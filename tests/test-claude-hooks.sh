#!/usr/bin/env bash
# Verify install wires auto-desc into SessionStart/UserPromptSubmit, is
# idempotent, and uninstall removes all plugin hooks. Uses a temp settings file.
set -euo pipefail
PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_SETTINGS="$TMP/settings.json"; echo '{}' > "$CLAUDE_SETTINGS"
fail(){ echo "FAIL: $1" >&2; exit 1; }

bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null
jq -e '.hooks.SessionStart[].hooks[].command | select(test("auto-desc.sh clear"))' "$CLAUDE_SETTINGS" >/dev/null || fail "SessionStart missing auto-desc clear"
jq -e '.hooks.UserPromptSubmit[].hooks[].command | select(test("auto-desc.sh set"))' "$CLAUDE_SETTINGS" >/dev/null || fail "UserPromptSubmit missing auto-desc set"
jq -e '.hooks.UserPromptSubmit[].hooks[].command | select(test("set-state.sh working"))' "$CLAUDE_SETTINGS" >/dev/null || fail "UserPromptSubmit lost set-state working"

bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null
n=$(jq '[.. | .command? // empty | select(test("auto-desc.sh set"))] | length' "$CLAUDE_SETTINGS")
[ "$n" -eq 1 ] || fail "auto-desc set duplicated on re-run (n=$n)"

bash "$PLUGIN_DIR/uninstall-claude-hooks.sh" >/dev/null
m=$(jq '[.. | .command? // empty | select(test("agent-status.tmux"))] | length' "$CLAUDE_SETTINGS")
[ "$m" -eq 0 ] || fail "uninstall left $m plugin hooks"

echo "PASS: claude hooks"
