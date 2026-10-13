#!/usr/bin/env bash
# Exercise the plugin's tmux hooks (pane exit/death, layout reconciliation),
# stdin handling, compaction, locks, locale, focused completion, notification
# clicks and log failures on isolated tmux servers.
set -euo pipefail
PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
AGENT="$PLUGIN_DIR/scripts/agent"
SET="$AGENT/set-state.sh"
SOCK="agent-status-hooks-test-$$"
SOCKA="agent-status-hooks-outer-$$"
TMP="$(mktemp -d)"
fail(){ echo "FAIL: $1" >&2; exit 1; }
ctl(){ TMUX='' tmux -L "$SOCK" "$@"; }
outer(){ TMUX='' tmux -L "$SOCKA" "$@"; }
cleanup(){
  local dir
  dir=$(ctl display -p '#{socket_path}' 2>/dev/null) || dir=""
  outer kill-server 2>/dev/null || true
  ctl kill-server 2>/dev/null || true
  # tmux 3.8 leaves the socket file behind after kill-server.
  [ -z "$dir" ] || rm -f "$dir" "${dir%/*}/$SOCKA"
  jobs -p | xargs kill 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
REAL_TMUX=$(command -v tmux)
mkdir "$TMP/bin"
ln -s "$REAL_TMUX" "$TMP/bin/tmux"
ln -s "$(command -v jq)" "$TMP/bin/jq"
export PATH="$TMP/bin:/usr/bin:/bin"

ctl -f /dev/null new-session -d -s t -x 120 -y 40
p1="$(ctl display -pt t:0.0 '#{pane_id}')"
w1="$(ctl display -pt "$p1" '#{window_id}')"
TMUX="$(ctl display -pt "$p1" '#{socket_path},#{pid},0')"
export TMUX
SOCK_PATH="${TMUX%%,*}"
tmux set-option -g @agent-log "$TMP/agent.log"
for s in working asking finished idle; do
  tmux set-option -g "@agent-icon-$s" "$s"
  tmux set-option -g "@agent-color-$s" default
done

get(){ tmux show-option -p -q -v -t "$1" "$2" 2>/dev/null || true; }
icon(){ tmux show-option -wqv -t "$1" @agent-icon 2>/dev/null || true; }
icon_is(){ [ "$(icon "$1")" = "#[push-default]#[fg=default]$2#[fg=default]#[pop-default]" ]; }
no_icon(){ [ -z "$(icon "$1")" ]; }
state(){ TMUX_PANE="$1" "$SET" "${@:2}" </dev/null; }
# eventually CMD...: poll for an asynchronous (run-shell -b) hook result.
eventually(){ local _; for _ in $(seq 1 40); do "$@" && return 0; sleep 0.1; done; "$@"; }
# finishes_within SECONDS PID: the process exits in time (killed otherwise).
finishes_within(){
  local _ n=$(( $1 * 10 ))
  for _ in $(seq 1 "$n"); do kill -0 "$2" 2>/dev/null || return 0; sleep 0.1; done
  kill "$2" 2>/dev/null || true; return 1
}

# ----- plugin load: hooks are -b, use hook_* formats, idempotent -----------
tmux set-hook -g pane-exited 'display-message user-hook'
bash "$PLUGIN_DIR/agent-status.tmux"
bash "$PLUGIN_DIR/agent-status.tmux"
for h in pane-focus-in pane-exited pane-died window-layout-changed pane-moved; do
  hooks=$(tmux show-hooks -g "$h")
  n=$(printf '%s\n' "$hooks" | grep -cF 'agent-status.tmux/scripts/agent' || true)
  [ "$n" -eq 1 ] || fail "$h has $n plugin entries after reload"
  printf '%s\n' "$hooks" | grep -F 'agent-status.tmux/scripts/agent' | grep -F 'run-shell -b' >/dev/null || fail "$h hook is not run-shell -b"
done
tmux show-hooks -g pane-exited | grep -F 'user-hook' >/dev/null || fail "reload dropped a user pane-exited hook"
tmux show-hooks -g pane-exited | grep -F '#{hook_pane}' >/dev/null || fail "pane-exited hook does not use #{hook_pane}"

# ----- pane-exited clears the exited pane, not the session's current one ---
# Record what tmux passes as #{hook_window}: the plugin relies on it.
for h in pane-exited pane-died; do
  tmux set-hook -ga "$h" "run-shell -b 'echo $h #{hook_pane} #{hook_window} >> $TMP/hook-window'"
done
state "$p1" working "" a-1 1 test reset
p2=$(tmux split-window -d -P -F '#{pane_id}' -t "$p1" 'sleep 1')
state "$p2" asking "" a-2 1 test reset
tmux set-option -p -t "$p1" @agent-description 'first title'
tmux set-option -p -t "$p2" @agent-description 'second title'
icon_is "$w1" asking || fail "asking pane did not win the rollup"
gone(){ ! tmux list-panes -a -F '#{pane_id}' | grep -qx "$1"; }
eventually gone "$p2" || fail "short-lived pane did not exit"
eventually icon_is "$w1" working || fail "pane-exited did not reaggregate the window"
[ "$(get "$p1" @agent-state)" = working ] || fail "pane-exited cleared the wrong pane"
[ "$(get "$p1" @agent-description)" = 'first title' ] || fail "pane-exited cleared another pane's title"
grep -Fx "pane-exited $p2 $w1" "$TMP/hook-window" >/dev/null || fail "pane-exited #{hook_window} is not the pane's window"
if grep -F "pane=$p2 " "$TMP/agent.log" | grep -F 'cleared (exit)' >/dev/null; then fail "vanished pane logged another pane's state as cleared"; fi

# ----- remain-on-exit: pane-died clears the dead pane --------------------
p3=$(tmux split-window -d -P -F '#{pane_id}' -t "$p1" 'sleep 1')
tmux set-option -p -t "$p3" remain-on-exit on
state "$p3" asking "" a-3 1 test reset
dead(){ [ "$(tmux display -pt "$p3" '#{pane_dead}')" = 1 ]; }
eventually dead || fail "remain-on-exit pane did not die"
cleared(){ [ -z "$(get "$p3" @agent-state)" ]; }
eventually cleared || fail "pane-died did not clear the dead pane"
eventually icon_is "$w1" working || fail "pane-died did not reaggregate the window"
grep -Fx "pane-died $p3 $w1" "$TMP/hook-window" >/dev/null || fail "pane-died #{hook_window} is not the pane's window"
tmux kill-pane -t "$p3"

# ----- reports for a vanished pane change nothing --------------------------
lines=$(wc -l < "$TMP/agent.log")
TMUX_PANE="$p3" "$SET" asking "" a-3 2 test </dev/null || fail "set-state for a vanished pane failed"
TMUX_PANE="$p3" "$AGENT/clear-state.sh" quit a-3 test </dev/null || fail "clear-state for a vanished pane failed"
"$AGENT/clear-finished.sh" "$p3" || fail "clear-finished for a vanished pane failed"
[ "$(wc -l < "$TMP/agent.log")" = "$lines" ] || fail "a vanished pane's report was logged"
[ "$(get "$p1" @agent-state)" = working ] || fail "a vanished pane's report changed another pane"

# ----- layout fast path: an unchanged window costs one tmux call -----------
[ "$(tmux show-option -wqv -t "$w1" @agent-icon-key)" = "working:0 " ] || fail "window agent key not cached"
mkdir "$TMP/cbin"
printf '#!/bin/sh\necho call >> %s\nexec %s "$@"\n' "$TMP/tmux-calls" "$REAL_TMUX" > "$TMP/cbin/tmux"
chmod +x "$TMP/cbin/tmux"
PATH="$TMP/cbin:$PATH" "$AGENT/update-window-icon.sh" "$w1" layout
[ "$(wc -l < "$TMP/tmux-calls" | tr -d ' ')" = 1 ] || fail "layout change in an unchanged agent window made $(wc -l < "$TMP/tmux-calls") tmux calls"

# ----- layout changes reconcile icons -------------------------------------
p4=$(tmux split-window -d -P -F '#{pane_id}' -t "$p1")
state "$p4" asking "" a-4 1 test reset
icon_is "$w1" asking || fail "asking rollup missing before kill-pane"
tmux kill-pane -t "$p4"
eventually icon_is "$w1" working || fail "kill-pane of an asking pane left its icon"

p5=$(tmux split-window -d -P -F '#{pane_id}' -t "$p1")
state "$p5" asking "" a-5 1 test reset
tmux break-pane -d -s "$p5"
w2=$(tmux display -pt "$p5" '#{window_id}')
eventually icon_is "$w1" working || fail "break-pane left the old window's icon"
eventually icon_is "$w2" asking || fail "break-pane did not set the new window's icon"
tmux split-window -d -t "$p5"
tmux join-pane -d -s "$p5" -t "$p1"
eventually icon_is "$w1" asking || fail "join-pane did not set the destination icon"
eventually no_icon "$w2" || fail "join-pane left the source window's icon"
tmux kill-window -t "$w2"
tmux kill-pane -t "$p5"
eventually icon_is "$w1" working || fail "icon not restored after cleanup"

# ----- adapters' open stdin never blocks set-state/clear-state/auto-desc --
mkfifo "$TMP/fifo"
sleep 30 > "$TMP/fifo" & writer=$!
TMUX_PANE="$p1" "$SET" working "" a-1 7 test < "$TMP/fifo" & pid=$!
finishes_within 3 "$pid" || fail "set-state with adapter args blocked on open stdin"
TMUX_PANE="$p1" "$SET" working "" "" "" test < "$TMP/fifo" & pid=$!
finishes_within 3 "$pid" || fail "set-state with an empty instance blocked on open stdin"
TMUX_PANE="$p1" "$AGENT/auto-desc.sh" clear test < "$TMP/fifo" & pid=$!
finishes_within 3 "$pid" || fail "auto-desc clear with a source blocked on open stdin"
TMUX_PANE="$p1" "$AGENT/clear-state.sh" quit wrong-instance test < "$TMP/fifo" & pid=$!
finishes_within 3 "$pid" || fail "clear-state with adapter args blocked on open stdin"
{ kill "$writer"; wait "$writer"; } 2>/dev/null || true
[ "$(get "$p1" @agent-state)" = working ] || fail "adapter reports changed state unexpectedly"

# ----- auto-compaction keeps the live state -------------------------------
p6=$(tmux split-window -d -P -F '#{pane_id}' -t "$p1")
claude(){ printf '%s\n' "$2" | TMUX_PANE="$1" AGENT_STATUS_KIND=claude "$SET" "$3"; }
claude "$p6" '{"session_id":"c-1","hook_event_name":"SessionStart","source":"startup"}' idle
claude "$p6" '{"session_id":"c-1","hook_event_name":"UserPromptSubmit"}' working
at=$(get "$p6" @agent-state-at)
claude "$p6" '{"session_id":"c-1","hook_event_name":"SessionStart","source":"compact","transcript_path":"/tmp/c-1.jsonl"}' idle
[ "$(get "$p6" @agent-state)" = working ] || fail "compaction SessionStart flipped working to idle"
[ "$(get "$p6" @agent-state-at)" = "$at" ] || fail "compaction reset the state age"
[ "$(get "$p6" @agent-transcript)" = /tmp/c-1.jsonl ] || fail "compaction did not refresh the transcript path"
claude "$p6" '{"session_id":"c-1","hook_event_name":"Stop"}' finished
claude "$p6" '{"session_id":"c-1","hook_event_name":"SessionStart","source":"compact"}' idle
[ "$(get "$p6" @agent-state):$(get "$p6" @agent-unseen)" = idle:1 ] || fail "compaction acknowledged an unseen completion"
claude "$p6" '{"session_id":"c-1","hook_event_name":"SessionStart","source":"clear"}' idle
[ "$(get "$p6" @agent-unseen)" = 0 ] || fail "a /clear SessionStart did not reset"
tmux kill-pane -t "$p6"
p6=$(tmux split-window -d -P -F '#{pane_id}' -t "$p1")
claude "$p6" '{"session_id":"c-2","hook_event_name":"SessionStart","source":"compact"}' idle
[ "$(get "$p6" @agent-state):$(get "$p6" @agent-instance)" = idle:claude:c-2 ] || fail "compaction did not register an unknown pane"
tmux kill-pane -t "$p6"

# ----- locks: stale and wedged holders cannot block hooks -----------------
holder(){  # holder PANE MODE &: take PANE's lock, record its path, then MODE
  rm -f "$TMP/lockpath"
  TMUX_PANE="$1" exec bash -c '. "$1/lib.sh"; agent_lock "pane-${TMUX_PANE#%}"; printf "%s" "$AGENT_LOCK" > "$2"
    case "$3" in kill) kill -9 $$ ;; hang) sleep 10 ;; term) sleep 10 & wait $! ;; esac' _ "$AGENT" "$TMP/lockpath" "$2"
}
holder "$p1" kill & wait $! 2>/dev/null || true
lockfile=$(cat "$TMP/lockpath")
[ -e "$lockfile" ] || fail "SIGKILLed holder left no lock to recover"
state "$p1" asking "" a-1 20 test & pid=$!
finishes_within 2 "$pid" || fail "a dead holder's lock blocked set-state"
[ "$(get "$p1" @agent-state)" = asking ] || fail "update lost after recovering a dead holder's lock"
[ ! -e "$lockfile" ] || fail "set-state left its lock behind"
holder "$p1" hang & hpid=$!
eventually test -s "$TMP/lockpath" -a -e "$lockfile" || fail "hung holder did not lock"
state "$p1" working "" a-1 21 test & pid=$!
finishes_within 8 "$pid" || fail "a wedged holder blocked set-state past the bound"
[ "$(get "$p1" @agent-state)" = working ] || fail "update lost after breaking a wedged lock"
kill "$hpid" 2>/dev/null || true; wait "$hpid" 2>/dev/null || true
holder "$p1" term & hpid=$!
eventually test -s "$TMP/lockpath" || fail "TERM holder did not lock"
sleep 0.2; kill -TERM "$hpid"; wait "$hpid" 2>/dev/null || true
[ ! -e "$(cat "$TMP/lockpath")" ] || fail "SIGTERM did not release the lock"

# Every client of a server shares the lock, whatever its TMPDIR.
lockpath(){ TMPDIR="$1" bash -c '. "$1/lib.sh"; agent_lock probe; printf "%s" "$AGENT_LOCK"' _ "$AGENT"; }
mkdir "$TMP/t1" "$TMP/t2"
l1=$(lockpath "$TMP/t1"); l2=$(lockpath "$TMP/t2")
[ "$l1" = "$l2" ] || fail "lock path depends on TMPDIR: $l1 vs $l2"
case "$l1" in "${SOCK_PATH%/*}/agent-status/"*) ;; *) fail "lock not beside the server socket: $l1" ;; esac
# A custom -S socket outside a tmux-* directory keeps locks under TMPDIR.
l3=$(TMUX="$TMP/custom.sock,123,0" lockpath "$TMP/t1")
case "$l3" in "$TMP/t1/agent-status-"*) ;; *) fail "custom-socket lock not under TMPDIR: $l3" ;; esac
[ ! -e "$TMP/agent-status" ] || fail "custom-socket lock created a directory beside the socket"
# Stale breakers (dead PID, or empty: killed before writing it) don't block.
dead_pid=$(bash -c 'echo $$') seq=22
for breaker in "$dead_pid" ""; do
  holder "$p1" kill & wait $! 2>/dev/null || true
  lockfile=$(cat "$TMP/lockpath")
  printf '%s' "$breaker" > "$lockfile.break"
  seq=$((seq + 1)); state "$p1" asking "" a-1 "$seq" test & pid=$!
  finishes_within 10 "$pid" || fail "stale breaker '$breaker' blocked set-state"
  [ ! -e "$lockfile.break" ] || fail "stale breaker '$breaker' was not cleared"
done
# A burst of waiters (longer in total than the stale bound) behind a dead
# owner's lock: every critical section runs alone and none is lost.
mkdir "$TMP/burst"; echo 0 > "$TMP/burst/count"
{ bash -c '. "$1/lib.sh"; agent_lock burst; kill -9 $$' _ "$AGENT"; } 2>/dev/null || true
worker(){
  bash -c '. "$1/lib.sh"; agent_lock burst
    mkdir "$2/inside" 2>/dev/null || echo overlap >> "$2/violations"
    n=$(cat "$2/count"); sleep 0.1; echo $((n + 1)) > "$2/count"
    rmdir "$2/inside" 2>/dev/null || true' _ "$AGENT" "$TMP/burst"
}
wpids=""
for _ in $(seq 1 40); do worker & wpids="$wpids $!"; done
for w in $wpids; do wait "$w"; done
[ ! -e "$TMP/burst/violations" ] || fail "lock let $(wc -l < "$TMP/burst/violations") critical sections overlap"
[ "$(cat "$TMP/burst/count")" = 40 ] || fail "lock burst lost updates: $(cat "$TMP/burst/count")/40"

# ----- locale: a client without TMUX or a UTF-8 locale still parses -------
mkdir "$TMP/lbin"
printf '#!/bin/sh\nexec env -u TMUX -u LANG -u LC_ALL -u LC_CTYPE %s -S %s "$@"\n' "$REAL_TMUX" "$SOCK_PATH" > "$TMP/lbin/tmux"
chmod +x "$TMP/lbin/tmux"
state "$p1" working "" a-1 30 test
PATH="$TMP/lbin:$PATH" TMUX_PANE="$p1" "$SET" asking "" a-1 29 test </dev/null
[ "$(get "$p1" @agent-state)" = working ] || fail "non-UTF-8 client misparsed state (stale sequence accepted)"
PATH="$TMP/lbin:$PATH" TMUX_PANE="$p1" "$SET" asking "" a-1 31 test </dev/null
[ "$(get "$p1" @agent-state)" = asking ] || fail "non-UTF-8 client lost an update"
PATH="$TMP/lbin:$PATH" "$AGENT/update-window-icon.sh" "$w1"
icon_is "$w1" asking || fail "non-UTF-8 client misparsed the rollup"

# ----- an unwritable log never aborts the hook ------------------------------
tmux set-option -g @agent-log /dev/null/agent.log
state "$p1" working "" a-1 40 test || fail "unwritable log made set-state fail"
icon_is "$w1" working || fail "unwritable log aborted set-state before the icon update"
tmux set-option -g @agent-log "$TMP/agent.log"

# ----- a failing alerter still focuses the pane on click -------------------
mkdir "$TMP/nbin"
printf '#!/bin/sh\necho "{\\"activationType\\":\\"contentsClicked\\"}"\nexit 1\n' > "$TMP/nbin/alerter"
chmod +x "$TMP/nbin/alerter"
p7=$(tmux split-window -d -P -F '#{pane_id}' -t "$p1")
state "$p7" working "" a-7 1 test reset
PATH="$TMP/nbin:$PATH" TMUX_PANE="$p7" "$SET" finished "" a-7 2 test </dev/null
active(){ [ "$(tmux display -pt "$1" '#{pane_active}')" = 1 ]; }
eventually active "$p7" || fail "click on a failing alerter did not focus the pane"
tmux kill-pane -t "$p7"

# ----- focused completion and stale-client notification clicks -------------
# Attach a real client to the test server from a pane of an outer server.
outer -f /dev/null new-session -d -s o -x 120 -y 40 "env -u TMUX $REAL_TMUX -S $SOCK_PATH attach -t t"
tmux set-option -g focus-events on
attached(){ [ -n "$(tmux list-clients -F '#{client_name}')" ]; }
eventually attached || fail "test client did not attach"
tmux select-pane -t "$p1"
focused(){ tmux list-clients -F '#{client_flags}' | grep -q focused; }
eventually focused || fail "attached client is not focused"
# A recording notifier: notifications land in $TMP/notified-<pane>.
mkdir "$TMP/rbin"
printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = --group ] && touch "%s/notified-$2"; shift; done\n' "$TMP" > "$TMP/rbin/alerter"
chmod +x "$TMP/rbin/alerter"
nstate(){ PATH="$TMP/rbin:$PATH" TMUX_PANE="$1" "$SET" "${@:2}" </dev/null; }
notified(){ [ -e "$TMP/notified-agent-$1" ]; }
p8=$(tmux split-window -d -P -F '#{pane_id}' -t "$p1")
nstate "$p1" working "" a-1 50 test
nstate "$p1" finished "" a-1 51 test
grep -F "pane=$p1 working->finished (focused, not notified)" "$TMP/agent.log" >/dev/null || fail "focused completion was not recognised"
[ "$(get "$p1" @agent-state):$(get "$p1" @agent-unseen)" = idle:1 ] || fail "focused completion lost its unseen marker"
sleep 0.3; ! notified "$p1" || fail "completion in the focused pane was notified"
nstate "$p1" working "" a-1 52 test
[ "$(get "$p1" @agent-unseen)" = 0 ] || fail "next prompt did not clear the unseen marker"
nstate "$p8" working "" a-8 1 test reset
nstate "$p8" finished "" a-8 2 test
[ "$(get "$p8" @agent-unseen)" = 1 ] || fail "completion in a background pane was not unseen"
eventually notified "$p8" || fail "completion in a background pane was not notified"
outer send-keys -t o -H 1b 5b 4f   # terminal focus-out
unfocused(){ ! focused; }
eventually unfocused || fail "client did not lose focus"
nstate "$p1" finished "" a-1 53 test
[ "$(get "$p1" @agent-unseen)" = 1 ] || fail "completion in an unfocused terminal was not unseen"
eventually notified "$p1" || fail "completion in an unfocused terminal was not notified"

tmux new-session -d -s other
p9=$(tmux display -pt other: '#{pane_id}')
"$AGENT/focus-pane.sh" "$p9" "$SOCK_PATH" /dev/ttys-stale-client
on_other(){ [ "$(tmux list-clients -F '#{session_name}')" = other ]; }
eventually on_other || fail "focus-pane with a stale client did not switch the attached client"

echo "PASS: hooks"
