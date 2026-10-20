#!/usr/bin/env bash
# Exercise the plugin's tmux hooks (focus, pane exit/death, window icons),
# stdin handling, compaction, locks, locale, focused completion, notification
# clicks and log failures on isolated tmux servers.
set -euo pipefail
# Run from a headless agent (claude -p), the hooks would ignore every call.
unset CLAUDE_CODE_ENTRYPOINT
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

# ----- plugin load: one entry per hook, whatever the checkout is called -----
tmux set-hook -g pane-exited 'display-message user-hook'
# Another tool's hook that runs something from its own scripts/agent
# directory is not the plugin's.
FOREIGN=': /elsewhere/scripts/agent/other.sh'
tmux set-hook -ga pane-focus-in "run-shell -b '$FOREIGN'"
tmux set-hook -ga window-layout-changed "run-shell -b '$FOREIGN'"
# A checkout in another directory (a clone not named agent-status.tmux, or a
# moved one): reloading from it, then from here, replaces its entries too.
# Its path is not ASCII, and it loads in the C locale.
ELSEWHERE="$TMP/else whére \$x'#"
mkdir "$ELSEWHERE"
cp -R "$PLUGIN_DIR/agent-status.tmux" "$PLUGIN_DIR/scripts" "$ELSEWHERE/"
LC_ALL=C bash "$ELSEWHERE/agent-status.tmux"
LC_ALL=C bash "$ELSEWHERE/agent-status.tmux"
bash "$PLUGIN_DIR/agent-status.tmux"
bash "$PLUGIN_DIR/agent-status.tmux"
for h in pane-focus-in pane-exited pane-died window-layout-changed pane-moved; do
  hooks=$(tmux show-hooks -g "$h")
  ! printf '%s\n' "$hooks" | grep -qF "$TMP/else" || fail "$h kept an entry from another checkout"
  n=$(printf '%s\n' "$hooks" | grep -cE 'scripts/agent/clear-(finished|pane)\.sh|@agent-icon-format' || true)
  [ "$n" -eq 1 ] || fail "$h has $n plugin entries after reload"
done
for h in pane-focus-in window-layout-changed; do
  n=$(tmux show-hooks -g "$h" | grep -cF "$FOREIGN" || true)
  [ "$n" -eq 1 ] || fail "$h has $n copies of another tool's scripts/agent hook after reload"
done
# Scripts run in the background, and only when there is work: a routine
# focus change, layout change or pane exit starts no process at all.
tmux show-hooks -g pane-died | grep -F "run-shell -b \"'$AGENT/clear-pane.sh'" | grep -F '#{hook_pane}' >/dev/null || fail "pane-died hook is not run-shell -b with #{hook_pane}"
tmux show-hooks -g pane-focus-in | grep -F 'if-shell -F "#{&&:#{==:#{@agent-state},idle},#{==:#{@agent-unseen},1}}"' | grep -F "run-shell -b \"'$AGENT/clear-finished.sh'" >/dev/null || fail "pane-focus-in does not check for an unseen completion in tmux"
# The icon hooks name the hook's window and write only a changed icon.
for h in pane-exited window-layout-changed pane-moved; do
  line=$(tmux show-hooks -g "$h" | grep -F '@agent-icon-format')
  [ "${line#*] }" = "run-shell -C \"if -F -t '#{hook_window}' '##{!=:##{@agent-icon},##{E:@agent-icon-format}}' { set-option -wqF -t '#{hook_window}' @agent-icon '##{E:@agent-icon-format}' }\"" ] || fail "$h hook is not a guarded icon update of its window: $line"
done
tmux show-hooks -g pane-exited | grep -F 'user-hook' >/dev/null || fail "reload dropped a user pane-exited hook"
# From here on the hooks run the copy, whose path has a space, a $, a quote,
# a # and an é: tmux and sh must still find its scripts (the focus and
# pane-died cases below).
LC_ALL=C bash "$ELSEWHERE/agent-status.tmux"

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
# A layout change recomputes an icon that is out of date.
p5=$(tmux split-window -d -P -F '#{pane_id}' -t "$p1")
tmux set-option -p -t "$p5" @agent-state asking
tmux select-layout -t "$w1" even-vertical
eventually icon_is "$w1" asking || fail "a layout change did not recompute a changed icon"
tmux kill-pane -t "$p5"
eventually icon_is "$w1" working || fail "icon not restored after the layout case"

# ----- the window a pane leaves is recomputed, wherever it is ---------------
# The hooks' own context is the pane that fired them; when that was its
# window's active pane, it is gone. Kill and let exit the active pane of a
# window that is not its session's current one, and of a window in another
# session: that window's icon is recomputed, and no other.
tmux new-session -d -s other -x 120 -y 40
for target in "$(tmux new-window -d -P -F '#{window_id}' -t t:)" "$(tmux display -p -t other: '#{window_id}')"; do
  for how in kill exit; do
    pa=$(tmux split-window -P -F '#{pane_id}' -t "$target" 'sleep 1')
    [ "$(tmux display -p -t "$target" '#{pane_id}')" = "$pa" ] || fail "the split is not its window's active pane"
    state "$pa" asking "" "a-$how" 1 test reset
    icon_is "$target" asking || fail "asking pane did not set its window's icon"
    if [ "$how" = kill ]; then tmux kill-pane -t "$pa"; fi
    eventually gone "$pa" || fail "the active pane did not go"
    eventually no_icon "$target" || fail "the active pane's $how left its window's icon: $(icon "$target")"
    icon_is "$w1" working || fail "the active pane's $how changed another window's icon"
  done
done
tmux kill-session -t other
# A window whose last pane exits is gone: nothing to recompute, nothing to
# report.
tmux new-window -d -t t: 'sleep 0.3'
sleep 1
if tmux show-messages | grep -F 'no such window' >/dev/null; then fail "a closed window's hooks reported an error"; fi

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

# ----- turns that end without Stop ----------------------------------------
p6=$(tmux split-window -d -P -F '#{pane_id}' -t "$p1")
claude "$p6" '{"session_id":"c-3","hook_event_name":"SessionStart","source":"startup"}' idle
# Esc interrupt: no Stop; the idle_prompt notification closes the turn
# without claiming an unseen completion.
claude "$p6" '{"session_id":"c-3","hook_event_name":"UserPromptSubmit"}' working
claude "$p6" '{"session_id":"c-3","hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input"}' idle
[ "$(get "$p6" @agent-state):$(get "$p6" @agent-unseen)" = idle:0 ] || fail "idle_prompt did not close an interrupted turn"
# A denied permission prompt also ends the turn without Stop.
claude "$p6" '{"session_id":"c-3","hook_event_name":"PermissionRequest"}' asking
claude "$p6" '{"session_id":"c-3","hook_event_name":"Notification","notification_type":"idle_prompt"}' idle
[ "$(get "$p6" @agent-state)" = idle ] || fail "idle_prompt did not close a denied permission prompt"
# An API error ends the turn with StopFailure: an unseen completion.
claude "$p6" '{"session_id":"c-3","hook_event_name":"UserPromptSubmit"}' working
claude "$p6" '{"session_id":"c-3","hook_event_name":"StopFailure","error":"rate_limit"}' finished
[ "$(get "$p6" @agent-state):$(get "$p6" @agent-unseen)" = idle:1 ] || fail "StopFailure did not finish the turn"
# A later idle_prompt must not acknowledge that completion.
claude "$p6" '{"session_id":"c-3","hook_event_name":"Notification","notification_type":"idle_prompt"}' idle
[ "$(get "$p6" @agent-unseen)" = 1 ] || fail "idle_prompt acknowledged an unseen completion"
# A headless claude -p started from the pane reports nothing into it: its
# SessionStart would take the pane over, and its end (even when it claims the
# pane's own session) would clear the pane's agent.
headless(){ printf '%s\n' "$2" | CLAUDE_CODE_ENTRYPOINT=sdk-cli AGENT_STATUS_KIND=claude TMUX_PANE="$1" "${@:3}"; }
headless "$p6" '{"session_id":"c-9","hook_event_name":"SessionStart","source":"startup"}' "$SET" idle
headless "$p6" '{"session_id":"c-9","hook_event_name":"UserPromptSubmit"}' "$SET" working
[ "$(get "$p6" @agent-state):$(get "$p6" @agent-instance)" = idle:claude:c-3 ] || fail "headless claude -p took over the pane"
headless "$p6" '{"session_id":"c-3","reason":"other"}' "$AGENT/clear-state.sh"
[ "$(get "$p6" @agent-state):$(get "$p6" @agent-instance)" = idle:claude:c-3 ] || fail "headless claude -p cleared the pane's agent"
tmux set-option -p -u -t "$p6" @agent-auto-description
headless "$p6" '{"prompt":"headless task"}' "$AGENT/auto-desc.sh" set
[ -z "$(get "$p6" @agent-auto-description)" ] || fail "headless claude -p described the pane"
tmux kill-pane -t "$p6"

# ----- a first prompt that tmux could read as a command separator ----------
w7=$(tmux new-window -d -P -F '#{window_id}' -t t:)
p7=$(tmux display -p -t "$w7" '#{pane_id}')
claude "$p7" '{"session_id":"c-7","hook_event_name":"SessionStart","source":"startup"}' idle
claude "$p7" '{"session_id":"c-7","hook_event_name":"UserPromptSubmit","prompt":" ; "}' working
[ "$(get "$p7" @agent-auto-description)" = ";" ] || fail "a ';' prompt was not kept: [$(get "$p7" @agent-auto-description)]"
icon_is "$w7" working || fail "a ';' prompt left the window icon: $(icon "$w7")"
grep -F "pane=$p7 idle->working" "$TMP/agent.log" >/dev/null || fail "a ';' prompt was not logged"
tmux kill-window -t "$w7"

# ----- a permission prompt outlasts other tools' hooks --------------------
p6=$(tmux split-window -d -P -F '#{pane_id}' -t "$p1")
ev(){ claude "$p6" "{\"session_id\":\"c-4\",\"hook_event_name\":\"$1\"${3:+,$3}}" "$2"; }
tool(){ ev "$1" "$2" "\"tool_name\":\"$3\"${4:+,\"agent_id\":\"$4\"}${5:+,$5}"; }
shown(){ printf '%s:%s' "$(get "$p6" @agent-state)" "$(get "$p6" @agent-asks)"; }
ev SessionStart idle '"source":"startup"'
# One hook process per event: set-state keeps the first prompt as the title.
ev UserPromptSubmit working '"prompt":"  check   the\nlogs\u001b  "'
[ "$(get "$p6" @agent-auto-description)" = "check the logs" ] || fail "first prompt not kept: [$(get "$p6" @agent-auto-description)]"
# Subagent a1 asks while subagent a2 and the main thread keep running tools,
# one of them a Bash too.
tool PermissionRequest asking Bash a1
tool PreToolUse working Read a2
tool PostToolUse working Read a2
tool PostToolUse working Bash
[ "$(shown)" = "asking:a1/Bash" ] || fail "other agents' tool hooks ended a permission prompt: $(shown)"
# The main thread asks too, for a WebFetch beside its parallel Reads.
tool PermissionRequest asking WebFetch
tool PostToolUse working Read
tool PostToolUse working Bash a1
[ "$(shown)" = "asking:/WebFetch" ] || fail "an approved tool did not end only its own ask: $(shown)"
# The approved WebFetch fails: PostToolUseFailure ends the ask.
tool PostToolUseFailure working WebFetch
[ "$(shown)" = "working:" ] || fail "PostToolUseFailure did not end the ask: $(shown)"
# An agent that moves on to another tool is no longer asking.
tool PermissionRequest asking Edit a3
tool PreToolUse working Grep a3
[ "$(shown)" = "working:" ] || fail "the asking agent's next tool did not end its ask: $(shown)"
# Hooks without PostToolUseFailure miss a subagent's approved tool failing:
# the main thread's Task returning ends that ask, unless a background
# subagent (here the one just launched) may still be asking.
tool PermissionRequest asking Bash a5
tool PermissionRequest asking WebFetch
tool PostToolUse working Task '' '"background_tasks":[{"id":"a6","type":"subagent","status":"running"}]'
[ "$(shown)" = "asking:a5/Bash /WebFetch" ] || fail "a background Task launch ended a subagent's ask: $(shown)"
tool PostToolUse working Agent '' '"background_tasks":[]'
[ "$(shown)" = "asking:/WebFetch" ] || fail "a returned Task did not end its subagent's ask: $(shown)"
tool PostToolUse working WebFetch
[ "$(shown)" = "working:" ] || fail "the approved WebFetch did not end its ask: $(shown)"
# A Stop held by a background subagent that asks keeps the pane asking; the
# final Stop ends every ask.
tool PermissionRequest asking Bash a4
ev Stop finished '"background_tasks":[{"id":"a4","type":"subagent","status":"running"}]'
[ "$(shown)" = "asking:a4/Bash" ] || fail "a held Stop dropped a background agent's ask: $(shown)"
tool PermissionRequest asking Bash
ev Stop finished '"background_tasks":[]'
[ "$(shown):$(get "$p6" @agent-unseen)" = "idle::1" ] || fail "the final Stop did not end the asks: $(shown)"
# Later prompts keep the title; a new session clears it, a compaction doesn't.
ev UserPromptSubmit working '"prompt":"something else"'
[ "$(get "$p6" @agent-auto-description)" = "check the logs" ] || fail "a later prompt replaced the title"
ev SessionStart idle '"source":"compact"'
[ "$(get "$p6" @agent-auto-description)" = "check the logs" ] || fail "compaction cleared the title"
ev SessionStart idle '"source":"clear"'
[ -z "$(get "$p6" @agent-auto-description)" ] || fail "a new session kept the title"
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
# A report that repeats the pane's state settles without the lock: parallel
# tool hooks never queue behind each other.
holder "$p1" hang & hpid=$!
eventually test -s "$TMP/lockpath" || fail "hung holder did not lock"
printf '%s\n' '{"session_id":"c-1","hook_event_name":"PreToolUse"}' | TMUX_PANE="$p1" "$SET" working & pid=$!
finishes_within 1 "$pid" || fail "a repeated report waited for the pane lock"
kill "$hpid" 2>/dev/null || true; wait "$hpid" 2>/dev/null || true
rm -f "$(cat "$TMP/lockpath")"
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
tmux set-option -w -t "$w1" @agent-icon stale
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
# A recording notifier: notifications land in $TMP/notified-<pane>, the last
# message in $TMP/message.
mkdir "$TMP/rbin"
printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do case "$1" in --group) touch "%s/notified-$2" ;; --message) printf %%s "$2" > "%s/message" ;; esac; shift; done\n' "$TMP" "$TMP" > "$TMP/rbin/alerter"
chmod +x "$TMP/rbin/alerter"
nstate(){ PATH="$TMP/rbin:$PATH" TMUX_PANE="$1" "$SET" "${@:2}" </dev/null; }
notified(){ [ -e "$TMP/notified-agent-$1" ]; }
p8=$(tmux new-window -d -P -F '#{pane_id}' -t t:)
nstate "$p1" working "" a-1 50 test
nstate "$p1" finished "" a-1 51 test
grep -F "pane=$p1 working->finished (focused, not notified)" "$TMP/agent.log" >/dev/null || fail "focused completion was not recognised"
[ "$(get "$p1" @agent-state):$(get "$p1" @agent-unseen)" = idle:1 ] || fail "focused completion lost its unseen marker"
sleep 0.3; ! notified "$p1" || fail "completion in the focused pane was notified"
nstate "$p1" asking "" a-1 52 test
sleep 0.3; ! notified "$p1" || fail "permission prompt in the focused pane was notified"
nstate "$p1" working "" a-1 53 test
[ "$(get "$p1" @agent-unseen)" = 0 ] || fail "next prompt did not clear the unseen marker"
# Only the most recently active client counts: one left attached elsewhere
# (a phone over mosh, which never reports focus-out) must not hide the
# completion from the user at another.
local_client=$(tmux list-clients -F '#{client_name}')
tmux new-session -d -s side
outer new-window -d -t o "env -u TMUX $REAL_TMUX -S $SOCK_PATH attach -t side"
both(){ [ "$(tmux list-clients | wc -l | tr -d ' ')" = 2 ]; }
eventually both || fail "second test client did not attach"
sleep 1.1; outer send-keys -t o:1 x   # client_activity counts seconds
nstate "$p1" finished "" a-1 54 test
eventually notified "$p1" || fail "a client active elsewhere did not get the completion"
rm -f "$TMP/notified-agent-$p1"
# Selecting a pane another client already shows fires no pane-focus-in: a
# notification click still marks it seen.
ps=$(tmux display -pt side: '#{pane_id}')
nstate "$ps" working "" s-1 1 test reset
nstate "$ps" finished "" s-1 2 test
[ "$(get "$ps" @agent-unseen)" = 1 ] || fail "completion on the second client was not unseen"
"$AGENT/focus-pane.sh" "$ps" "$SOCK_PATH" "$local_client"
eventually test "$(get "$ps" @agent-unseen)" = 0 || fail "notification click did not mark a pane seen"
outer kill-window -t o:1
one(){ [ "$(tmux list-clients | wc -l | tr -d ' ')" = 1 ]; }
eventually one || fail "second test client did not detach"
tmux switch-client -c "$local_client" -t "$p1"
tmux kill-session -t side
nstate "$p1" working "" a-1 55 test
nstate "$p8" working "" a-8 1 test reset
nstate "$p8" finished "" a-8 2 test
[ "$(get "$p8" @agent-unseen)" = 1 ] || fail "completion in a background pane was not unseen"
eventually notified "$p8" || fail "completion in a background pane was not notified"
# Focusing it marks it seen (the pane-focus-in hook) and recomputes the icon.
icon_is "$p8" finished || fail "background completion did not show as finished"
tmux select-window -t "$p8"
seen(){ [ "$(get "$p8" @agent-unseen)" = 0 ]; }
eventually seen || fail "focusing a finished pane did not mark it seen"
eventually icon_is "$p8" idle || fail "focusing a finished pane did not recompute its icon"
tmux select-window -t "$p1"
# The message is one line without control characters, cut to 240 characters
# (not bytes, whatever the locale).
rm -f "$TMP/message"
LC_ALL=C nstate "$p8" asking $'x\033\n'"$(printf 'é%.0s' $(seq 1 300))" a-8 3 test
eventually test -s "$TMP/message" || fail "permission prompt in a background pane was not notified"
[ "$(cat "$TMP/message")" = "x $(printf 'é%.0s' $(seq 1 238))" ] || fail "notification message not cleaned and cut: $(cat "$TMP/message")"
tmux kill-window -t "$p8"
outer send-keys -t o -H 1b 5b 4f   # terminal focus-out
unfocused(){ ! focused; }
eventually unfocused || fail "client did not lose focus"
nstate "$p1" finished "" a-1 56 test
[ "$(get "$p1" @agent-unseen)" = 1 ] || fail "completion in an unfocused terminal was not unseen"
eventually notified "$p1" || fail "completion in an unfocused terminal was not notified"

# A Claude agent-team lead's completion waits while teammates are alive and is
# dropped when the lead resumes, a newer completion supersedes it, or the pane
# is seen. Without teammates it is immediate.
tmux set-option -g @agent-notify-team-delay 1
p10=$(tmux split-window -d -P -F '#{pane_id}' -t "$p1")
lead(){ printf '{"session_id":"c-10","hook_event_name":"%s","background_tasks":%s}\n' "$2" "${3:-[]}" | \
  PATH="$TMP/rbin:$PATH" TMUX_PANE="$p10" AGENT_STATUS_KIND=claude "$SET" "$1"; }
team='[{"id":"t1","type":"teammate","status":"running"}]'
lead working SessionStart
lead working UserPromptSubmit
lead finished Stop "$team"
[ "$(get "$p10" @agent-state):$(get "$p10" @agent-unseen)" = idle:1 ] || fail "team delay delayed the pane state"
lead working PreToolUse
sleep 1.5; ! notified "$p10" || fail "lead completion that resumed within the delay was notified"
lead finished Stop "$team"
"$AGENT/clear-finished.sh" "$p10" </dev/null
sleep 1.5; ! notified "$p10" || fail "lead completion seen within the delay was notified"
lead working PreToolUse
lead finished Stop "$team"
eventually notified "$p10" || fail "lead completion that stayed finished was not notified"
rm -f "$TMP/notified-agent-$p10"
# A newer state change cancels a pending delayed send: here the immediate
# completion notifies once, and the earlier team Stop must not notify again.
lead working UserPromptSubmit
lead finished Stop "$team"
lead working UserPromptSubmit
lead finished Stop
eventually notified "$p10" || fail "completion without teammates was not notified"
rm -f "$TMP/notified-agent-$p10"
sleep 1.5; ! notified "$p10" || fail "superseded delayed completion was notified"
tmux kill-pane -t "$p10"

tmux new-session -d -s other
p9=$(tmux display -pt other: '#{pane_id}')
"$AGENT/focus-pane.sh" "$p9" "$SOCK_PATH" /dev/ttys-stale-client
on_other(){ [ "$(tmux list-clients -F '#{session_name}')" = other ]; }
eventually on_other || fail "focus-pane with a stale client did not switch the attached client"

# A click switches the local client, never a remote one (a phone over mosh:
# here a client under a process named mosh-server), even when the remote one
# was captured at notify time.
ln -s "$(command -v bash)" "$TMP/mosh-server"
local_client=$(tmux list-clients -F '#{client_name}')
outer new-window -d -t o "$TMP/mosh-server -c 'env -u TMUX $REAL_TMUX -S $SOCK_PATH attach -t other; :'"
both(){ [ "$(tmux list-clients | wc -l | tr -d ' ')" = 2 ]; }
eventually both || fail "remote test client did not attach"
remote_client=$(tmux list-clients -F '#{client_name}' | grep -vxF "$local_client")
"$AGENT/focus-pane.sh" "$p1" "$SOCK_PATH" "$remote_client"
on(){ tmux list-clients -F '#{client_name} #{session_name}' | grep -qxF "$1 $2"; }
eventually on "$local_client" t || fail "click did not switch the local client"
on "$remote_client" other || fail "click switched the remote client"

echo "PASS: hooks"
