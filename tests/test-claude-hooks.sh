#!/usr/bin/env bash
# Verify install wires auto-desc into SessionStart/UserPromptSubmit, is
# idempotent, and uninstall removes all plugin hooks. Uses a temp settings file.
set -euo pipefail
PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_SETTINGS="$TMP/settings.json"
jq -n --arg s "$PLUGIN_DIR/scripts/agent" '{hooks:{PermissionDenied:[{hooks:[
  {type:"command",command:($s + "/set-state.sh working")},
  {type:"command",command:"keep-me"}
]}]}}' > "$CLAUDE_SETTINGS"
chmod 600 "$CLAUDE_SETTINGS"
fail(){ echo "FAIL: $1" >&2; exit 1; }

bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null
mode=$(stat -f %Lp "$CLAUDE_SETTINGS" 2>/dev/null || stat -c %a "$CLAUDE_SETTINGS")
[ "$mode" = 600 ] || fail "install changed settings permissions"
jq -e '.hooks.SessionStart[].hooks[].command | select(test("auto-desc.sh clear"))' "$CLAUDE_SETTINGS" >/dev/null || fail "SessionStart missing auto-desc clear"
jq -e '.hooks.UserPromptSubmit[].hooks[].command | select(test("auto-desc.sh set"))' "$CLAUDE_SETTINGS" >/dev/null || fail "UserPromptSubmit missing auto-desc set"
jq -e '.hooks.UserPromptSubmit[].hooks[].command | select(test("AGENT_STATUS_KIND=claude .*set-state.sh working"))' "$CLAUDE_SETTINGS" >/dev/null || fail "UserPromptSubmit lost typed working state"
jq -e '.hooks.Stop[].hooks[].command | select(test("set-state.sh finished"))' "$CLAUDE_SETTINGS" >/dev/null || fail "Stop lost completion event"
jq -e '.hooks.PermissionDenied[].hooks[].command | select(. == "keep-me")' "$CLAUDE_SETTINGS" >/dev/null || fail "unrelated PermissionDenied hook was removed"
jq -e '[.hooks.PermissionDenied[].hooks[].command | select(test("agent-status.tmux"))] | length == 0' "$CLAUDE_SETTINGS" >/dev/null || fail "legacy unsupported PermissionDenied hook remains"

bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null
n=$(jq '[.. | .command? // empty | select(test("auto-desc.sh set"))] | length' "$CLAUDE_SETTINGS")
[ "$n" -eq 1 ] || fail "auto-desc set duplicated on re-run (n=$n)"

bash "$PLUGIN_DIR/uninstall-claude-hooks.sh" >/dev/null
m=$(jq '[.. | .command? // empty | select(test("agent-status.tmux"))] | length' "$CLAUDE_SETTINGS")
[ "$m" -eq 0 ] || fail "uninstall left $m plugin hooks"

# Installing through a symlinked plugin dir (TPM) must replace hooks written
# under the resolved path, and vice versa, never duplicating them.
mkdir -p "$TMP/tpm"; ln -s "$PLUGIN_DIR" "$TMP/tpm/agent-status.tmux"
bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null
bash "$TMP/tpm/agent-status.tmux/install-claude-hooks.sh" >/dev/null
n=$(jq '[.hooks.Stop[].hooks[].command | select(test("set-state.sh finished"))] | length' "$CLAUDE_SETTINGS")
[ "$n" -eq 1 ] || fail "symlinked install duplicated Stop hook (n=$n)"
# Entries left under other spellings (old symlink installs, a moved clone) are
# replaced when installing from the real path; a sibling user hook is kept.
jq --arg l "$TMP/tpm/agent-status.tmux/scripts/agent" --arg sib "$PLUGIN_DIR/scripts/agent-sessions.sh" \
  '.hooks.Stop += [{hooks:[{type:"command",command:($l + "/set-state.sh finished")},
                          {type:"command",command:"/old/clone/agent-status.tmux/scripts/agent/set-state.sh finished"},
                          {type:"command",command:$sib}]}]' "$CLAUDE_SETTINGS" > "$TMP/seeded.json"
cat "$TMP/seeded.json" > "$CLAUDE_SETTINGS"
bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null
n=$(jq '[.hooks.Stop[].hooks[].command | select(test("set-state.sh finished"))] | length' "$CLAUDE_SETTINGS")
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

victim="$TMP/victim.json"; printf '{"safe":true}\n' > "$victim"
export CLAUDE_SETTINGS="$TMP/settings-link.json"; ln -s "$victim" "$CLAUDE_SETTINGS"
if bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null 2>&1; then fail "install followed settings symlink"; fi
if bash "$PLUGIN_DIR/uninstall-claude-hooks.sh" >/dev/null 2>&1; then fail "uninstall followed settings symlink"; fi
jq -e '.safe == true' "$victim" >/dev/null || fail "settings symlink target changed"

echo "PASS: claude hooks"
