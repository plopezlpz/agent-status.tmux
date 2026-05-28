#!/usr/bin/env bash
# Remove this plugin's entries from Claude Code's hooks config.
# Does NOT touch entries that belong to other tools/scripts.
set -eu

PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRIPTS="$PLUGIN_DIR/scripts/agent"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

if ! command -v jq >/dev/null 2>&1; then
  echo "claude-agent-status: jq is required" >&2
  exit 1
fi

[ -f "$SETTINGS" ] || { echo "claude-agent-status: $SETTINGS not found, nothing to do"; exit 0; }
backup="$SETTINGS.bak-$(date +%s)"
cp "$SETTINGS" "$backup"

new=$(jq --arg s "$SCRIPTS" '
  def strip:
    map(select(
      ((.hooks // []) | map(.command // "") | join("|") | contains($s)) | not
    ));
  if .hooks then
    .hooks |= with_entries(.value |= strip)
    | .hooks |= with_entries(select(.value | length > 0))
  else . end
' "$SETTINGS")

printf '%s\n' "$new" > "$SETTINGS"

echo "claude-agent-status: hooks removed from $SETTINGS"
echo "claude-agent-status: backup saved to $backup"
