#!/usr/bin/env bash
# agent-status.tmux -- TPM entrypoint.
#
# Live agent status for Claude Code panes in tmux:
#   - per-pane state (working / asking / finished / idle) driven by
#     Claude hooks (see ./install-claude-hooks.sh)
#   - aggregated worst-state icon set as the @agent-icon
#     window-scoped option (add `#{?@agent-icon,...}` to your
#     window-status-format)
#   - clickable notifications (terminal-notifier / notify-send)
#   - fzf-based navigator popup over all live agent panes

set -eu
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRIPTS="$CURRENT_DIR/scripts"

# ----- defaults (-gqo = set only if unset, so user overrides win) ------
tmux set-option -gqo @agent-icon-working  '󱐋'
tmux set-option -gqo @agent-icon-asking   '󰘥'
tmux set-option -gqo @agent-icon-finished '󰗠'
tmux set-option -gqo @agent-icon-idle     '󱚣'
tmux set-option -gqo @agent-navigator-key 'A'
tmux set-option -gqo @agent-popup-width   '70%'
tmux set-option -gqo @agent-popup-height  '70%'
# Transient state -> tmux's tmpdir (per-user, reboot-cleared). Persistent
# data (descriptions, log) -> XDG_DATA_HOME/tmux, like tmux-resurrect.
_agent_runtime="${TMUX_TMPDIR:-/tmp}/agent-status-$(id -u)"
_agent_data="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/agent-status"
tmux set-option -gqo @agent-state-dir         "$_agent_runtime"
tmux set-option -gqo @agent-descriptions-dir  "$_agent_data/descriptions"
tmux set-option -gqo @agent-log               "$_agent_data/agent.log"
# Optional: macOS terminal app to activate on notification click (e.g.
# "Ghostty", "iTerm", "Terminal"). Empty = don't activate any app.
tmux set-option -gqo @agent-terminal-app ''

# ----- runtime directories --------------------------------------------
state_dir=$(tmux show-option -gqv @agent-state-dir)
mkdir -p "$state_dir"

# ----- prerequisites ---------------------------------------------------
# pane-focus-in only fires when the server has focus-events on -- tmux's
# default is off, so users without it set would see icons stick on
# "finished" forever. Required, set unconditionally.
tmux set-option -g focus-events on

# ----- hooks -----------------------------------------------------------
# Hooks whose command contains this needle are "ours".
PLUGIN_NEEDLE='agent-status.tmux/scripts/agent'

# add_hook NAME CMD: append CMD as a global hook, idempotently. If a prior
# plugin entry exists, rebuild the list keeping non-plugin (user) hooks and
# re-add CMD -- so every reload converges to one plugin entry. Matches on
# PLUGIN_NEEDLE, not CMD, since tmux rewrites hook quoting when it stores it.
add_hook() {
  local name="$1" cmd="$2"
  local existing
  existing=$(tmux show-hooks -g "$name" 2>/dev/null || true)

  # Any prior plugin entry present? Rebuild keeping non-plugin entries.
  if [ -n "$existing" ] && printf '%s\n' "$existing" | grep -qF -- "$PLUGIN_NEEDLE"; then
    local survivors line
    survivors=""
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      case "$line" in *"$PLUGIN_NEEDLE"*) continue ;; esac
      # Strip the "<name>[<idx>] " prefix; the remainder is the hook's
      # original command, ready to feed back to set-hook.
      survivors="$survivors${line#"$name"\[*\] }
"
    done <<< "$existing"
    tmux set-hook -gu "$name"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      tmux set-hook -ga "$name" "$line"
    done <<< "$survivors"
  fi

  tmux set-hook -ga "$name" "$cmd"
}

# Demote `finished` -> `idle` when the pane gets focus.
add_hook pane-focus-in \
  "run-shell '$SCRIPTS/agent/clear-finished.sh \"#{pane_id}\"'"

# Pane death: drop its state file and re-aggregate the window icon.
# Wrapped in a helper script so the runtime path is resolved dynamically
# and any spaces in $state_dir don't break the hook command string.
add_hook pane-exited \
  "run-shell '$SCRIPTS/agent/clear-pane.sh \"#{pane_id}\" \"#{window_id}\"'"

# ----- binding ---------------------------------------------------------
nav_key=$(tmux show-option -gqv @agent-navigator-key)
popup_w=$(tmux show-option -gqv @agent-popup-width)
popup_h=$(tmux show-option -gqv @agent-popup-height)

tmux bind -N "Claude agent navigator" "$nav_key" \
  display-popup -E -w "$popup_w" -h "$popup_h" "$SCRIPTS/agent-sessions.sh"
