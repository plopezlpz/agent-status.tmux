#!/usr/bin/env bash
# Wire the plugin's per-state scripts into Claude Code's hooks config.
#
# Idempotent: any prior hook entries pointing at this plugin's scripts/
# directory are stripped first, then re-added. Safe to re-run after the
# plugin updates (e.g., after a TPM update pulls in new commits).
#
# Backs up ~/.claude/settings.json to .bak-<unix-ts> before writing.
set -eu

PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRIPTS="$PLUGIN_DIR/scripts/agent"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

if ! command -v jq >/dev/null 2>&1; then
  echo "claude-agent-status: jq is required (brew install jq | apt install jq)" >&2
  exit 1
fi

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
backup="$SETTINGS.bak-$(date +%s)"
cp "$SETTINGS" "$backup"

# jq filter:
#   - strip(): drop any hook entry whose command references our scripts dir
#   - then append fresh entries for each Claude event
new=$(jq --arg s "$SCRIPTS" '
  # Drop only the inner hooks that point at this plugin -- keep peers
  # belonging to other tools sharing the same entry. Then drop entries
  # whose hooks array was emptied as a result.
  def strip:
    map(.hooks |= map(select((.command // "") | contains($s) | not)))
    | map(select((.hooks // []) | length > 0));
  # Ensure .hooks is an object even if the file has it as null/array/other.
  .hooks |= (if type == "object" then . else {} end) |
  .hooks.SessionStart      = ((.hooks.SessionStart      // []) | strip) + [{hooks:[{type:"command", command:"\($s)/set-state.sh idle"}]}] |
  .hooks.SessionEnd        = ((.hooks.SessionEnd        // []) | strip) + [{hooks:[{type:"command", command:"\($s)/clear-state.sh"}]}] |
  .hooks.UserPromptSubmit  = ((.hooks.UserPromptSubmit  // []) | strip) + [{hooks:[{type:"command", command:"\($s)/set-state.sh working"}]}] |
  .hooks.Stop              = ((.hooks.Stop              // []) | strip) + [{hooks:[{type:"command", command:"\($s)/set-state.sh finished"}]}] |
  .hooks.PermissionRequest = ((.hooks.PermissionRequest // []) | strip) + [{hooks:[{type:"command", command:"\($s)/set-state.sh asking"}]}] |
  .hooks.PreToolUse        = ((.hooks.PreToolUse        // []) | strip) + [{hooks:[{type:"command", command:"\($s)/set-state.sh working"}]}]
' "$SETTINGS")

printf '%s\n' "$new" > "$SETTINGS"

echo "claude-agent-status: hooks installed in $SETTINGS"
echo "claude-agent-status: backup saved to $backup"
