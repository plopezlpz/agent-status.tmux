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
  echo "agent-status: jq is required (brew install jq | apt install jq)" >&2
  exit 1
fi

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
backup="$SETTINGS.bak-$(date +%s)"
cp "$SETTINGS" "$backup"

new=$(jq --arg s "$SCRIPTS" '
  # strip: drop only the inner hooks pointing at this plugin (keep peers
  # from other tools), then drop entries left with no hooks. The (.hooks //
  # []) coerce handles a missing/null inner hooks field. Then append fresh.
  def strip:
    map(.hooks = ((.hooks // []) | map(select((.command // "") | contains($s) | not))))
    | map(select((.hooks // []) | length > 0));
  # Ensure .hooks is an object even if the file has it as null/array/other.
  .hooks |= (if type == "object" then . else {} end) |
  .hooks.SessionStart      = ((.hooks.SessionStart      // []) | strip) + [{hooks:[{type:"command", command:"\($s)/set-state.sh idle"}, {type:"command", command:"\($s)/auto-desc.sh clear"}]}] |
  .hooks.SessionEnd        = ((.hooks.SessionEnd        // []) | strip) + [{hooks:[{type:"command", command:"\($s)/clear-state.sh"}]}] |
  .hooks.UserPromptSubmit  = ((.hooks.UserPromptSubmit  // []) | strip) + [{hooks:[{type:"command", command:"\($s)/set-state.sh working"}, {type:"command", command:"\($s)/auto-desc.sh set"}]}] |
  .hooks.Stop              = ((.hooks.Stop              // []) | strip) + [{hooks:[{type:"command", command:"\($s)/set-state.sh finished"}]}] |
  .hooks.PermissionRequest = ((.hooks.PermissionRequest // []) | strip) + [{hooks:[{type:"command", command:"\($s)/set-state.sh asking"}]}] |
  .hooks.PreToolUse        = ((.hooks.PreToolUse        // []) | strip) + [{hooks:[{type:"command", command:"\($s)/set-state.sh working"}]}] |
  # Claude Code has no "permission answered" event, so `asking` only returns
  # to `working` via the next tool. PostToolUse fires right after an approved
  # tool runs; PermissionDenied fires when a prompt is rejected (the turn then
  # continues). Wire both so the pane leaves `asking` the moment work resumes,
  # whether the prompt was approved or denied.
  .hooks.PostToolUse       = ((.hooks.PostToolUse       // []) | strip) + [{hooks:[{type:"command", command:"\($s)/set-state.sh working"}]}] |
  .hooks.PermissionDenied  = ((.hooks.PermissionDenied  // []) | strip) + [{hooks:[{type:"command", command:"\($s)/set-state.sh working"}]}]
' "$SETTINGS")

printf '%s\n' "$new" > "$SETTINGS"

echo "agent-status: hooks installed in $SETTINGS"
echo "agent-status: backup saved to $backup"
