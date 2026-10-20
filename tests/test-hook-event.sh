#!/usr/bin/env bash
# Kimi and MastraCode hooks (hook-event.sh) on an isolated tmux server, with
# their real payload shapes. A stand-in provider process runs each hook as
# its child, as the agents do: kimi as the foreground job of a pane (or a
# headless one), MastraCode as one long-lived process.
set -euo pipefail
# Run from a headless agent (claude -p), the hooks would ignore every call.
unset CLAUDE_CODE_ENTRYPOINT
ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
HOOK="$ROOT/scripts/agent/hook-event.sh"
SOCK="agent-status-hook-event-test-$$"
TMP="$(mktemp -d)"
fail(){ echo "FAIL: $1" >&2; exit 1; }
ctl(){ TMUX='' tmux -L "$SOCK" "$@"; }
# Stand-ins outside a pane's foreground outlive its server.
cleanup(){ ctl kill-server 2>/dev/null || true; pkill -f "$TMP/agent.sh" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
command -v tmux >/dev/null 2>&1 || { echo "SKIP: hook-event (tmux not installed)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: hook-event (jq not installed)"; exit 0; }
export HOME="$TMP/home"; mkdir -p "$HOME"

ctl -f /dev/null new-session -d -s t -x 120 -y 40 'exec sleep 600'
TMUX="$(ctl display -pt t:0.0 '#{socket_path},#{pid},0')"
export TMUX
tmux set-option -g default-shell "$(command -v bash)"
tmux set-option -g @agent-log "$TMP/agent.log"
get(){ tmux show-option -p -q -v -t "$1" "$2" 2>/dev/null || true; }
shown(){ printf '%s:%s' "$(get "$1" @agent-state)" "$(get "$1" @agent-unseen)"; }

# The stand-in: for each line "<payload file> <command words...>" from its
# FIFO, it runs the command as its child with the payload on stdin, then
# marks the payload done. It holds the FIFO open itself, so it never ends.
cat > "$TMP/agent.sh" <<'EOF'
exec 3<>"$1"
while read -r input command; do
  # shellcheck disable=SC2086 # the command's words
  $command < "$input" || :
  : > "$input.done"
done <&3
EOF
n=0
# start NAME FIFO HOW: a stand-in titled NAME, its hooks fed by FIFO,
# started by HOW (a function taking the shell command).
start(){ mkfifo "$2"; "$3" "exec -a '$1' bash '$TMP/agent.sh' '$2'"; }
# A pane whose own process (its foreground job) is the stand-in.
in_pane(){ ctl new-window -d -P -F '#{pane_id}' "$1"; }
# In the background of a pane's job-control shell.
in_background(){ ctl new-window -d -P -F '#{pane_id}' "bash -c \"set -m; $1 & wait\""; }
# With no terminal (run by another agent's tool), inheriting TMUX_PANE=$to.
detached(){ TMUX_PANE="$to" perl -MPOSIX -e 'setsid(); exec @ARGV' bash -c "$1" </dev/null >/dev/null 2>&1 & disown; }
# send FIFO ACTION JSON [COMMAND]: one hook through that stand-in (by default
# hook-event.sh $KIND); waits for it.
send(){
  n=$((n + 1))
  local input="$TMP/payload.$n"
  printf '%s' "$3" > "$input"
  exec 9>"$1"
  printf '%s %s %s\n' "$input" "${4:-$HOOK $KIND}" "$2" >&9
  exec 9>&-
  for _ in $(seq 1 100); do [ -e "$input.done" ] && return 0; sleep 0.05; done
  fail "hook $2 never ran: $3"
}

# ----- Kimi ------------------------------------------------------------------
KIND=kimi
# kimi retitles itself "kimi-code", cut to its command line's length.
pk=$(start kimi-code "$TMP/k" in_pane)
ev(){ send "$TMP/k" "$1" "{\"session_id\":\"s1\",\"cwd\":\"/w\",\"client_type\":\"cli\",\"hook_event_name\":\"$2\"${3:+,$3}}"; }
# TMUX_PANE comes from the pane, as for the real agent.
ev session SessionStart '"source":"startup","model":"k2"'
[ "$(get "$pk" @agent-kind):$(get "$pk" @agent-instance):$(shown "$pk")" = "kimi:kimi:s1:idle:0" ] || fail "kimi SessionStart: $(get "$pk" @agent-instance) $(shown "$pk")"
# A turn kimi starts itself (a background task's result) works, and its
# prompt doesn't name the pane.
ev working TurnStarted '"turn_id":1,"origin_kind":"task","prompt":[{"type":"text","text":"<task-notification>"}]'
[ "$(shown "$pk"):$(get "$pk" @agent-auto-description)" = "working:0:" ] || fail "kimi TurnStarted: $(shown "$pk") $(get "$pk" @agent-auto-description)"
# The prompt comes as content parts: their text names the pane.
ev working UserPromptSubmit '"prompt":[{"type":"text","text":"fix the login"},{"type":"image_url","image_url":{"url":"x"}},{"type":"text","text":"bug"}],"is_steer":false'
[ "$(get "$pk" @agent-auto-description)" = "fix the login bug" ] || fail "kimi prompt parts: $(get "$pk" @agent-auto-description)"
# A subagent's turn ends with its own Stop, under the session's id: the
# pane stays working until the main agent's.
ev working SubagentStart '"agent_name":"coder","prompt":"look around"'
ev idle Stop '"stop_hook_active":false'
[ "$(shown "$pk")" = "working:0" ] || fail "kimi subagent Stop finished the turn: $(shown "$pk")"
ev idle Stop '"stop_hook_active":false'
[ "$(shown "$pk")" = "idle:1" ] || fail "kimi main Stop did not finish: $(shown "$pk")"
[ "$(get "$pk" @agent-auto-description)" = "fix the login bug" ] || fail "a subagent's prompt renamed the pane"
# Parallel subagents ending in any way (a failure, a cancel): the last end
# is the turn's.
ev working UserPromptSubmit '"prompt":[{"type":"text","text":"again"}]'
ev working SubagentStart '"agent_name":"a"'
ev working SubagentStart '"agent_name":"b"'
ev idle StopFailure '"error_type":"rate_limit"'
ev interrupt Interrupt '"turn_id":2,"reason":"cancelled"'
[ "$(shown "$pk")" = "working:0" ] || fail "kimi subagents' ends settled the pane: $(shown "$pk")"
ev idle Stop
[ "$(shown "$pk")" = "idle:1" ] || fail "kimi turn after parallel subagents: $(shown "$pk")"
# A prompt starts the count over (a subagent that never ended).
ev working UserPromptSubmit '"prompt":[{"type":"text","text":"more"}]'
ev working SubagentStart '"agent_name":"a"'
ev working UserPromptSubmit '"prompt":[{"type":"text","text":"more"}]'
ev idle Stop
[ "$(shown "$pk")" = "idle:1" ] || fail "kimi count survived a prompt: $(shown "$pk")"
# Asks; an Esc settles idle without claiming a completion.
ev working UserPromptSubmit '"prompt":[{"type":"text","text":"more"}]'
ev blocked PreToolUse '"tool_name":"AskUserQuestion","tool_input":{},"tool_call_id":"c1"'
[ "$(shown "$pk")" = "asking:0" ] || fail "kimi AskUserQuestion: $(shown "$pk")"
ev interrupt Interrupt '"turn_id":3,"reason":"cancelled"'
[ "$(shown "$pk")" = "idle:0" ] || fail "kimi Interrupt: $(shown "$pk")"
# Compaction keeps the turn; another session's end isn't this one's.
ev working UserPromptSubmit '"prompt":[{"type":"text","text":"more"}]'
ev session SessionStart '"source":"compact"'
[ "$(shown "$pk")" = "working:0" ] || fail "kimi compaction reset the turn: $(shown "$pk")"
send "$TMP/k" end '{"session_id":"s9","hook_event_name":"SessionEnd","reason":"exit"}'
[ "$(get "$pk" @agent-instance)" = kimi:s1 ] || fail "another kimi session's end cleared the pane"
# Hooks installed by an older release run a symlink to the adapter shim.
mkdir "$TMP/legacy"; ln -s "$ROOT/scripts/kimi/agent-status.sh" "$TMP/legacy/kimi.sh"
send "$TMP/k" blocked '{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"Shell"}' "$TMP/legacy/kimi.sh"
[ "$(shown "$pk")" = "asking:0" ] || fail "kimi hook from an older release: $(shown "$pk")"
ev end SessionEnd '"reason":"exit"'
[ -z "$(get "$pk" @agent-state)$(get "$pk" @agent-kind)$(get "$pk" @agent-subagents)" ] || fail "kimi SessionEnd did not clear the pane"

# Shorter command lines cut the title shorter ("kimi -p" -> "kimi-co").
for name in kimi kimi-co kimi-cod; do
  p=$(start "$name" "$TMP/k-$name" in_pane)
  send "$TMP/k-$name" session '{"session_id":"s2","hook_event_name":"SessionStart","source":"startup"}'
  [ "$(get "$p" @agent-instance)" = kimi:s2 ] || fail "interactive kimi titled '$name' did not report"
done
# Headless runs (kimi -p, acp, web) can't be told from argv: one in the
# background of a pane, or with no terminal (run by another agent's tool),
# reports nothing, even into the pane it inherited.
p=$(start kimi-code "$TMP/k-bg" in_background)
send "$TMP/k-bg" session '{"session_id":"h1","hook_event_name":"SessionStart","source":"startup"}'
send "$TMP/k-bg" working '{"session_id":"h1","hook_event_name":"UserPromptSubmit","prompt":[{"type":"text","text":"x"}]}'
[ -z "$(get "$p" @agent-state)" ] || fail "a kimi in the background of a pane reported"
to=$pk; start kimi-code "$TMP/k-tool" detached
send "$TMP/k-tool" session '{"session_id":"s1","hook_event_name":"SessionStart","source":"startup"}'
send "$TMP/k-tool" working '{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":[{"type":"text","text":"x"}]}'
[ -z "$(get "$pk" @agent-state)" ] || fail "a kimi with no terminal reported"

# ----- MastraCode -------------------------------------------------------------
KIND=mastracode
pm=$(start mastracode "$TMP/m" in_pane)
mpid=$(ctl display -p -t "$pm" '#{pane_pid}')
mev(){ send "$TMP/m" "$1" "{\"session_id\":\"${4:-T1}\",\"cwd\":\"/w\",\"hook_event_name\":\"$2\"${3:+,$3}}"; }
# The session id is "session-init" until the first prompt creates a thread.
mev session SessionStart '' session-init
[ "$(get "$pm" @agent-kind):$(get "$pm" @agent-instance):$(shown "$pm")" = "mastracode:mastracode:$mpid:idle:0" ] || fail "mastracode SessionStart: $(get "$pm" @agent-instance) $(shown "$pm")"
mev working UserPromptSubmit '"user_message":"fix the login bug"' session-init
[ "$(shown "$pm"):$(get "$pm" @agent-auto-description)" = "working:0:fix the login bug" ] || fail "mastracode prompt: $(shown "$pm") $(get "$pm" @agent-auto-description)"
# From here on the thread's id.
mev working AgentStart '"run_id":"r1"'
mev blocked PermissionRequest '"run_id":"r1","permission_kind":"tool_approval","tool_call_id":"c1","tool_name":"execute_command"'
[ "$(shown "$pm")" = "asking:0" ] || fail "mastracode PermissionRequest after the thread id changed: $(shown "$pm")"
mev working PermissionResult '"run_id":"r1","permission_kind":"tool_approval","tool_call_id":"c1","tool_name":"execute_command","decision":"approved"'
[ "$(shown "$pm")" = "working:0" ] || fail "mastracode PermissionResult: $(shown "$pm")"
# ask_user only notifies; a suspended run's end leaves the ask.
mev blocked Notification '"reason":"ask_question","message":"Which branch?"'
[ "$(shown "$pm")" = "asking:0" ] || fail "mastracode ask_question: $(shown "$pm")"
mev idle AgentEnd '"run_id":"r1","stop_reason":"suspended"'
mev idle Stop '"stop_reason":"complete"'
[ "$(shown "$pm")" = "asking:0" ] || fail "mastracode suspended run: $(shown "$pm")"
mev working AgentStart '"run_id":"r2"'
mev blocked Notification '"reason":"agent_done"'
[ "$(shown "$pm")" = "working:0" ] || fail "mastracode agent_done notification asked: $(shown "$pm")"
mev idle AgentEnd '"run_id":"r2","stop_reason":"complete"'
[ "$(shown "$pm")" = "idle:1" ] || fail "mastracode AgentEnd: $(shown "$pm")"
# Esc: Interrupt, then the aborted run's end: idle, no completion claimed.
mev working AgentStart '"run_id":"r3"' T2
mev interrupt Interrupt '"run_id":"r3","reason":"user_interrupt"' T2
mev idle AgentEnd '"run_id":"r3","stop_reason":"aborted"' T2
mev idle Stop '"stop_reason":"aborted"' T2
[ "$(shown "$pm")" = "idle:0" ] || fail "mastracode Esc: $(shown "$pm")"
# Headless runs (a prompt argument, --acp) fire tool hooks only: another
# mastracode process never reports into this pane, nor into a plain one.
to=$pm; start mastracode "$TMP/m-h" detached
send "$TMP/m-h" working '{"session_id":"h","hook_event_name":"PreToolUse","tool_name":"view"}'
[ "$(shown "$pm")" = "idle:0" ] || fail "a headless mastracode reported into the TUI's pane: $(shown "$pm")"
send "$TMP/m-h" blocked '{"session_id":"h","hook_event_name":"PermissionRequest","tool_name":"view"}'
send "$TMP/m-h" idle '{"session_id":"h","hook_event_name":"AgentEnd","stop_reason":"complete"}'
[ "$(shown "$pm")" = "idle:0" ] || fail "a headless mastracode's ask or end reached the TUI's pane: $(shown "$pm")"
to=$(ctl new-window -d -P -F '#{pane_id}' 'exec sleep 600'); start mastracode "$TMP/m-h2" detached
send "$TMP/m-h2" working '{"session_id":"h","hook_event_name":"PreToolUse","tool_name":"view"}'
[ -z "$(get "$to" @agent-state)" ] || fail "a headless mastracode registered a plain pane"
send "$TMP/m-h2" working '{"session_id":"h","hook_event_name":"UserPromptSubmit","user_message":"not mine"}'
[ -z "$(get "$to" @agent-state)$(get "$to" @agent-auto-description)" ] || fail "an unregistered mastracode's prompt reached a plain pane"
# Hooks installed by an older release; SessionEnd carries the thread id.
ln -s "$ROOT/scripts/mastracode/agent-status.sh" "$TMP/legacy/mastracode.sh"
send "$TMP/m" working '{"session_id":"T2","hook_event_name":"PreToolUse","tool_name":"view"}' "$TMP/legacy/mastracode.sh"
[ "$(shown "$pm")" = "working:0" ] || fail "mastracode hook from an older release: $(shown "$pm")"
mev end SessionEnd '' T2
[ -z "$(get "$pm" @agent-state)$(get "$pm" @agent-kind)" ] || fail "mastracode SessionEnd did not clear the pane"
# MastraCode exits without waiting for its SessionEnd hook: an end that runs
# once the registered process is gone still clears its pane.
mev session SessionStart '' session-init
[ "$(get "$pm" @agent-instance)" = "mastracode:$mpid" ] || fail "mastracode did not register again"
tmux set-option -p -t "$pm" @agent-instance mastracode:999999
mev end SessionEnd '' T3
[ -z "$(get "$pm" @agent-state)" ] || fail "an end after the registered MastraCode exited did not clear the pane"
mev session SessionStart '' session-init
tmux set-option -p -t "$pm" @agent-instance "mastracode:$$"
mev end SessionEnd '' T3
[ "$(get "$pm" @agent-instance)" = "mastracode:$$" ] || fail "an end cleared a pane another live MastraCode registered"

echo "PASS: hook-event"
