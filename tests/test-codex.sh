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

install
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
# Uninstalling moves that later hook up: say so, since Codex asks again.
out=$(bash "$ROOT/manage-provider.sh" uninstall codex)
case "$out" in *"1 hook(s) of other tools moved"*) ;; *) fail "uninstall did not warn about the moved hook: $out" ;; esac
jq 'del(.hooks.Stop[1])' "$TMP/later.json" | jq -e --slurpfile now "$H" '.hooks.Stop | map(select(.hooks[0].command | test("hook-event") | not)) == $now[0].hooks.Stop' >/dev/null || fail "uninstall changed other Stop hooks"
jq '.hooks.Stop |= map(select(.hooks[0].command != "later-tool"))' "$H" > "$TMP/x" && cat "$TMP/x" > "$H"
cmp -s "$H" "$TMP/orig.json" || fail "uninstall did not restore the original bytes"
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
# Refusals change nothing: invalid JSON, a non-Codex shape, a symlink.
for bad in '{"hooks": [] }' '[1]' '{"hooks": {"Stop": {}}}' '{ "hooks": '; do
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
shown(){ printf '%s:%s:%s' "$(get @agent-state)" "$(get @agent-unseen)" "$(get @agent-asks)"; }
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
ev working PostToolUse '"tool_name":"Bash","tool_input":{},"tool_use_id":"c3","tool_response":"ok"'
[ "$(shown)" = "working:0:" ] || fail "the approved tool did not end its ask: $(shown)"
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
# A tool whose input only mentions it is not a question.
ev tool PreToolUse '"tool_name":"Bash","tool_input":{"command":"echo \"tool_name\":\"request_user_input\""},"tool_use_id":"c5"'
[ "$(shown)" = "working:0:" ] || fail "a mention of request_user_input asked: $(shown)"
ev idle Stop '"stop_hook_active":false,"last_assistant_message":"done"'
[ "$(shown)" = "idle:1:" ] || fail "Stop did not finish: $(shown)"
# A subagent ending after its parent stopped doesn't wake the pane.
ev working SubagentStop '"agent_id":"a2","agent_type":"default","agent_transcript_path":null,"stop_hook_active":false,"last_assistant_message":"late"'
[ "$(shown)" = "idle:1:" ] || fail "a late SubagentStop woke the pane: $(shown)"
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
