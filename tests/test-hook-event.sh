#!/usr/bin/env bash
# Kimi, MastraCode, Gemini CLI and Qwen Code hooks (hook-event.sh) on an
# isolated tmux server, with their real payload shapes. A stand-in provider
# process runs each hook as its child, as the agents do: kimi, gemini and
# qwen as the foreground job of a pane (or a headless one), MastraCode as one
# long-lived process.
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
cleanup(){ ctl kill-server 2>/dev/null || true; pkill -f "$TMP/agent.sh" 2>/dev/null || true; pkill -f "$TMP/bin/gemini" 2>/dev/null || true; pkill -f "$TMP/bin/qwen" 2>/dev/null || true; rm -rf "$TMP"; }
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

# ----- Gemini CLI -------------------------------------------------------------
# Gemini's child process runs the hooks: `node --max-old-space-size=N
# .../bin/gemini [args]`. The stand-in has that shape (a script named gemini
# after an option, its FIFO in the environment), and Gemini's hook
# environment: GEMINI_SESSION_ID is the payload's session_id.
mkdir "$TMP/bin"
# shellcheck disable=SC2016 # the stand-in's own variable
sed 's/"\$1"/"$GEMINI_FIFO"/' "$TMP/agent.sh" > "$TMP/bin/gemini"
gstart(){ mkfifo "$2"; "$3" "GEMINI_FIFO='$2' exec -a node bash --norc '$TMP/bin/gemini' $1"; }
KIND=gemini
pg=$(gstart "" "$TMP/g" in_pane)
# gev FIFO ACTION EVENT SESSION [FIELDS]: one hook, as Gemini sends it.
gev(){ send "$1" "$2" "{\"session_id\":\"$4\",\"transcript_path\":\"/h/.gemini/tmp/w/chats/session-$4.jsonl\",\"cwd\":\"/w\",\"hook_event_name\":\"$3\",\"timestamp\":\"2026-10-20T13:46:00.000Z\"${5:+,$5}}" "env GEMINI_SESSION_ID=$4 $HOOK gemini"; }
gev "$TMP/g" session SessionStart g1 '"source":"startup"'
[ "$(get "$pg" @agent-kind):$(get "$pg" @agent-instance):$(shown "$pg")" = "gemini:gemini:g1:idle:0" ] || fail "gemini SessionStart: $(get "$pg" @agent-instance) $(shown "$pg")"
gev "$TMP/g" working BeforeAgent g1 '"prompt":"fix the login bug"'
[ "$(shown "$pg"):$(get "$pg" @agent-auto-description)" = "working:0:fix the login bug" ] || fail "gemini BeforeAgent: $(shown "$pg") $(get "$pg" @agent-auto-description)"
gev "$TMP/g" blocked Notification g1 '"notification_type":"ToolPermission","message":"Tool Confirm Shell Command requires execution","details":{"type":"exec","title":"Confirm Shell Command","command":"make test","rootCommand":"make"}'
[ "$(shown "$pg")" = "asking:0" ] || fail "gemini Notification: $(shown "$pg")"
# The approved tool returns.
gev "$TMP/g" tool AfterTool g1 '"tool_name":"run_shell_command","tool_input":{"command":"make test"},"tool_response":{"llmContent":"ok","returnDisplay":"ok"}'
[ "$(shown "$pg")" = "working:0" ] || fail "gemini AfterTool: $(shown "$pg")"
# AfterAgent carries the turn's prompt too: it doesn't rename the pane.
gev "$TMP/g" idle AfterAgent g1 '"prompt":"something else","prompt_response":"Done.","stop_hook_active":false'
[ "$(shown "$pg"):$(get "$pg" @agent-auto-description)" = "idle:1:fix the login bug" ] || fail "gemini AfterAgent: $(shown "$pg") $(get "$pg" @agent-auto-description)"
# /clear: SessionEnd(clear) keeps the pane, SessionStart(clear) starts over
# under the new id.
gev "$TMP/g" end SessionEnd g1 '"reason":"clear"'
[ "$(get "$pg" @agent-instance)" = gemini:g1 ] || fail "gemini SessionEnd(clear) cleared the pane"
gev "$TMP/g" session SessionStart g2 '"source":"clear"'
[ "$(get "$pg" @agent-instance):$(shown "$pg"):$(get "$pg" @agent-auto-description)" = "gemini:g2:idle:0:" ] || fail "gemini SessionStart(clear): $(get "$pg" @agent-instance) $(shown "$pg")"
# An in-app /resume switches the session without an event: a tool hook of
# the old one is ignored, and the next prompt rebinds the pane.
gev "$TMP/g" working BeforeAgent g2 '"prompt":"first"'
gev "$TMP/g" tool AfterTool g1 '"tool_name":"read_file"'
gev "$TMP/g" idle AfterAgent g1 '"prompt":"x","prompt_response":"y","stop_hook_active":false'
[ "$(get "$pg" @agent-instance):$(shown "$pg")" = "gemini:g2:working:0" ] || fail "another gemini session's hooks reached the pane: $(get "$pg" @agent-instance) $(shown "$pg")"
gev "$TMP/g" working BeforeAgent g3 '"prompt":"resumed work"'
[ "$(get "$pg" @agent-instance):$(shown "$pg"):$(get "$pg" @agent-auto-description)" = "gemini:g3:working:0:resumed work" ] || fail "gemini prompt after /resume: $(get "$pg" @agent-instance) $(shown "$pg") $(get "$pg" @agent-auto-description)"
# Gemini fires SessionEnd(exit) up to three times as it quits.
gev "$TMP/g" end SessionEnd g3 '"reason":"exit"'
gev "$TMP/g" end SessionEnd g3 '"reason":"exit"'
[ -z "$(get "$pg" @agent-state)$(get "$pg" @agent-kind)$(get "$pg" @agent-instance)$(get "$pg" @agent-auto-description)" ] || fail "gemini SessionEnd did not clear the pane"
# A prompt argument stays interactive in a terminal, as -i does; -p and an
# editor's ACP server are headless, and so is a gemini in the background of
# a pane or with no terminal.
n_g=0
for args in "'fix it'" "-m pro 'fix it'" "-i 'fix it'" "--prompt-interactive=x" "-r latest" "-r"; do
  n_g=$((n_g + 1))
  p=$(gstart "$args" "$TMP/gi-$n_g" in_pane)
  gev "$TMP/gi-$n_g" session SessionStart i$n_g '"source":"startup"'
  [ "$(get "$p" @agent-instance)" = "gemini:i$n_g" ] || fail "interactive gemini $args did not report"
done
for args in "-p 'fix it'" "--prompt='fix it'" "-m pro -p x" "-y --prompt x" "--acp" "--experimental-acp"; do
  n_g=$((n_g + 1))
  p=$(gstart "$args" "$TMP/gh-$n_g" in_pane)
  gev "$TMP/gh-$n_g" session SessionStart h$n_g '"source":"startup"'
  gev "$TMP/gh-$n_g" working BeforeAgent h$n_g '"prompt":"x"'
  [ -z "$(get "$p" @agent-state)" ] || fail "headless gemini $args reported"
done
p=$(gstart "" "$TMP/g-bg" in_background)
gev "$TMP/g-bg" session SessionStart b1 '"source":"startup"'
[ -z "$(get "$p" @agent-state)" ] || fail "a gemini in the background of a pane reported"
to=$pg; gstart "" "$TMP/g-tool" detached
gev "$TMP/g-tool" session SessionStart t1 '"source":"startup"'
gev "$TMP/g-tool" working BeforeAgent t1 '"prompt":"x"'
[ -z "$(get "$pg" @agent-state)" ] || fail "a gemini with no terminal reported"
# Gemini shows a hook's output and takes exit status 2 as a block: the hook
# prints nothing and succeeds even when a state script fails.
mkdir "$TMP/broken"; cp "$HOOK" "$TMP/broken/"
printf '#!/bin/sh\necho out; echo err >&2; exit 2\n' > "$TMP/broken/set-state.sh"; chmod +x "$TMP/broken/set-state.sh"
for action in working idle tool; do
  rc=0; out=$(printf '{"session_id":"g1","hook_event_name":"AfterAgent"}' | TMUX_PANE=$pg GEMINI_SESSION_ID=g1 "$TMP/broken/hook-event.sh" gemini $action 2>&1) || rc=$?
  [ "$rc:$out" = "0:" ] || fail "gemini $action hook printed or failed: $rc $out"
done

# ----- Qwen Code ---------------------------------------------------------------
# Qwen runs its CLI, and so its hooks, in the launcher's own process: `node
# .../bin/qwen [args]`. Its payloads are Claude Code's; SessionStart,
# SessionEnd and the idle prompt's Notification are as Qwen 0.25.3 sent them.
# shellcheck disable=SC2016 # the stand-in's own variable
sed 's/"\$1"/"$QWEN_FIFO"/' "$TMP/agent.sh" > "$TMP/bin/qwen"
qstart(){ mkfifo "$2"; "$3" "QWEN_FIFO='$2' exec -a node bash '$TMP/bin/qwen' $1"; }
KIND=qwen
pq=$(qstart "" "$TMP/q" in_pane)
# qev FIFO ACTION EVENT SESSION [FIELDS]: one hook, as Qwen sends it.
qev(){ send "$1" "$2" "{\"session_id\":\"$4\",\"transcript_path\":\"/h/.qwen/projects/-w/chats/$4.jsonl\",\"cwd\":\"/w\",\"hook_event_name\":\"$3\",\"timestamp\":\"2026-10-20T14:03:12.766Z\",\"permission_mode\":\"auto\"${5:+,$5}}"; }
q(){ qev "$TMP/q" "$1" "$2" "${4:-q1}" "${3:-}"; }
q session SessionStart '"source":"startup","model":"coder-model"'
[ "$(get "$pq" @agent-kind):$(get "$pq" @agent-instance):$(shown "$pq"):$(get "$pq" @agent-transcript)" = "qwen:qwen:q1:idle:0:/h/.qwen/projects/-w/chats/q1.jsonl" ] \
  || fail "qwen SessionStart: $(get "$pq" @agent-instance) $(shown "$pq") $(get "$pq" @agent-transcript)"
q working UserPromptSubmit '"prompt_id":"p1","prompt":"fix the login bug","submitted_prompt":"fix the login bug"'
[ "$(shown "$pq"):$(get "$pq" @agent-auto-description)" = "working:0:fix the login bug" ] || fail "qwen prompt: $(shown "$pq") $(get "$pq" @agent-auto-description)"
# A permission prompt asks; Qwen runs the tool only once it is answered, so
# its PreToolUse, however soon, ends the ask.
q blocked PermissionRequest '"tool_name":"run_shell_command","tool_input":{"command":"make test"},"permission_suggestions":null'
[ "$(shown "$pq")" = "asking:0" ] || fail "qwen PermissionRequest: $(shown "$pq")"
q working PreToolUse '"tool_name":"run_shell_command","tool_input":{"command":"make test"},"tool_use_id":"c1","tool_call_id":"c1"'
[ "$(shown "$pq"):$(get "$pq" @agent-asks)" = "working:0:" ] || fail "qwen approved tool still asks: $(shown "$pq") $(get "$pq" @agent-asks)"
q working PostToolUse '"tool_name":"run_shell_command","tool_input":{"command":"make test"},"tool_response":{"llmContent":"ok"},"tool_use_id":"c1","tool_call_id":"c1"'
q idle Stop '"stop_hook_active":false,"last_assistant_message":"Done.","background_tasks":[],"crons":[]'
[ "$(shown "$pq")" = "idle:1" ] || fail "qwen Stop: $(shown "$pq")"
# The idle prompt that follows a turn keeps it finished.
q interrupt Notification '"message":"Qwen Code is waiting for your input","notification_type":"idle_prompt","title":"Waiting for input"'
[ "$(shown "$pq")" = "idle:1" ] || fail "qwen idle prompt after a turn: $(shown "$pq")"
# A denial (or an Esc) ends the turn without Stop: the idle prompt settles it.
q working UserPromptSubmit '"prompt":"edit it"'
q blocked PermissionRequest '"tool_name":"edit","tool_input":{"file_path":"/w/a"}'
q interrupt Notification '"message":"Qwen Code is waiting for your input","notification_type":"idle_prompt","title":"Waiting for input"'
[ "$(shown "$pq"):$(get "$pq" @agent-asks)" = "idle:0:" ] || fail "qwen denial: $(shown "$pq") $(get "$pq" @agent-asks)"
# The model's question asks until it is answered; a subagent's ask outlasts
# the main thread's tools and ends with its own next tool.
q working UserPromptSubmit '"prompt":"ask me"'
q blocked PermissionRequest '"tool_name":"ask_user_question","tool_input":{"questions":[]}'
q working PostToolUse '"tool_name":"ask_user_question","tool_use_id":"c2","tool_call_id":"c2"'
[ "$(shown "$pq")" = "working:0" ] || fail "qwen answered question: $(shown "$pq")"
q blocked PermissionRequest '"agent_id":"a1","tool_name":"run_shell_command","tool_input":{"command":"ls"}'
q working PreToolUse '"tool_name":"read_file","tool_use_id":"c3","tool_call_id":"c3"'
[ "$(shown "$pq")" = "asking:0" ] || fail "qwen main thread ended a subagent's ask: $(shown "$pq")"
q working PreToolUse '"agent_id":"a1","tool_name":"run_shell_command","tool_use_id":"c4","tool_call_id":"c4"'
[ "$(shown "$pq")" = "working:0" ] || fail "qwen subagent's approved tool: $(shown "$pq")"
# A Stop while a background agent runs isn't the end: its result starts a
# turn of Qwen's own, whose Stop is.
q idle Stop '"background_tasks":[{"id":"b1","status":"running","agent_type":"general-purpose","started_at":"2026-10-20T14:03:12.766Z","description":"scan"}],"crons":[]'
[ "$(shown "$pq")" = "working:0" ] || fail "qwen Stop with a background agent running: $(shown "$pq")"
q idle Stop '"background_tasks":[{"id":"b1","status":"completed","agent_type":"general-purpose","started_at":"2026-10-20T14:03:12.766Z","description":"scan"}],"crons":[]'
[ "$(shown "$pq")" = "idle:1" ] || fail "qwen Stop after the background agent: $(shown "$pq")"
# An API error ends the turn; compaction keeps it.
q working UserPromptSubmit '"prompt":"more"'
q session SessionStart '"source":"compact","model":"coder-model"'
[ "$(shown "$pq")" = "working:0" ] || fail "qwen compaction reset the turn: $(shown "$pq")"
q idle StopFailure '"error":"rate_limit","error_details":"429","last_assistant_message":""'
[ "$(shown "$pq")" = "idle:1" ] || fail "qwen StopFailure: $(shown "$pq")"
# /clear: SessionEnd(clear) keeps the pane, SessionStart(clear) starts over
# under the new id; then the idle prompt.
q end SessionEnd '"prompt_id":"q1########0","reason":"clear"'
[ "$(get "$pq" @agent-instance)" = qwen:q1 ] || fail "qwen SessionEnd(clear) cleared the pane"
q session SessionStart '"prompt_id":"q1########0","source":"clear","model":"coder-model"' q2
q interrupt Notification '"prompt_id":"q1########0","message":"Qwen Code is waiting for your input","notification_type":"idle_prompt","title":"Waiting for input"' q2
[ "$(get "$pq" @agent-instance):$(shown "$pq"):$(get "$pq" @agent-auto-description)" = "qwen:q2:idle:0:" ] || fail "qwen /clear: $(get "$pq" @agent-instance) $(shown "$pq")"
q end SessionEnd '"reason":"prompt_input_exit"' q1
[ "$(get "$pq" @agent-instance)" = qwen:q2 ] || fail "another qwen session's end cleared the pane"
q end SessionEnd '"reason":"prompt_input_exit"' q2
[ -z "$(get "$pq" @agent-state)$(get "$pq" @agent-kind)$(get "$pq" @agent-instance)" ] || fail "qwen SessionEnd did not clear the pane"
# A prompt argument, a subcommand, -p and --acp run headless; -i keeps a
# prompt interactive. Option values (lists too) are not prompts.
n_q=0
for args in "-i 'fix it'" "--prompt-interactive=x" "-m x -y" "-r" "-r abc" "--resume -y" "-c" "--sandbox docker" "-o json" "--auth-type openai" "-e a b --yolo" "--add-dir a b -m x" "-y -i 'x y'"; do
  n_q=$((n_q + 1))
  p=$(qstart "$args" "$TMP/qi-$n_q" in_pane)
  qev "$TMP/qi-$n_q" session SessionStart i$n_q '"source":"startup"'
  [ "$(get "$p" @agent-instance)" = "qwen:i$n_q" ] || fail "interactive qwen $args did not report"
done
for args in "'fix the bug'" "fix" "-p hi" "--prompt=hi" "-m x 'do it'" "--approval-mode yolo 'do it'" "--acp" "--experimental-acp" "serve" "review run"; do
  n_q=$((n_q + 1))
  p=$(qstart "$args" "$TMP/qh-$n_q" in_pane)
  qev "$TMP/qh-$n_q" session SessionStart h$n_q '"source":"startup"'
  qev "$TMP/qh-$n_q" working UserPromptSubmit h$n_q '"prompt":"x"'
  [ -z "$(get "$p" @agent-state)" ] || fail "headless qwen $args reported"
done
# So is one in the background of a pane, or with no terminal.
p=$(qstart "" "$TMP/q-bg" in_background)
qev "$TMP/q-bg" session SessionStart b1 '"source":"startup"'
[ -z "$(get "$p" @agent-state)" ] || fail "a qwen in the background of a pane reported"
to=$(qstart "" "$TMP/q2" in_pane)
qev "$TMP/q2" session SessionStart t0 '"source":"startup"'
qstart "" "$TMP/q-tool" detached
qev "$TMP/q-tool" session SessionStart t1 '"source":"startup"'
qev "$TMP/q-tool" working UserPromptSubmit t1 '"prompt":"x"'
[ "$(get "$to" @agent-instance):$(shown "$to")" = "qwen:t0:idle:0" ] || fail "a qwen with no terminal reported: $(get "$to" @agent-instance) $(shown "$to")"
# Qwen gives a SessionStart or prompt hook's output to the model and takes
# exit status 2 as a block: the hook prints nothing and succeeds even when a
# state script fails.
cp "$TMP/broken/set-state.sh" "$TMP/broken/clear-state.sh"
for action in session working blocked idle interrupt end; do
  rc=0; out=$(printf '{"session_id":"q1","hook_event_name":"SessionStart","source":"startup"}' | TMUX_PANE=$pq "$TMP/broken/hook-event.sh" qwen $action 2>&1) || rc=$?
  [ "$rc:$out" = "0:" ] || fail "qwen $action hook printed or failed: $rc $out"
done

echo "PASS: hook-event"
