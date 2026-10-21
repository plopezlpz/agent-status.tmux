#!/usr/bin/env bash
# Codex: the hooks.json installer (other tools' hooks keep their place, so
# Codex keeps trusting them), and the hooks themselves on an isolated tmux
# server: payloads per event, sticky asks, headless runs.
set -euo pipefail
# Run from a headless agent (claude -p), the hooks would ignore every call.
unset CLAUDE_CODE_ENTRYPOINT CODEX_HOME
ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
HOOK="$ROOT/scripts/agent/hook-event.sh"
SOCK="agent-status-codex-test-$$"
TMP="$(mktemp -d)"
fail(){ echo "FAIL: $1" >&2; exit 1; }
ctl(){ TMUX='' tmux -L "$SOCK" "$@"; }
cleanup(){ ctl kill-server 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
command -v jq >/dev/null 2>&1 || { echo "SKIP: codex (jq missing)"; exit 0; }
export HOME="$TMP/home"; mkdir -p "$HOME"
install(){ bash "$ROOT/manage-provider.sh" "${1:-install}" codex >/dev/null; }

# ----- installer -------------------------------------------------------------
export CODEX_HOME="$TMP/codex"; mkdir "$CODEX_HOME"
H="$CODEX_HOME/hooks.json"
# Other tools' hooks, formatted as jq writes them (so an uninstall can be
# compared byte for byte), with keys in their own order.
jq . > "$H" <<'EOF'
{"description":"mine","hooks":{
  "SessionStart":[{"hooks":[{"command":"/opt/notify.sh","type":"command"}]},
    {"hooks":[{"command":"bash '/opt/other state.sh' session","timeout":10,"type":"command"}]},
    {"matcher":"*","hooks":[{"command":"other-tool hook --agent codex 2>/dev/null || true","timeout":10,"type":"command"}]}],
  "Stop":[{"hooks":[{"type":"command","command":": form=1; if [ -n \"${X-}\" ]; then /bin/sh \"$X/hook.sh\" || :; else cat >/dev/null; fi","timeout":10}]}],
  "SubagentStart":[{"hooks":[{"type":"command","command":"/opt/notify.sh"}]}],
  "Interrupt":[{"hooks":[{"type":"command","command":"/opt/notify.sh","timeout":3}]}]}}
EOF
chmod 600 "$H"
cp "$H" "$TMP/orig.json"
# keyed FILE: other tools' handlers with the key Codex trusts them by.
keyed(){ jq -c '[.hooks | to_entries[] | .key as $e | .value | to_entries[] | .key as $g | .value.hooks
  | to_entries[] | select(.value.command | test("hook-event\\.sh. codex") | not) | [$e, $g, .key, .value]]' "$1"; }
ours(){ jq -c --arg e "$2" '[.hooks[$e] // [] | to_entries[] | select(.value.hooks | any(.command | test("hook-event\\.sh. codex"))) | .key]' "$1"; }

out=$(bash "$ROOT/manage-provider.sh" install codex)
case "$out" in *"jq's layout"*) fail "install called a jq-formatted file reformatted: $out" ;; esac
[ "$(keyed "$H")" = "$(keyed "$TMP/orig.json")" ] || fail "install moved or changed another tool's hook"
[ "$(jq -c 'keys' "$H")" = '["description","hooks"]' ] || fail "install changed the top level"
for e in SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse SubagentStop Stop Interrupt SessionEnd; do
  n=$(jq --arg e "$e" '.hooks[$e] | length' "$H")
  [ "$(ours "$H" "$e")" = "[$((n - 1))]" ] || fail "$e: not one group of ours, last: $(ours "$H" "$e")"
done
[ "$(jq -c '.hooks.SubagentStart | length' "$H")" = 1 ] || fail "install hooked SubagentStart"
jq -e --arg c "'$HOOK' codex tool" '.hooks.PreToolUse[-1] == {hooks: [{type: "command", command: $c, timeout: 10}]}' "$H" >/dev/null || fail "PreToolUse group is not the tool action"
jq -e '[.hooks.Interrupt[-1], .hooks.SessionEnd[-1]] | all(.hooks[0].timeout == 3)' "$H" >/dev/null || fail "Interrupt/SessionEnd timeout is above Codex's 3s cap"
mode=$(stat -c %a "$H" 2>/dev/null || stat -f %Lp "$H")
[ "$mode" = 600 ] || fail "install changed hooks.json permissions"
[ "$(find "$CODEX_HOME" -name 'hooks.json.bak-*' | wc -l | tr -d ' ')" = 1 ] || fail "install made no backup"
cmp -s "$(find "$CODEX_HOME" -name 'hooks.json.bak-*')" "$TMP/orig.json" || fail "the backup is not the old file"

# An unchanged reinstall writes nothing: no new trust review, no backup.
cp -p "$H" "$TMP/once.json"
install
cmp -s "$H" "$TMP/once.json" || fail "a reinstall changed hooks.json"
[ "$(find "$CODEX_HOME" -name 'hooks.json.bak-*' | wc -l | tr -d ' ')" = 1 ] || fail "a no-op reinstall made a backup"

# Another tool appends after us; a checkout elsewhere (a changed command)
# replaces our groups where they are, so that tool's hooks keep their keys.
jq '.hooks.Stop += [{hooks: [{type: "command", command: "later-tool"}]}]' "$H" > "$TMP/x" && cat "$TMP/x" > "$H"
cp "$H" "$TMP/later.json"
ln -s "$ROOT" "$TMP/alias"
CODEX_HOME="$CODEX_HOME" bash "$TMP/alias/manage-provider.sh" install codex >/dev/null
[ "$(keyed "$H")" = "$(keyed "$TMP/later.json")" ] || fail "a reinstall from another path moved other tools' hooks"
jq -e --arg c "'$TMP/alias/scripts/agent/hook-event.sh' codex idle" '.hooks.Stop[1].hooks[0].command == $c' "$H" >/dev/null || fail "our Stop group was not replaced in place"
[ "$(jq '[.. | .command? // empty | select(test("hook-event\\.sh. codex"))] | length' "$H")" = 9 ] || fail "a reinstall duplicated our hooks"
# Uninstalling leaves an empty placeholder group where ours was, so that
# later hook keeps its key and Codex its trust.
out=$(bash "$ROOT/manage-provider.sh" uninstall codex)
case "$out" in *"other tools moved"*) fail "uninstall moved another tool's hook: $out" ;; esac
[ "$(keyed "$H")" = "$(keyed "$TMP/later.json")" ] || fail "uninstall moved other tools' hooks"
jq '.hooks.Stop[1] = {hooks: []} | .hooks |= (map_values(map(select(.hooks[0].command // "" | test("hook-event") | not))) | with_entries(select(.value != [])))' "$TMP/later.json" \
  | jq -e --slurpfile now "$H" '. == $now[0]' >/dev/null || fail "uninstall did not leave just a placeholder: $(jq -c .hooks "$H")"
# A reinstall takes the placeholder back.
install
jq -e --arg c "'$HOOK' codex idle" '.hooks.Stop[1].hooks[0].command == $c and (.hooks.Stop | length) == 3' "$H" >/dev/null || fail "a reinstall did not take the placeholder: $(jq -c .hooks.Stop "$H")"
[ "$(keyed "$H")" = "$(keyed "$TMP/later.json")" ] || fail "a reinstall into a placeholder moved other tools' hooks"
# With nothing after it, our group goes, and so do placeholders left before it.
jq '.hooks.Stop |= map(select(.hooks[0].command != "later-tool")) | .hooks.Stop |= .[:1] + [{hooks: []}] + .[1:]' "$H" > "$TMP/x" && cat "$TMP/x" > "$H"
install uninstall
cmp -s "$H" "$TMP/orig.json" || fail "uninstall did not restore the original bytes: $(jq -c .hooks.Stop "$H")"
out=$(bash "$ROOT/manage-provider.sh" uninstall codex)
case "$out" in *"has no agent-status hooks"*) ;; *) fail "a second uninstall changed something: $out" ;; esac
cmp -s "$H" "$TMP/orig.json" || fail "a second uninstall changed hooks.json"
# Backups: only our newest 3; look-alikes stay.
: > "$H.bak-keep"
for _ in 1 2 3; do install; install uninstall; done
[ "$(find "$CODEX_HOME" -name 'hooks.json.bak-[0-9]*.??????' | wc -l | tr -d ' ')" = 3 ] || fail "backups were not pruned to 3"
[ -e "$H.bak-keep" ] || fail "pruning removed a file that is not our backup"

# The Claude hooks Codex copies when it migrates Claude's settings report as
# Claude: install replaces them. A hook only mentioning our scripts stays.
jq --arg s "$ROOT/scripts/agent" --arg q "'" '.hooks.Stop += [{hooks: [{type: "command", command: "\($q)\($s)/set-state.sh\($q) finished"}]},
  {hooks: [{type: "command", command: "/x/claude-agent-status.tmux/scripts/agent/set-state.sh finished"},
           {type: "command", command: "grep agent-status.tmux/scripts/agent/set-state.sh.bak log"}]}]' "$TMP/orig.json" > "$H"
install
[ "$(jq -c '[.hooks.Stop[].hooks[].command | select(test("set-state"))]' "$H")" = '["grep agent-status.tmux/scripts/agent/set-state.sh.bak log"]' ] || fail "migrated Claude hooks not replaced: $(jq -c '.hooks.Stop' "$H")"
install uninstall

# No hooks.json yet: one is created, and uninstall leaves no hook in it.
rm -f "$H"; install
jq -e '.hooks | length == 9' "$H" >/dev/null || fail "install did not create hooks.json"
install uninstall
jq -e '.hooks == {}' "$H" >/dev/null || fail "uninstall left hooks in a created hooks.json"
# An empty file is {} to the installer (Codex can't read it): hooks are
# written, as one document, and an uninstall leaves it alone.
for empty in '' '  '; do
  printf '%s' "$empty" > "$H"; install uninstall
  [ "$(cat "$H")" = "$empty" ] || fail "uninstall changed an empty hooks.json ('$empty')"
  out=$(bash "$ROOT/manage-provider.sh" install codex)
  case "$out" in *"already has"*) fail "an empty hooks.json ('$empty') counted as installed: $out" ;; esac
  [ "$(jq -s 'length' "$H"):$(jq '.hooks | length' "$H")" = 1:9 ] || fail "install into an empty hooks.json ('$empty'): $(cat "$H")"
done
# A file in another layout is rewritten in jq's: install says so.
jq --indent 4 . "$TMP/orig.json" > "$H"
out=$(bash "$ROOT/manage-provider.sh" install codex)
case "$out" in *"jq's layout"*) ;; *) fail "install did not say it reformats hooks.json: $out" ;; esac
install uninstall
# Refusals change nothing: invalid JSON, a non-Codex shape, several
# documents (Codex reads none of them), a symlink.
for bad in '{"hooks": [] }' '[1]' '{"hooks": {"Stop": {}}}' '{ "hooks": ' '{"hooks":{}} {"hooks":{}}'; do
  printf '%s\n' "$bad" > "$H"
  if install 2>/dev/null; then fail "install accepted $bad"; fi
  [ "$(cat "$H")" = "$bad" ] || fail "a refused install changed $bad"
done
rm "$H"; printf '{"hooks":{}}\n' > "$TMP/victim.json"; ln -s "$TMP/victim.json" "$H"
if install 2>/dev/null; then fail "install followed a hooks.json symlink"; fi
[ "$(cat "$TMP/victim.json")" = '{"hooks":{}}' ] || fail "the symlink target changed"
rm "$H"
# Hooks turned off in config.toml: install says so.
printf 'model = "x"\n[features] # mine\nhooks = false\n' > "$CODEX_HOME/config.toml"
err=$(bash "$ROOT/manage-provider.sh" install codex 2>&1 >/dev/null)
case "$err" in *"turns Codex hooks off"*) ;; *) fail "hooks = false was not reported: $err" ;; esac
printf '[features]\nhooks = true\n[other]\nhooks = false\n' > "$CODEX_HOME/config.toml"
err=$(bash "$ROOT/manage-provider.sh" install codex 2>&1 >/dev/null)
[ -z "$err" ] || fail "hooks reported off: $err"
# Codex's home: CODEX_HOME, else ~/.codex; a missing one is skipped.
CODEX_HOME="$TMP/none" bash "$ROOT/manage-provider.sh" install codex >/dev/null 2>&1 || fail "a missing CODEX_HOME failed the install"
[ ! -e "$TMP/none" ] || fail "install created a missing CODEX_HOME"
CODEX_HOME="$TMP/none" bash "$ROOT/manage-provider.sh" found codex && fail "found codex without its home"
(unset CODEX_HOME; ! bash "$ROOT/manage-provider.sh" found codex) || fail "found codex without ~/.codex"
mkdir "$HOME/.codex"
(unset CODEX_HOME; bash "$ROOT/manage-provider.sh" install codex >/dev/null) || fail "install into ~/.codex failed"
jq -e '.hooks | length == 9' "$HOME/.codex/hooks.json" >/dev/null || fail "install ignored ~/.codex"
# Codex runs a hook with the user's shell -c: a path with a space still works.
mkdir "$TMP/sp ace"; cp -R "$ROOT" "$TMP/sp ace/agent-status.tmux"
rm -f "$H"; CODEX_HOME="$CODEX_HOME" bash "$TMP/sp ace/agent-status.tmux/manage-provider.sh" install codex >/dev/null
cmd=$(jq -r '.hooks.Stop[0].hooks[0].command' "$H")
rc=0; out=$(echo '{}' | TMUX_PANE="" sh -c "$cmd") || rc=$?
[ "$rc:$out" = 0: ] || fail "the hook command failed ($rc) or printed under a path with a space: $cmd"

# ----- hooks -----------------------------------------------------------------
command -v tmux >/dev/null 2>&1 || { echo "PASS: codex installer (SKIP hooks: tmux not installed)"; exit 0; }
ctl -f /dev/null new-session -d -s t -x 120 -y 40
p1="$(ctl display -pt t:0.0 '#{pane_id}')"
TMUX="$(ctl display -pt "$p1" '#{socket_path},#{pid},0')"
export TMUX
tmux set-option -g @agent-log "$TMP/agent.log"
get(){ tmux show-option -p -q -v -t "$p1" "$1" 2>/dev/null || true; }
# Asks without their call hash and opening time.
shown(){ printf '%s:%s:%s' "$(get @agent-state)" "$(get @agent-unseen)" "$(get @agent-asks | sed -E 's/[#@][0-9]+//g')"; }
# age: make every open ask older than a parallel batch's start.
age(){ tmux set-option -p -t "$p1" @agent-asks "$(get @agent-asks | sed -E 's/@[0-9]+/@1000/g')"; }
# ev ACTION EVENT [JSON fields]: a Codex hook for pane p1, as Codex runs it.
ev(){
  local out rc=0
  out=$(printf '{"session_id":"s1","turn_id":"t1","transcript_path":null,"cwd":"/w","hook_event_name":"%s","model":"m","permission_mode":"default"%s}' "$2" "${3:+,$3}" \
    | TMUX_PANE="$p1" "$HOOK" codex "$1") || rc=$?
  [ "$rc:$out" = 0: ] || fail "$2 hook exited $rc or printed: $out"
}
ev session SessionStart '"source":"startup"'
[ "$(get @agent-kind):$(get @agent-instance):$(shown)" = "codex:codex:s1:idle:0:" ] || fail "SessionStart did not register codex: $(get @agent-kind) $(get @agent-instance) $(shown)"
ev working UserPromptSubmit '"prompt":"fix the   flaky\ntest"'
[ "$(get @agent-auto-description)" = "fix the flaky test" ] || fail "first prompt not kept: $(get @agent-auto-description)"
ev tool PreToolUse '"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"c1"'
[ "$(shown)" = "working:0:" ] || fail "PreToolUse: $(shown)"
# A permission prompt holds through other agents' tools until its tool runs.
ev blocked PermissionRequest '"tool_name":"Bash","tool_input":{"command":"rm x"}'
[ "$(shown)" = "asking:0:/Bash" ] || fail "PermissionRequest: $(shown)"
ev tool PreToolUse '"agent_id":"a1","agent_type":"default","tool_name":"apply_patch","tool_input":{},"tool_use_id":"c2"'
ev working PostToolUse '"agent_id":"a1","agent_type":"default","tool_name":"apply_patch","tool_input":{},"tool_use_id":"c2","tool_response":"ok"'
[ "$(shown)" = "asking:0:/Bash" ] || fail "a subagent's tools ended the main thread's ask: $(shown)"
ev working PostToolUse '"tool_name":"Bash","tool_input":{"command":"rm x"},"tool_use_id":"c3","tool_response":"ok"'
[ "$(shown)" = "working:0:" ] || fail "the approved tool did not end its ask: $(shown)"
# Codex runs shell calls in parallel, all named Bash: a sibling of the asking
# call returning, or starting just after the ask, doesn't end it.
ev tool PreToolUse '"tool_name":"Bash","tool_input":{"command":"rm y"},"tool_use_id":"a"'
ev tool PreToolUse '"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"b"'
ev blocked PermissionRequest '"tool_name":"Bash","tool_input":{"command":"rm y","description":"why"}'
[ "$(shown)" = "asking:0:/Bash" ] || fail "parallel PermissionRequest: $(shown)"
ev working PostToolUse '"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"b","tool_response":"ok"'
[ "$(shown)" = "asking:0:/Bash" ] || fail "a sibling's return ended the ask: $(shown)"
ev tool PreToolUse '"tool_name":"Bash","tool_input":{"command":"pwd"},"tool_use_id":"c"'
[ "$(shown)" = "asking:0:/Bash" ] || fail "a sibling starting after the ask ended it: $(shown)"
ev working PostToolUse '"tool_name":"Bash","tool_input":{"command":"rm y"},"tool_use_id":"a","tool_response":"ok"'
[ "$(shown)" = "working:0:" ] || fail "the asking call's return did not end the ask: $(shown)"
# A denied call returns nothing: the model's next call, later, ends the ask.
ev blocked PermissionRequest '"tool_name":"Bash","tool_input":{"command":"rm z"}'
age
ev tool PreToolUse '"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"d"'
[ "$(shown)" = "working:0:" ] || fail "a call after a denied ask did not end it: $(shown)"
# Writing to a running command asks as write_stdin; the command's Bash
# return ends that ask.
ev blocked PermissionRequest '"tool_name":"write_stdin","tool_input":{"session_id":1,"chars":"y"}'
[ "$(shown)" = "asking:0:/write_stdin" ] || fail "write_stdin PermissionRequest: $(shown)"
ev working PostToolUse '"tool_name":"Bash","tool_input":{"command":"make"},"tool_use_id":"e","tool_response":"ok"'
[ "$(shown)" = "working:0:" ] || fail "the Bash return did not end the write_stdin ask: $(shown)"
# A subagent's ask ends when the subagent does (its tool may never return),
# and a prompt to it ends only its own asks.
ev blocked PermissionRequest '"agent_id":"a1","agent_type":"default","tool_name":"apply_patch","tool_input":{}'
ev blocked PermissionRequest '"agent_id":"a2","agent_type":"default","tool_name":"Bash","tool_input":{}'
ev working UserPromptSubmit '"agent_id":"a2","agent_type":"default","prompt":"go on"'
[ "$(shown)" = "asking:0:a1/apply_patch" ] || fail "a subagent's prompt: $(shown)"
ev working SubagentStop '"agent_id":"a1","agent_type":"default","agent_transcript_path":null,"stop_hook_active":false,"last_assistant_message":"done"'
[ "$(shown)" = "working:0:" ] || fail "SubagentStop did not end its ask: $(shown)"
[ "$(get @agent-auto-description)" = "fix the flaky test" ] || fail "a subagent's prompt changed the title"
# The model asking the user a question is an ask too.
ev tool PreToolUse '"tool_name":"request_user_input","tool_input":{"questions":[]},"tool_use_id":"c4"'
[ "$(shown)" = "asking:0:/request_user_input" ] || fail "request_user_input did not ask: $(shown)"
ev working PostToolUse '"tool_name":"request_user_input","tool_input":{},"tool_use_id":"c4","tool_response":"{}"'
[ "$(shown)" = "working:0:" ] || fail "the answered question did not end the ask: $(shown)"
# So is its asking for more permissions, which fires no PermissionRequest.
ev tool PreToolUse '"tool_name":"request_permissions","tool_input":{"reason":"write the cache","permissions":{}},"tool_use_id":"c6"'
[ "$(shown)" = "asking:0:/request_permissions" ] || fail "request_permissions did not ask: $(shown)"
ev working PostToolUse '"tool_name":"request_permissions","tool_input":{},"tool_use_id":"c6","tool_response":"{}"'
[ "$(shown)" = "working:0:" ] || fail "the granted permissions did not end the ask: $(shown)"
# A tool whose input only mentions it is not a question.
ev tool PreToolUse '"tool_name":"Bash","tool_input":{"command":"echo \"tool_name\":\"request_user_input\""},"tool_use_id":"c5"'
[ "$(shown)" = "working:0:" ] || fail "a mention of request_user_input asked: $(shown)"
# Parallel calls ask at once, and return at once: the pane lock records
# every ask, then ends every one.
batch(){
  local i pids=""
  for i in 1 2 3 4 5 6 7 8; do
    if [ "$1" = blocked ]; then
      ev blocked PermissionRequest "\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm p$i\"}" & pids="$pids $!"
    else
      ev working PostToolUse "\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm p$i\"},\"tool_use_id\":\"p$i\",\"tool_response\":\"ok\"" & pids="$pids $!"
    fi
  done
  for i in $pids; do wait "$i" || fail "a parallel $1 hook failed"; done
}
batch blocked
[ "$(shown)" = "asking:0:/Bash /Bash /Bash /Bash /Bash /Bash /Bash /Bash" ] || fail "parallel asks were lost: $(shown)"
[ "$(get @agent-asks | tr ' ' '\n' | sed 's/@.*//' | sort -u | wc -l | tr -d ' ')" = 8 ] || fail "parallel asks are not 8 distinct calls: $(get @agent-asks)"
batch working
[ "$(shown):$(get @agent-asks)" = "working:0::" ] || fail "parallel returns left asks: $(shown)"
ev idle Stop '"stop_hook_active":false,"last_assistant_message":"done"'
[ "$(shown)" = "idle:1:" ] || fail "Stop did not finish: $(shown)"
# A subagent asking as its parent's turn ends outlives it: the turn's end
# keeps that ask (not the main thread's own), and once it ends the pane
# shows the finished turn.
ev working UserPromptSubmit '"prompt":"next"'
ev blocked PermissionRequest '"agent_id":"a5","agent_type":"default","tool_name":"Bash","tool_input":{"command":"rm s"}'
ev blocked PermissionRequest '"agent_id":"a6","agent_type":"default","tool_name":"apply_patch","tool_input":{}'
ev blocked PermissionRequest '"tool_name":"Bash","tool_input":{"command":"rm m"}'
ev idle Stop '"stop_hook_active":false,"last_assistant_message":"done"'
[ "$(shown):$(get @agent-settled)" = "asking:0:a5/Bash a6/apply_patch:1" ] || fail "the turn's end dropped its subagents' asks: $(shown) $(get @agent-settled)"
ev working PostToolUse '"agent_id":"a5","agent_type":"default","tool_name":"Bash","tool_input":{"command":"rm s"},"tool_use_id":"s5","tool_response":"ok"'
[ "$(shown):$(get @agent-settled)" = "asking:0:a6/apply_patch:1" ] || fail "a subagent's answered ask after the turn's end: $(shown) $(get @agent-settled)"
ev working SubagentStop '"agent_id":"a6","agent_type":"default","agent_transcript_path":null,"stop_hook_active":false,"last_assistant_message":"late"'
[ "$(shown):$(get @agent-settled)" = "idle:1::" ] || fail "the last subagent ask's end did not show the finished turn: $(shown) $(get @agent-settled)"
# A subagent outliving its parent's turn doesn't wake the pane: neither its
# tools nor its end. Its ask shows, then the pane settles as it was.
ev tool PreToolUse '"agent_id":"a2","agent_type":"default","tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"s1"'
ev working PostToolUse '"agent_id":"a2","agent_type":"default","tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"s1","tool_response":"ok"'
ev working UserPromptSubmit '"agent_id":"a2","agent_type":"default","prompt":"go on"'
[ "$(shown)" = "idle:1:" ] || fail "a late subagent's tools woke the pane: $(shown)"
ev working SubagentStop '"agent_id":"a2","agent_type":"default","agent_transcript_path":null,"stop_hook_active":false,"last_assistant_message":"late"'
[ "$(shown)" = "idle:1:" ] || fail "a late SubagentStop woke the pane: $(shown)"
ev blocked PermissionRequest '"agent_id":"a3","agent_type":"default","tool_name":"Bash","tool_input":{"command":"rm w"}'
[ "$(shown):$(get @agent-settled)" = "asking:0:a3/Bash:1" ] || fail "a late subagent's ask: $(shown) $(get @agent-settled)"
ev working PostToolUse '"agent_id":"a3","agent_type":"default","tool_name":"Bash","tool_input":{"command":"rm w"},"tool_use_id":"s2","tool_response":"ok"'
[ "$(shown):$(get @agent-settled)" = "idle:1::" ] || fail "a late subagent's answered ask did not settle the pane: $(shown) $(get @agent-settled)"
# Focusing the pane to answer one sees the completion it holds.
ev blocked PermissionRequest '"agent_id":"a3","agent_type":"default","tool_name":"Bash","tool_input":{"command":"rm t"}'
"$ROOT/scripts/agent/clear-finished.sh" "$p1" </dev/null
[ "$(shown):$(get @agent-settled)" = "asking:0:a3/Bash:0" ] || fail "focus during a late subagent's ask: $(shown) $(get @agent-settled)"
ev working PostToolUse '"agent_id":"a3","agent_type":"default","tool_name":"Bash","tool_input":{"command":"rm t"},"tool_use_id":"s4","tool_response":"ok"'
[ "$(shown):$(get @agent-settled)" = "idle:0::" ] || fail "a completion seen during a late subagent's ask came back: $(shown) $(get @agent-settled)"
# A prompt meanwhile resumes the pane itself.
ev blocked PermissionRequest '"agent_id":"a3","agent_type":"default","tool_name":"Bash","tool_input":{"command":"rm v"}'
ev working UserPromptSubmit '"prompt":"next"'
[ "$(shown):$(get @agent-settled)" = "working:0::" ] || fail "a prompt during a late subagent's ask: $(shown) $(get @agent-settled)"
# After an Esc too: no unseen completion appears when its ask ends.
ev interrupt Interrupt
ev tool PreToolUse '"agent_id":"a4","agent_type":"default","tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"s3"'
[ "$(shown)" = "idle:0:" ] || fail "a subagent's tool after an Esc woke the pane: $(shown)"
ev blocked PermissionRequest '"agent_id":"a4","agent_type":"default","tool_name":"Bash","tool_input":{"command":"rm u"}'
[ "$(shown)" = "asking:0:a4/Bash" ] || fail "a subagent's ask after an Esc: $(shown)"
ev working SubagentStop '"agent_id":"a4","agent_type":"default","agent_transcript_path":null,"stop_hook_active":false,"last_assistant_message":"x"'
[ "$(shown):$(get @agent-settled)" = "idle:0::" ] || fail "a subagent's end after an Esc: $(shown) $(get @agent-settled)"
# Esc: idle, every ask gone, no unseen completion claimed.
ev working UserPromptSubmit '"prompt":"again"'
ev blocked PermissionRequest '"tool_name":"Bash","tool_input":{}'
ev interrupt Interrupt
[ "$(shown)" = "idle:0:" ] || fail "Interrupt: $(shown)"
# Compaction keeps the live turn; resume and clear start over.
ev working UserPromptSubmit '"prompt":"more"'
ev session SessionStart '"source":"compact"'
[ "$(shown)" = "working:0:" ] || fail "compaction reset the turn: $(shown)"
ev session SessionStart '"source":"clear"'
[ "$(shown):$(get @agent-auto-description)" = "idle:0::" ] || fail "a cleared session kept its state or title: $(shown)"
# Another session's end is not this one's; this one's clears the pane.
printf '{"session_id":"s9","hook_event_name":"SessionEnd","reason":"other"}' | TMUX_PANE="$p1" "$HOOK" codex end
[ "$(get @agent-instance)" = codex:s1 ] || fail "another session's end cleared the pane"
ev end SessionEnd '"reason":"other"'
[ -z "$(get @agent-state)$(get @agent-kind)$(get @agent-instance)" ] || fail "SessionEnd did not clear the pane"

# Headless runs report nothing: `codex exec` and the shared background server
# (app-server) can carry TMUX_PANE from some pane. A fake codex runs the hook
# as its child, as Codex does.
mkdir "$TMP/bin"
cat > "$TMP/bin/codex" <<'EOF'
#!/bin/bash
"$HOOK_PATH" codex "$HOOK_ACTION" < "$HOOK_INPUT"
EOF
chmod +x "$TMP/bin/codex"
printf '{"session_id":"h1","hook_event_name":"SessionStart","source":"startup"}' > "$TMP/start.json"
via(){ tmux set-option -p -u -t "$p1" @agent-state; HOOK_PATH="$HOOK" HOOK_ACTION=session HOOK_INPUT="$TMP/start.json" TMUX_PANE="$p1" "$TMP/bin/codex" "$@"; }
for args in "exec fix-it" "e x" "review" "app-server --listen unix://" "-c features.x=true app-server" "--profile work exec x" "-m o3 -c a=b exec" "exec-server" "cloud"; do
  # shellcheck disable=SC2086 # the words are the argv
  via $args
  [ -z "$(get @agent-state)" ] || fail "headless 'codex $args' reported"
done
for args in "" "--no-daemon" "--no-daemon resume abc" "fork --last" "-p work" "-m exec" "fix the exec bug" "-C /w --yolo"; do
  # shellcheck disable=SC2086
  via $args
  [ "$(get @agent-state)" = idle ] || fail "interactive 'codex $args' did not report"
done
# A quoted prompt starting with a subcommand's name: /proc keeps it one word;
# without /proc, ps can't tell it from the subcommand (a known limitation).
for prompt in "review my last change" "e x"; do
  via --no-daemon "$prompt"
  if [ -r "/proc/$$/cmdline" ]; then
    [ "$(get @agent-state)" = idle ] || fail "interactive 'codex \"$prompt\"' did not report"
  else
    [ -z "$(get @agent-state)" ] || fail "ps now keeps quoting? 'codex \"$prompt\"' reported: update the docs"
  fi
done
# A command line that only mentions codex is not Codex.
cat > "$TMP/bin/other" <<'EOF'
#!/bin/bash
"$HOOK_PATH" codex "$HOOK_ACTION" < "$HOOK_INPUT"
EOF
chmod +x "$TMP/bin/other"
tmux set-option -p -u -t "$p1" @agent-state
HOOK_PATH="$HOOK" HOOK_ACTION=session HOOK_INPUT="$TMP/start.json" TMUX_PANE="$p1" "$TMP/bin/other" codex exec
[ "$(get @agent-state)" = idle ] || fail "a command line mentioning 'codex exec' was taken for Codex"

echo "PASS: codex"
