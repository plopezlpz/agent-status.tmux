#!/usr/bin/env bash
# describe.sh: titles in @agent-description (cleaning, clearing, key
# validation), dead-pane guards, transcript edge cases, and suggestions that
# are printed, not set, with their timeouts and signals.
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
tmux set-option -p -t "$p1" @agent-state idle
tmux set-option -p -t "$p1" @agent-kind pi
title(){ tmux show-option -pqv -t "$p1" @agent-description; }

mkdir "$TMP/bin" "$TMP/stub"
for tool in tmux jq; do
  ! command -v "$tool" >/dev/null 2>&1 || ln -s "$(command -v "$tool")" "$TMP/bin/$tool"
done
# No coreutils timeout here: suggest must use its perl watchdog, so the
# system dirs are linked in without it (Linux keeps it in /usr/bin). No
# fallback path either: only the stub pi may run.
mkdir "$TMP/sys"
ln -s /usr/bin/* /bin/* "$TMP/sys/" 2>/dev/null || true
rm -f "$TMP/sys/timeout" "$TMP/sys/gtimeout"
export PATH="$TMP/bin:$TMP/stub:$TMP/sys" AGENT_PI_FALLBACK_PATH=
DESCRIBE="$PLUGIN_DIR/scripts/agent/describe.sh"
stub_pi(){ printf '#!/bin/sh\n%s\n' "$1" > "$TMP/stub/pi"; chmod +x "$TMP/stub/pi"; }
wait_for(){ for _ in $(seq 1 50); do eval "$1" && return 0; sleep 0.2; done; return 1; }
alive(){ [ -s "$TMP/pi-pid" ] && kill -0 "$(cat "$TMP/pi-pid")" 2>/dev/null; }

# 1. Titles: set cleaned and trimmed; blank clears; keys that aren't pane ids
# are rejected.
"$DESCRIBE" set "$p1" $'  safe\033[31m label\tdata '
[ "$(title)" = 'safe[31m label data' ] || fail "title not set cleaned: $(title)"
"$DESCRIBE" set "$p1" '  '
[ -z "$(title)" ] || fail "a blank title did not clear it"
rc=0; "$DESCRIBE" set '../../escape' x 2>/dev/null || rc=$?
[ "$rc" = 2 ] || fail "a bad key was not rejected with status 2 ($rc)"
long=x$(printf 'é%.0s' $(seq 1 300))  # odd byte offset: a byte cut splits an é
for loc in C ''; do
  env LC_ALL="$loc" LANG= LC_CTYPE= "$DESCRIBE" set "$p1" "$long"
  [ "$(title)" = "x$(printf 'é%.0s' $(seq 1 239))" ] || fail "not cut to 240 characters (LC_ALL=$loc)"
done

# 2. Vanished panes: display -p succeeds for them, so nothing may be set.
dead=$(tmux split-window -d -P -F '#{pane_id}' -t "$p1"); tmux kill-pane -t "$dead"
err=$("$DESCRIBE" set "$dead" orphan 2>&1) && fail "set succeeded for a vanished pane"
[ "$err" = "describe.sh: pane $dead is gone" ] || fail "set gave no reason: $err"

# 3. A transcript smaller than the tail window keeps its first line.
printf '%s\n' '{"type":"user","message":{"role":"user","content":"the only prompt"}}' > "$TMP/one.jsonl"
"$DESCRIBE" context "$TMP/one.jsonl" | grep -F 'the only prompt' >/dev/null || fail "transcript lost its first line"

# 4. Screen context keeps literal text (no escape-stripping sed stage).
stub_pi "cat > '$TMP/pi-input'; echo 'Screen title'"
tmux send-keys -t "$p1" 'clear; printf "keep x1b[1m literal\n"' Enter; sleep 0.4
"$DESCRIBE" suggest "$p1" >/dev/null
grep -F 'keep x1b[1m literal' "$TMP/pi-input" >/dev/null || fail "screen context lost literal text"

# 5. suggest prints pi's title, cleaned and cut, and sets nothing; failures
# say why on stderr.
"$DESCRIBE" set "$p1" kept
stub_pi "cat >/dev/null; printf '\"Fix the\\033 cart page\"\\n'"
[ "$("$DESCRIBE" suggest "$p1")" = 'Fix the cart page' ] || fail "suggest did not print the cleaned title"
[ "$(title)" = kept ] || fail "suggest changed the title"
stub_pi "cat >/dev/null; printf '%s\\n' '$(printf 'y%.0s' $(seq 1 100))'"
[ "$("$DESCRIBE" suggest "$p1")" = "$(printf 'y%.0s' $(seq 1 80))" ] || fail "suggest did not cut to 80 characters"
suggest_err(){ local out; if out=$("$DESCRIBE" suggest "$1" 2>&1); then fail "suggest succeeded: $out"; fi; printf '%s' "$out"; }
stub_pi 'cat >/dev/null'
[ "$(suggest_err "$p1")" = 'pi gave no title' ] || fail "no reason for an empty reply"
stub_pi 'cat >/dev/null; echo "warming up" >&2; echo "error: not logged in" >&2; exit 1'
[ "$(suggest_err "$p1")" = 'pi failed: error: not logged in' ] || fail "pi's error not passed on"
# A hung pi is capped, by the perl watchdog or by coreutils timeout.
command -v timeout >/dev/null 2>&1 && fail "test PATH unexpectedly has timeout"
real_timeout=$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin command -v timeout || command -v gtimeout || true)
[ -z "$real_timeout" ] || { mkdir "$TMP/tbin"; ln -s "$real_timeout" "$TMP/tbin/timeout"; }
stub_pi 'cat >/dev/null; sleep 30'
for runner_path in "$PATH" ${real_timeout:+"$TMP/tbin:$PATH"}; do
  t0=$(date +%s)
  [ "$(PATH="$runner_path" AGENT_DESCRIBE_TIMEOUT=1 suggest_err "$p1")" = 'pi timed out after 1s' ] || fail "no reason for a timeout ($runner_path)"
  [ $(( $(date +%s) - t0 )) -lt 10 ] || fail "pi was not capped ($runner_path)"
done
[ "$(suggest_err "$dead")" = "pane $dead is gone" ] || fail "no reason for a vanished pane"
[ "$(TMUX=/nonexistent/socket,1,0 suggest_err "$p1")" = 'cannot reach tmux' ] || fail "an unreachable tmux reported as a gone pane"
rc=0; "$DESCRIBE" suggest '../x' 2>/dev/null || rc=$?
[ "$rc" = 2 ] || fail "suggest accepted a bad key ($rc)"
rm -f "$TMP/stub/pi"
[ "$(suggest_err "$p1")" = 'pi is not installed' ] || fail "no reason without pi"
# A UI cancelling a suggestion (TERM to the script) stops pi, under either
# runner.
stub_pi "echo \$\$ > '$TMP/pi-pid'; cat >/dev/null; exec sleep 30"
for runner_path in "$PATH" ${real_timeout:+"$TMP/tbin:$PATH"}; do
  rm -f "$TMP/pi-pid"
  PATH="$runner_path" AGENT_DESCRIBE_TIMEOUT=60 "$DESCRIBE" suggest "$p1" >/dev/null 2>&1 & run=$!
  wait_for alive || fail "pi never started for suggest"
  kill -TERM "$run"; wait "$run" 2>/dev/null || true
  wait_for '! alive' || fail "terminated suggest left pi running ($runner_path)"
done
leftover=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'agent-describe.*' -newer "$TMP/stub" 2>/dev/null | head -1)
[ -z "$leftover" ] || fail "suggest left its temporary directory: $leftover"

echo "PASS: describe"
