#!/usr/bin/env bash
# describe.sh: overrides (cleaning, clearing, key validation), dead-pane
# guards, server-scoped keys and pruning, generation marker ownership,
# timeouts and races, transcript edge cases and run-shell format escaping.
set -euo pipefail
PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
SOCK="agent-status-describe-test-$$"
TMP="$(mktemp -d)"
fail(){ echo "FAIL: $1" >&2; exit 1; }
ctl(){ TMUX='' tmux -L "$SOCK" "$@"; }
cleanup(){ ctl kill-server 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }
ctl -f /dev/null new-session -d -s t -x 100 -y 30
p1="$(ctl display -pt t:0.0 '#{pane_id}')"
TMUX="$(ctl display -pt "$p1" '#{socket_path},#{pid},0')"
export TMUX
D="$TMP/descriptions"
tmux set-option -g @agent-descriptions-dir "$D"
tmux set-option -p -t "$p1" @agent-state idle
tmux set-option -p -t "$p1" @agent-kind pi
START=$(tmux display -p '#{start_time}')
DK="$D/$START-${p1#%}"; DM="$D/.generating-$START-${p1#%}"

mkdir "$TMP/bin" "$TMP/stub" "$D"
for tool in tmux jq; do
  ! command -v "$tool" >/dev/null 2>&1 || ln -s "$(command -v "$tool")" "$TMP/bin/$tool"
done
# No coreutils timeout here (stock macOS): generation must use its perl watchdog.
export PATH="$TMP/bin:$TMP/stub:/usr/bin:/bin"
DESCRIBE="$PLUGIN_DIR/scripts/agent/describe.sh"
stub_pi(){ printf '#!/bin/sh\n%s\n' "$1" > "$TMP/stub/pi"; chmod +x "$TMP/stub/pi"; }
wait_gone(){ for _ in $(seq 1 50); do [ -e "$1" ] || return 0; sleep 0.2; done; return 1; }

# 1. Overrides: saved cleaned and server-scoped, cleared when blank, bumping
# the revision; keys that aren't pane ids are rejected.
rev=$(tmux show -gqv @agent-revision)
"$DESCRIBE" set "$p1" $'safe\033[31m label\tdata'
[ "$(cat "$DK")" = 'safe[31m label data' ] || fail "override not saved cleaned: $(cat "$DK")"
[ "$(tmux show -gqv @agent-revision)" != "$rev" ] || fail "saving did not bump @agent-revision"
"$DESCRIBE" set "$p1" ''
[ ! -e "$DK" ] || fail "a blank override did not clear it"
if "$DESCRIBE" set '../../escape' x 2>/dev/null; then fail "accepted a traversal key"; fi
[ ! -e "$TMP/escape" ] || fail "description escaped its directory"
long=x$(printf 'é%.0s' $(seq 1 300))  # odd byte offset: a byte cut splits an é
for loc in C ''; do
  env LC_ALL="$loc" LANG= LC_CTYPE= "$DESCRIBE" set "$p1" "$long"
  iconv -f UTF-8 -t UTF-8 < "$DK" >/dev/null 2>&1 || fail "truncation split a UTF-8 character (LC_ALL=$loc)"
  [ "$(cat "$DK")" = "x$(printf 'é%.0s' $(seq 1 239))" ] || fail "not cut to 240 characters (LC_ALL=$loc)"
done
rm -f "$DK"

# 2. Vanished panes: display -p succeeds for them, so nothing may run or save.
dead=$(tmux split-window -d -P -F '#{pane_id}' -t "$p1"); tmux kill-pane -t "$dead"
stub_pi "echo called >> '$TMP/pi-calls'; echo Title"
"$DESCRIBE" run "$dead"
[ ! -e "$TMP/pi-calls" ] || fail "run called pi for a vanished pane"
[ -z "$(ls -A "$D")" ] || fail "run left files for a vanished pane: $(ls -A "$D")"
"$DESCRIBE" generate "$dead"
"$DESCRIBE" set "$dead" 'orphan'
[ -z "$(ls -A "$D")" ] || fail "generate/set wrote files for a vanished pane"

# 3. Keys carry the server start time; pruning drops only week-old entries
# of other servers.
stub_pi 'cat >/dev/null; echo "Server scoped title"'
"$DESCRIBE" run "$p1"
[ "$(cat "$DK")" = 'Server scoped title' ] || fail "description not saved under <start_time>-<pane>"
[ ! -e "$DM" ] || fail "generation left its marker"
other=$((START - 1000))
mkdir -p "$D/dac"
for f in "$other-5" ".generating-$other-5" "$START-77" ".generating-$START-77" 29 "1-2-3" "x$other-5"; do
  : > "$D/$f"; touch -t 202001010000 "$D/$f"
done
: > "$D/$other-6"
"$DESCRIBE" prune
for f in "$other-5" ".generating-$other-5"; do [ ! -e "$D/$f" ] || fail "stale $f not pruned"; done
for f in "$START-77" ".generating-$START-77" 29 "1-2-3" "x$other-5" "$other-6" dac; do
  [ -e "$D/$f" ] || fail "prune removed $f"
done
rm -f "$D/$START-77" "$D/.generating-$START-77"

# 4. A hung pi is capped (perl watchdog without timeout) and the marker goes.
command -v timeout >/dev/null 2>&1 && fail "test PATH unexpectedly has timeout"
stub_pi 'cat >/dev/null; sleep 30; echo late'
t0=$(date +%s)
AGENT_DESCRIBE_TIMEOUT=1 "$DESCRIBE" run "$p1"
[ $(( $(date +%s) - t0 )) -lt 10 ] || fail "perl watchdog did not cap pi"
[ ! -e "$DM" ] || fail "timed-out generation left its marker"
[ "$(cat "$DK")" = 'Server scoped title' ] || fail "timed-out generation changed the description"
real_timeout=$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin command -v timeout || command -v gtimeout || true)
if [ -n "$real_timeout" ]; then
  mkdir "$TMP/tbin"; ln -s "$real_timeout" "$TMP/tbin/timeout"
  t0=$(date +%s)
  PATH="$TMP/tbin:$PATH" AGENT_DESCRIBE_TIMEOUT=1 "$DESCRIBE" run "$p1"
  [ $(( $(date +%s) - t0 )) -lt 10 ] || fail "timeout did not cap pi"
  [ ! -e "$DM" ] || fail "timeout run left its marker"
fi
# A killed run removes its marker through the trap.
stub_pi "echo \$\$ > '$TMP/pi-pid'; cat >/dev/null; exec sleep 30"
rm -f "$TMP/pi-pid"
AGENT_DESCRIBE_TIMEOUT=60 "$DESCRIBE" run "$p1" & run=$!
for _ in $(seq 1 50); do [ -s "$TMP/pi-pid" ] && break; sleep 0.1; done
[ -e "$DM" ] || fail "generation did not create its marker"
kill -TERM "$run"; kill "$(cat "$TMP/pi-pid")" 2>/dev/null || true
wait "$run" 2>/dev/null || true
[ ! -e "$DM" ] || fail "terminated generation left its marker"

# 5. Concurrency: an edit made during generation wins over the AI title.
stub_pi 'cat >/dev/null; sleep 1; echo "AI title"'
"$DESCRIBE" run "$p1" & run=$!
sleep 0.4; printf 'user edit\n' > "$DK"
wait "$run"
[ "$(cat "$DK")" = 'user edit' ] || fail "AI title overwrote a description saved meanwhile"
[ ! -e "$DM" ] || fail "skipped save left the marker"
# A double generate starts one run (through run-shell, with '#' in PATH and in
# the script path, which tmux would format-expand unless escaped).
hashdir="$TMP/has#{pane_id}#hash"; mkdir "$hashdir"
ln -s "$PLUGIN_DIR" "$TMP/plug#in"
printf '#!/bin/sh\necho run >> "%s"\ncat >/dev/null\nsleep 1\necho "Hashed path title"\n' "$TMP/runs" > "$hashdir/pi"
chmod +x "$hashdir/pi"; rm -f "$TMP/stub/pi"
PATH="$hashdir:$PATH" "$TMP/plug#in/scripts/agent/describe.sh" generate "$p1"
[ -e "$DM" ] || fail "generate did not create a marker"
PATH="$hashdir:$PATH" "$TMP/plug#in/scripts/agent/describe.sh" generate "$p1"
wait_gone "$DM" || fail "generation marker never cleared"
runs(){ cat "$TMP/runs" 2>/dev/null | wc -l | tr -d ' '; }
[ "$(runs)" = 1 ] || fail "double generate ran pi $(runs) times"
[ "$(cat "$DK")" = 'Hashed path title' ] || fail "run-shell command mangled by '#' format expansion"
# A stale marker (older than 3 minutes) is reclaimed.
printf 'dead-run\n' > "$DM"; touch -t 202001010000 "$DM"
PATH="$hashdir:$PATH" "$DESCRIBE" generate "$p1"
wait_gone "$DM" || fail "reclaimed generation marker never cleared"
[ "$(runs)" = 2 ] || fail "stale marker blocked generation"

# 6. A transcript smaller than the tail window keeps its first line.
printf '%s\n' '{"type":"user","message":{"role":"user","content":"the only prompt"}}' > "$TMP/one.jsonl"
"$DESCRIBE" context "$TMP/one.jsonl" | grep -F 'the only prompt' >/dev/null || fail "transcript lost its first line"

# 7. Screen context keeps literal text (no escape-stripping sed stage).
stub_pi "cat > '$TMP/pi-input'; echo 'Screen title'"
rm -f "$DK"
tmux send-keys -t "$p1" 'clear; printf "keep x1b[1m literal\n"' Enter; sleep 0.4
"$DESCRIBE" run "$p1"
grep -F 'keep x1b[1m literal' "$TMP/pi-input" >/dev/null || fail "screen context lost literal text"

echo "PASS: describe"
