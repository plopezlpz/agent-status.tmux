#!/usr/bin/env bash
# Remove this plugin's entries from Claude Code's hooks config.
# Does NOT touch entries that belong to other tools/scripts.
set -eu

PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRIPTS="$PLUGIN_DIR/scripts/agent"
# Resolved path: hooks are written with it, and stripped under both spellings
# so installs through a symlinked plugin dir (e.g. TPM) never duplicate.
SCRIPTS_REAL="$( cd "$SCRIPTS" && pwd -P )"
# Path-independent match for entries written under any other spelling
# (old installs through a symlink, a moved clone).
OURS='/agent-status\.tmux/scripts/agent/(set-state|clear-state|auto-desc)\.sh( |$)'
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

if ! command -v jq >/dev/null 2>&1; then
  echo "agent-status: jq is required" >&2
  exit 1
fi

[ ! -L "$SETTINGS" ] || { echo "agent-status: refusing to edit config symlink $SETTINGS" >&2; exit 1; }
[ ! -e "$SETTINGS" ] || [ -f "$SETTINGS" ] || { echo "agent-status: refusing non-file config $SETTINGS" >&2; exit 1; }
[ -f "$SETTINGS" ] || { echo "agent-status: $SETTINGS not found, nothing to do"; exit 0; }
# Keep only the newest 3 of our backups (exact mktemp name pattern below).
prune_backups() {
  local f stamp
  for f in "$SETTINGS".bak-*; do
    stamp="${f#"$SETTINGS".bak-}"
    [[ "$stamp" =~ ^[0-9]+\.[A-Za-z0-9]{6}$ ]] && [ -f "$f" ] && [ ! -L "$f" ] || continue
    printf '%s\t%s\n' "${stamp%%.*}" "$f"
  done | sort -t $'\t' -k1,1nr | tail -n +4 | cut -f2- | while IFS= read -r f; do
    rm -f -- "$f"
  done
}
backup=$(mktemp "$SETTINGS.bak-$(date +%s).XXXXXX")
cp -p "$SETTINGS" "$backup"

# shellcheck disable=SC2016 # jq program, not shell interpolation
filter='
  def strip:
    map(.hooks = ((.hooks // []) | map(select((.command // "") | (contains($s + "/") or contains($r + "/") or test($ours)) | not))))
    | map(select((.hooks // []) | length > 0));
  .hooks |= (if type == "object" then . else {} end)
  | .hooks |= with_entries(.value |= strip)
  | .hooks |= with_entries(select(.value | length > 0))
'
new=$(jq --arg s "$SCRIPTS" --arg r "$SCRIPTS_REAL" --arg ours "$OURS" "$filter" "$SETTINGS")
tmp=$(mktemp "$SETTINGS.agent-status.XXXXXX")
trap '[ -z "$tmp" ] || rm -f "$tmp"' EXIT
cp -p "$SETTINGS" "$tmp"
printf '%s\n' "$new" > "$tmp"
mv "$tmp" "$SETTINGS"
tmp=""
prune_backups

echo "agent-status: hooks removed from $SETTINGS"
echo "agent-status: backup saved to $backup"
