#!/usr/bin/env bash
# Wire the plugin's per-state scripts into Claude Code's hooks config, or
# with `uninstall` remove them.
# Usage: install-claude-hooks.sh [install|uninstall]
#
# Idempotent: any prior hook entries pointing at this plugin's scripts/
# directory are stripped first, then (install) re-added. Safe to re-run after
# the plugin updates (e.g., after a TPM update pulls in new commits). Entries
# that belong to other tools are never touched.
#
# Backs up an existing settings file before writing.
set -eu

ACTION="${1:-install}"
case "$ACTION" in install|uninstall) ;; *) echo "usage: $0 [install|uninstall]" >&2; exit 2 ;; esac

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
  echo "agent-status: jq is required (brew install jq | apt install jq)" >&2
  exit 1
fi

[ ! -L "$SETTINGS" ] || { echo "agent-status: refusing to edit config symlink $SETTINGS" >&2; exit 1; }
[ ! -e "$SETTINGS" ] || [ -f "$SETTINGS" ] || { echo "agent-status: refusing non-file config $SETTINGS" >&2; exit 1; }
if [ "$ACTION" = uninstall ] && [ ! -f "$SETTINGS" ]; then
  echo "agent-status: $SETTINGS not found, nothing to do"; exit 0
fi
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

mkdir -p "$(dirname "$SETTINGS")"
input=/dev/null backup=""
if [ -f "$SETTINGS" ]; then
  input="$SETTINGS"
  backup=$(mktemp "$SETTINGS.bak-$(date +%s).XXXXXX")
  cp -p "$SETTINGS" "$backup"
fi

# shellcheck disable=SC2016 # jq program, not shell interpolation
strip='
  # strip: drop only the inner hooks pointing at this plugin (keep peers
  # from other tools), then drop entries left with no hooks. The (.hooks //
  # []) coerce handles a missing/null inner hooks field.
  def strip:
    map(.hooks = ((.hooks // []) | map(select((.command // "") | (contains($s + "/") or contains($r + "/") or test($ours)) | not))))
    | map(select((.hooks // []) | length > 0));
  # Ensure .hooks is an object even if the file has it as null/array/other.
  .hooks |= (if type == "object" then . else {} end) |
'
# shellcheck disable=SC2016
uninstall_filter="$strip"'
  .hooks |= with_entries(.value |= strip)
  | .hooks |= with_entries(select(.value | length > 0))
'
# Install strips each event's entries, then appends fresh ones.
# shellcheck disable=SC2016
install_filter="$strip"'
  def put($event; entry): .hooks[$event] = ((.hooks[$event] // []) | strip) + [entry];
  def run($cmd): {type:"command", command:"\($r)/\($cmd)"};
  def state($s): {type:"command", command:"\($r)/set-state.sh \($s)"};
  # Older plugin releases registered PermissionDenied, which fires on auto-mode
  # classifier denials mid-turn and is not a state change. Remove only our old
  # entry and preserve any unrelated user configuration.
  .hooks.PermissionDenied = ((.hooks.PermissionDenied // []) | strip) |
  if (.hooks.PermissionDenied | length) == 0 then del(.hooks.PermissionDenied) else . end |
  put("SessionStart"; {hooks:[state("idle"), run("auto-desc.sh clear")]}) |
  put("SessionEnd"; {hooks:[run("clear-state.sh")]}) |
  put("UserPromptSubmit"; {hooks:[state("working"), run("auto-desc.sh set")]}) |
  put("Stop"; {hooks:[state("finished")]}) |
  # A turn that ends in an API error (rate limit, overload, auth) fires
  # StopFailure instead of Stop.
  put("StopFailure"; {hooks:[state("finished")]}) |
  # An Esc interrupt fires neither. idle_prompt is sent once the prompt has sat
  # idle (default 60s) with no turn, dialog, or background agent running, so
  # it ends a working/asking state that no Stop will ever close.
  put("Notification"; {matcher:"idle_prompt", hooks:[state("idle")]}) |
  put("PermissionRequest"; {hooks:[state("asking")]}) |
  put("PreToolUse"; {hooks:[state("working")]}) |
  # Claude Code has no "permission answered" event. PostToolUse fires after an
  # approved tool runs; a denial ends the turn like an interrupt, so the
  # idle_prompt notification above closes it.
  put("PostToolUse"; {hooks:[state("working")]})
'
if [ "$ACTION" = install ]; then filter="$install_filter"; else filter="$uninstall_filter"; fi
new=$({ if [ "$input" = /dev/null ]; then printf '{}\n'; else cat "$input"; fi; } | jq --arg s "$SCRIPTS" --arg r "$SCRIPTS_REAL" --arg ours "$OURS" "$filter")
tmp=$(mktemp "$SETTINGS.agent-status.XXXXXX")
trap '[ -z "$tmp" ] || rm -f "$tmp"' EXIT
if [ -f "$SETTINGS" ]; then cp -p "$SETTINGS" "$tmp"; fi
printf '%s\n' "$new" > "$tmp"
mv "$tmp" "$SETTINGS"
tmp=""
prune_backups

if [ "$ACTION" = install ]; then
  echo "agent-status: hooks installed in $SETTINGS"
else
  echo "agent-status: hooks removed from $SETTINGS"
fi
[ -z "$backup" ] || echo "agent-status: backup saved to $backup"
