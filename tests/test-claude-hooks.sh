#!/usr/bin/env bash
# Verify install wires one quoted set-state hook per event, upgrades older
# entries, is idempotent, and uninstall removes all plugin hooks. Uses a temp
# settings file.
set -euo pipefail
PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unset CLAUDE_CONFIG_DIR
export CLAUDE_SETTINGS="$TMP/settings.json"
# Seeded with entries an older release wrote, which install must replace.
jq -n --arg s "$PLUGIN_DIR/scripts/agent" '{hooks:{PermissionDenied:[{hooks:[
  {type:"command",command:($s + "/set-state.sh working")},
  {type:"command",command:"keep-me"}
]}], UserPromptSubmit:[{hooks:[
  {type:"command",command:("env AGENT_STATUS_KIND=claude " + $s + "/set-state.sh working")},
  {type:"command",command:($s + "/auto-desc.sh set")}
]}], SessionStart:[{hooks:[
  {type:"command",command:($s + "/set-state.sh idle")},
  {type:"command",command:($s + "/auto-desc.sh clear")}
]}]}}' > "$CLAUDE_SETTINGS"
chmod 600 "$CLAUDE_SETTINGS"
fail(){ echo "FAIL: $1" >&2; exit 1; }

bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null
mode=$(stat -c %a "$CLAUDE_SETTINGS" 2>/dev/null || stat -f %Lp "$CLAUDE_SETTINGS")
[ "$mode" = 600 ] || fail "install changed settings permissions"
# One hook per event: set-state also keeps the first prompt, so the older
# auto-desc entries are gone.
! grep -qF auto-desc "$CLAUDE_SETTINGS" || fail "install kept the older auto-desc entries"
jq -e --arg c "'$PLUGIN_DIR/scripts/agent/set-state.sh' working" '[.hooks.UserPromptSubmit[].hooks[].command] == [$c]' "$CLAUDE_SETTINGS" >/dev/null || fail "UserPromptSubmit is not one quoted set-state working hook"
jq -e --arg c "'$PLUGIN_DIR/scripts/agent/set-state.sh' idle" '[.hooks.SessionStart[].hooks[].command] == [$c]' "$CLAUDE_SETTINGS" >/dev/null || fail "SessionStart is not one quoted set-state idle hook"
n=$(jq '[.. | .command? // empty | select(test("set-state.sh. working"))] | length' "$CLAUDE_SETTINGS")
[ "$n" -eq 4 ] || fail "install did not replace the older env-prefixed entry ($n working hooks, expected 4)"
jq -e '.hooks.PostToolUseFailure[].hooks[].command | select(test("set-state.sh. working$"))' "$CLAUDE_SETTINGS" >/dev/null || fail "a failed approved tool does not end the ask"
jq -e '.hooks.Stop[].hooks[].command | select(test("set-state.sh. finished"))' "$CLAUDE_SETTINGS" >/dev/null || fail "Stop lost completion event"
jq -e '.hooks.StopFailure[].hooks[].command | select(test("set-state.sh. finished"))' "$CLAUDE_SETTINGS" >/dev/null || fail "StopFailure does not end the turn"
jq -e '.hooks.Notification[] | select(.matcher == "idle_prompt") | .hooks[].command | select(test("set-state.sh. idle"))' "$CLAUDE_SETTINGS" >/dev/null || fail "idle_prompt does not close interrupted turns"
jq -e '.hooks.PermissionDenied[].hooks[].command | select(. == "keep-me")' "$CLAUDE_SETTINGS" >/dev/null || fail "unrelated PermissionDenied hook was removed"
jq -e '[.hooks.PermissionDenied[].hooks[].command | select(test("agent-status.tmux"))] | length == 0' "$CLAUDE_SETTINGS" >/dev/null || fail "legacy unsupported PermissionDenied hook remains"

cp "$CLAUDE_SETTINGS" "$TMP/once.json"
bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null
cmp -s "$CLAUDE_SETTINGS" "$TMP/once.json" || fail "a re-run changed the hooks"

# A bad action is refused before the settings are touched.
cp "$CLAUDE_SETTINGS" "$TMP/before.json"
rc=0; bash "$PLUGIN_DIR/install-claude-hooks.sh" bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "install-claude-hooks.sh bogus exited $rc, expected 2"
cmp -s "$CLAUDE_SETTINGS" "$TMP/before.json" || fail "a bad action changed settings"

bash "$PLUGIN_DIR/manage-provider.sh" uninstall claude >/dev/null
m=$(jq '[.. | .command? // empty | select(test("agent-status.tmux"))] | length' "$CLAUDE_SETTINGS")
[ "$m" -eq 0 ] || fail "uninstall left $m plugin hooks"
jq -e '[.hooks.PermissionDenied[].hooks[].command] == ["keep-me"]' "$CLAUDE_SETTINGS" >/dev/null || fail "uninstall removed an unrelated user hook"

# Installing through a symlinked plugin dir (TPM) must replace hooks written
# under the resolved path, and vice versa, never duplicating them.
mkdir -p "$TMP/tpm"; ln -s "$PLUGIN_DIR" "$TMP/tpm/agent-status.tmux"
bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null
bash "$TMP/tpm/agent-status.tmux/install-claude-hooks.sh" >/dev/null
n=$(jq '[.hooks.Stop[].hooks[].command | select(test("set-state.sh. finished"))] | length' "$CLAUDE_SETTINGS")
[ "$n" -eq 1 ] || fail "symlinked install duplicated Stop hook (n=$n)"
# Entries left under other spellings (old symlink installs, a moved clone) are
# replaced when installing from the real path; a sibling user hook is kept.
jq --arg l "$TMP/tpm/agent-status.tmux/scripts/agent" --arg sib "$PLUGIN_DIR/scripts/agent-sessions.sh" \
  '.hooks.Stop += [{hooks:[{type:"command",command:($l + "/set-state.sh finished")},
                          {type:"command",command:"/old/clone/agent-status.tmux/scripts/agent/set-state.sh finished"},
                          {type:"command",command:$sib}]}]' "$CLAUDE_SETTINGS" > "$TMP/seeded.json"
cat "$TMP/seeded.json" > "$CLAUDE_SETTINGS"
bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null
n=$(jq '[.hooks.Stop[].hooks[].command | select(test("set-state.sh.? finished"))] | length' "$CLAUDE_SETTINGS")
[ "$n" -eq 1 ] || fail "install from real path kept hooks under other spellings (n=$n)"
jq -e --arg sib "$PLUGIN_DIR/scripts/agent-sessions.sh" '[.. | .command? // empty | select(. == $sib)] | length == 1' "$CLAUDE_SETTINGS" >/dev/null || fail "install stripped a sibling user hook"
bash "$TMP/tpm/agent-status.tmux/uninstall-claude-hooks.sh" >/dev/null
m=$(jq '[.. | .command? // empty | select(test("scripts/agent/"))] | length' "$CLAUDE_SETTINGS")
[ "$m" -eq 0 ] || fail "symlinked uninstall left $m plugin hooks"

# Backups are pruned to our newest 3; files merely resembling them are kept.
: > "$CLAUDE_SETTINGS.bak-keep"
: > "$CLAUDE_SETTINGS.bak-1.notours"
for _ in 1 2 3 4 5; do bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null; done
bash "$PLUGIN_DIR/uninstall-claude-hooks.sh" >/dev/null
n=$(find "$TMP" -maxdepth 1 -name 'settings.json.bak-[0-9]*.??????' | wc -l | tr -d ' ')
[ "$n" -eq 3 ] || fail "installer kept $n backups, expected 3"
[ -e "$CLAUDE_SETTINGS.bak-keep" ] && [ -e "$CLAUDE_SETTINGS.bak-1.notours" ] || fail "backup pruning removed a foreign file"
# A failed write leaves no temp file behind and the settings untouched.
mkdir "$TMP/failbin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/failbin/mv"; chmod +x "$TMP/failbin/mv"
cp "$CLAUDE_SETTINGS" "$TMP/before.json"
if PATH="$TMP/failbin:$PATH" bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null 2>&1; then fail "install ignored a failed write"; fi
if PATH="$TMP/failbin:$PATH" bash "$PLUGIN_DIR/uninstall-claude-hooks.sh" >/dev/null 2>&1; then fail "uninstall ignored a failed write"; fi
[ -z "$(find "$TMP" -maxdepth 1 -name 'settings.json.agent-status.*')" ] || fail "failed write left a temp file"
cmp -s "$CLAUDE_SETTINGS" "$TMP/before.json" || fail "failed write changed settings"

# Claude runs hooks with sh -c: a plugin path with a space still works.
mkdir "$TMP/sp ace"; cp -R "$PLUGIN_DIR" "$TMP/sp ace/agent-status.tmux"
bash "$TMP/sp ace/agent-status.tmux/install-claude-hooks.sh" >/dev/null
for event in Stop SessionEnd; do
  cmd=$(jq -r --arg e "$event" '.hooks[$e][].hooks[].command | select(contains("sp ace"))' "$CLAUDE_SETTINGS")
  [ -n "$cmd" ] || fail "$event not installed from the spaced copy"
  rc=0; TMUX_PANE="" sh -c "$cmd" </dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "hook command failed ($rc) under a path with a space: $cmd"
done
# Moving the plugin and installing again replaces those entries.
bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null
! grep -qF "sp ace" "$CLAUDE_SETTINGS" || fail "a quoted entry from another checkout was kept"

# Without CLAUDE_SETTINGS, the hooks go where Claude reads them:
# $CLAUDE_CONFIG_DIR/settings.json, else ~/.claude/settings.json.
mkdir "$TMP/config"
CLAUDE_SETTINGS="" CLAUDE_CONFIG_DIR="$TMP/config" bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null
jq -e '.hooks.Stop' "$TMP/config/settings.json" >/dev/null || fail "install ignored CLAUDE_CONFIG_DIR"

victim="$TMP/victim.json"; printf '{"safe":true}\n' > "$victim"
export CLAUDE_SETTINGS="$TMP/settings-link.json"; ln -s "$victim" "$CLAUDE_SETTINGS"
if bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null 2>&1; then fail "install followed settings symlink"; fi
if bash "$PLUGIN_DIR/uninstall-claude-hooks.sh" >/dev/null 2>&1; then fail "uninstall followed settings symlink"; fi
jq -e '.safe == true' "$victim" >/dev/null || fail "settings symlink target changed"

echo "PASS: claude hooks"
