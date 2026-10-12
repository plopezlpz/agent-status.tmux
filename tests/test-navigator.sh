#!/usr/bin/env bash
# Navigator regressions: dead-pane guards, server-scoped description keys and
# pruning, ctrl-g marker ownership/timeouts/races, transcript and dialog edge
# cases, run-shell format escaping, root-folder panes and UTF-8 truncation.
set -euo pipefail
PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
SOCK="agent-status-nav-test-$$"
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
for tool in tmux jq fzf; do
  ! command -v "$tool" >/dev/null 2>&1 || ln -s "$(command -v "$tool")" "$TMP/bin/$tool"
done
# No coreutils timeout here (stock macOS): ctrl-g must use its perl watchdog.
export PATH="$TMP/bin:$TMP/stub:/usr/bin:/bin"
NAV="$PLUGIN_DIR/scripts/agent-sessions.sh"
stub_pi(){ printf '#!/bin/sh\n%s\n' "$1" > "$TMP/stub/pi"; chmod +x "$TMP/stub/pi"; }
wait_gone(){ for _ in $(seq 1 50); do [ -e "$1" ] || return 0; sleep 0.2; done; return 1; }

# 1. Vanished panes: display -p succeeds for them, so nothing may run or save.
dead=$(tmux split-window -d -P -F '#{pane_id}' -t "$p1"); tmux kill-pane -t "$dead"
stub_pi "echo called >> '$TMP/pi-calls'; echo Title"
"$NAV" --generate-run "$dead"
[ ! -e "$TMP/pi-calls" ] || fail "generate-run called pi for a vanished pane"
[ -z "$(ls -A "$D")" ] || fail "generate-run left files for a vanished pane: $(ls -A "$D")"
mkdir "$TMP/fakefzf"
printf '#!/bin/sh\necho called >> "%s"\necho typed\n' "$TMP/fzf-calls" > "$TMP/fakefzf/fzf"; chmod +x "$TMP/fakefzf/fzf"
PATH="$TMP/fakefzf:$PATH" "$NAV" --dialog "$dead" </dev/null
[ ! -e "$TMP/fzf-calls" ] || fail "describe dialog opened for a vanished pane"
"$NAV" --generate "$dead"
[ -z "$(ls -A "$D")" ] || fail "generate-start marked a vanished pane"

# 2. Keys carry the server start time; legacy bare ids are ignored.
printf 'LEGACY TITLE\n' > "$D/${p1#%}"
"$NAV" --list | tr '\0' '\n' | grep -F 'LEGACY TITLE' >/dev/null && fail "navigator read a legacy bare-id description"
stub_pi 'cat >/dev/null; echo "Server scoped title"'
"$NAV" --generate-run "$p1"
[ "$(cat "$DK")" = 'Server scoped title' ] || fail "description not saved under <start_time>-<pane>"
[ ! -e "$DM" ] || fail "generation left its marker"
"$NAV" --list | tr '\0' '\n' | grep -F 'Server scoped title' >/dev/null || fail "card did not read the scoped key"
# Pruning on navigator start: only week-old entries of other servers go.
other=$((START - 1000))
mkdir -p "$D/dac"
for f in "$other-5" ".generating-$other-5" "$START-77" ".generating-$START-77" 29 "1-2-3" "x$other-5"; do
  : > "$D/$f"; touch -t 202001010000 "$D/$f"
done
: > "$D/$other-6"
printf '#!/bin/sh\ncat >/dev/null\nexit 130\n' > "$TMP/fakefzf/fzf"
PATH="$TMP/fakefzf:$PATH" "$NAV" </dev/null >/dev/null
for f in "$other-5" ".generating-$other-5"; do [ ! -e "$D/$f" ] || fail "stale $f not pruned"; done
for f in "$START-77" ".generating-$START-77" 29 "1-2-3" "x$other-5" "$other-6" dac "${p1#%}"; do
  [ -e "$D/$f" ] || fail "prune removed $f"
done
rm -f "$D/$START-77" "$D/.generating-$START-77"

# 3. A hung pi is capped (perl watchdog without timeout) and the marker goes.
command -v timeout >/dev/null 2>&1 && fail "test PATH unexpectedly has timeout"
stub_pi 'cat >/dev/null; sleep 30; echo late'
t0=$(date +%s)
AGENT_NAV_GENERATE_TIMEOUT=1 "$NAV" --generate-run "$p1"
[ $(( $(date +%s) - t0 )) -lt 10 ] || fail "perl watchdog did not cap pi"
[ ! -e "$DM" ] || fail "timed-out generation left its marker"
[ "$(cat "$DK")" = 'Server scoped title' ] || fail "timed-out generation changed the description"
real_timeout=$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin command -v timeout || command -v gtimeout || true)
if [ -n "$real_timeout" ]; then
  mkdir "$TMP/tbin"; ln -s "$real_timeout" "$TMP/tbin/timeout"
  t0=$(date +%s)
  PATH="$TMP/tbin:$PATH" AGENT_NAV_GENERATE_TIMEOUT=1 "$NAV" --generate-run "$p1"
  [ $(( $(date +%s) - t0 )) -lt 10 ] || fail "timeout did not cap pi"
  [ ! -e "$DM" ] || fail "timeout run left its marker"
fi
# A killed run removes its marker through the trap.
stub_pi "echo \$\$ > '$TMP/pi-pid'; cat >/dev/null; exec sleep 30"
rm -f "$TMP/pi-pid"
AGENT_NAV_GENERATE_TIMEOUT=60 "$NAV" --generate-run "$p1" & run=$!
for _ in $(seq 1 50); do [ -s "$TMP/pi-pid" ] && break; sleep 0.1; done
[ -e "$DM" ] || fail "generation did not create its marker"
kill -TERM "$run"; kill "$(cat "$TMP/pi-pid")" 2>/dev/null || true
wait "$run" 2>/dev/null || true
[ ! -e "$DM" ] || fail "terminated generation left its marker"

# 4. Concurrency: a Ctrl-E edit made during generation wins over the AI title.
stub_pi 'cat >/dev/null; sleep 1; echo "AI title"'
"$NAV" --generate-run "$p1" & run=$!
sleep 0.4; printf 'user edit\n' > "$DK"
wait "$run"
[ "$(cat "$DK")" = 'user edit' ] || fail "AI title overwrote a description saved meanwhile"
[ ! -e "$DM" ] || fail "skipped save left the marker"
# Double ctrl-g starts one run (through run-shell, with '#' in PATH and in the
# script path, which tmux would format-expand unless escaped).
hashdir="$TMP/has#{pane_id}#hash"; mkdir "$hashdir"
ln -s "$PLUGIN_DIR" "$TMP/plug#in"
printf '#!/bin/sh\necho run >> "%s"\ncat >/dev/null\nsleep 1\necho "Hashed path title"\n' "$TMP/runs" > "$hashdir/pi"
chmod +x "$hashdir/pi"; rm -f "$TMP/stub/pi"
PATH="$hashdir:$PATH" "$TMP/plug#in/scripts/agent-sessions.sh" --generate "$p1"
[ -e "$DM" ] || fail "ctrl-g did not create a marker"
PATH="$hashdir:$PATH" "$TMP/plug#in/scripts/agent-sessions.sh" --generate "$p1"
wait_gone "$DM" || fail "ctrl-g marker never cleared"
runs(){ cat "$TMP/runs" 2>/dev/null | wc -l | tr -d ' '; }
[ "$(runs)" = 1 ] || fail "double ctrl-g ran pi $(runs) times"
[ "$(cat "$DK")" = 'Hashed path title' ] || fail "run-shell command mangled by '#' format expansion"
# A stale marker (older than 3 minutes) is reclaimed.
printf 'dead-run\n' > "$DM"; touch -t 202001010000 "$DM"
PATH="$hashdir:$PATH" "$NAV" --generate "$p1"
wait_gone "$DM" || fail "reclaimed ctrl-g marker never cleared"
[ "$(runs)" = 2 ] || fail "stale marker blocked ctrl-g"

# 5. A transcript smaller than the tail window keeps its first line.
printf '%s\n' '{"type":"user","message":{"role":"user","content":"the only prompt"}}' > "$TMP/one.jsonl"
"$NAV" --context "$TMP/one.jsonl" | grep -F 'the only prompt' >/dev/null || fail "transcript lost its first line"

# 10. Screen context keeps literal text (no escape-stripping sed stage).
stub_pi "cat > '$TMP/pi-input'; echo 'Screen title'"
rm -f "$DK"
tmux send-keys -t "$p1" 'clear; printf "keep x1b[1m literal\n"' Enter; sleep 0.4
"$NAV" --generate-run "$p1"
grep -F 'keep x1b[1m literal' "$TMP/pi-input" >/dev/null || fail "screen context lost literal text"

# 6. Enter on the untouched automatic description saves nothing.
if [ -e "$TMP/bin/fzf" ]; then
  dialog() {
    local d
    d=$(tmux new-window -d -P -F '#{pane_id}' "$NAV --dialog $p1")
    for _ in $(seq 1 20); do
      sleep 0.2; case "$(tmux capture-pane -p -t "$d" 2>/dev/null)" in *'describe agent'*) break ;; esac
    done
    tmux send-keys -t "$d" "$@"
    for _ in $(seq 1 20); do sleep 0.2; tmux list-panes -a -F '#{pane_id}' | grep -qx "$d" || return 0; done
    tmux kill-pane -t "$d" 2>/dev/null; fail "description dialog did not close"
  }
  rm -f "$DK"
  tmux set-option -p -t "$p1" @agent-auto-description 'auto first prompt'
  dialog Enter
  [ ! -e "$DK" ] || fail "unchanged automatic description saved as an override: $(cat "$DK")"
  dialog ' edited' Enter
  [ "$(cat "$DK")" = 'auto first prompt edited' ] || fail "edited automatic description not saved"
  dialog Enter
  [ "$(cat "$DK")" = 'auto first prompt edited' ] || fail "unchanged override lost"
  rm -f "$DK"
else
  echo "SKIP: navigator dialog checks (fzf not installed)"
fi

# 8. An agent in "/" still gets a card and counts in the label.
root=$(tmux new-window -d -P -F '#{pane_id}' -c / 'sleep 60')
tmux set-option -p -t "$root" @agent-state working
cards=$("$NAV" --list | tr '\0' '\n')
printf '%s' "$cards" | grep -F "$root" >/dev/null || fail "agent in / has no card"
printf '%s' "$cards" | grep -F 't › / ·' >/dev/null || fail "agent in / has no folder label"
case "$("$NAV" --label)" in *'1 working'*'1 idle'*) ;; *) fail "label did not count the agent in /" ;; esac

# 9. Long multibyte descriptions are cut by characters, whatever the locale.
long=x$(printf 'é%.0s' $(seq 1 300))  # odd byte offset: a byte cut splits an é
printf '%s\n' "$long" > "$DK"
for loc in C ''; do
  title=$(env LC_ALL="$loc" LANG= LC_CTYPE= "$NAV" --list | LC_ALL=C tr "\0" "\n" | LC_ALL=C grep -F "$p1" | LC_ALL=C cut -f4)
  printf '%s' "$title" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || fail "truncation split a UTF-8 character (LC_ALL=$loc)"
  printf '%s' "$title" | grep -F "x$(printf 'é%.0s' $(seq 1 239))" >/dev/null || fail "truncation lost characters (LC_ALL=$loc)"
  printf '%s' "$title" | grep -F "x$(printf 'é%.0s' $(seq 1 240))" >/dev/null && fail "truncation kept over 240 characters (LC_ALL=$loc)"
done
rm -f "$DK"

# 11. Automatic refreshes use reload (reload-sync blocks typing under --track).
: > "$TMP/refresh"
action=$(AGENT_NAV_REFRESH_FILE="$TMP/refresh" "$NAV" --refresh)
case "$action" in reload\(*) ;; *) fail "automatic refresh is not a plain reload: $action" ;; esac

# 12. The tick redraws the preview only when the focused pane's screen changed.
# A minute rollover may add a reload; it must still carry refresh-preview.
tick(){ AGENT_NAV_REFRESH_FILE="$TMP/refresh" "$NAV" --refresh "$p1"; }
case "$(tick)" in *refresh-preview) ;; *) fail "first preview tick did not refresh the preview" ;; esac
case "$(tick)" in ''|reload\(*) ;; *) fail "unchanged pane redrew the preview" ;; esac
tmux send-keys -t "$p1" 'echo preview-changed' Enter
for _ in 1 2 3 4 5 6 7 8 9 10; do tmux capture-pane -p -t "$p1" | grep -q '^preview-changed' && break; sleep 0.1; done
case "$(tick)" in *refresh-preview) ;; *) fail "changed pane did not refresh the preview" ;; esac

echo "PASS: navigator"
