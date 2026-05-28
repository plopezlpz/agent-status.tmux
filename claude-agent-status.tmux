#!/usr/bin/env bash
# claude-agent-status.tmux -- TPM entrypoint.
#
# Live agent status for Claude Code panes in tmux:
#   - per-pane state (working / asking / finished / idle) driven by
#     Claude hooks (see ./install-claude-hooks.sh)
#   - aggregated worst-state icon set as the @claude-agent-icon
#     window-scoped option (add `#{?@claude-agent-icon,...}` to your
#     window-status-format)
#   - clickable notifications (terminal-notifier / notify-send)
#   - fzf-based navigator popup over all live agent panes

set -eu
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRIPTS="$CURRENT_DIR/scripts"

# ----- defaults (only set if user hasn't already overridden) -----------
# -o means "set only if not already set", so users can configure these
# anywhere in their config before the `run` line that loads tpm.
tmux set-option -gqo @claude-agent-icon-working  '󱐋'
tmux set-option -gqo @claude-agent-icon-asking   '󰘥'
tmux set-option -gqo @claude-agent-icon-finished '󰗠'
tmux set-option -gqo @claude-agent-icon-idle     '󱚣'
tmux set-option -gqo @claude-agent-navigator-key 'A'
tmux set-option -gqo @claude-agent-popup-width   '70%'
tmux set-option -gqo @claude-agent-popup-height  '70%'
tmux set-option -gqo @claude-agent-state-dir         '/tmp/claude-agent-state'
tmux set-option -gqo @claude-agent-descriptions-dir  "$HOME/.cache/claude-agent-status/descriptions"
tmux set-option -gqo @claude-agent-log               "$HOME/.cache/claude-agent-status/agent.log"
# Optional: macOS terminal app to activate on notification click (e.g.
# "Ghostty", "iTerm", "Terminal"). Empty = don't activate any app.
tmux set-option -gqo @claude-agent-terminal-app ''

# ----- runtime directories --------------------------------------------
state_dir=$(tmux show-option -gqv @claude-agent-state-dir)
mkdir -p "$state_dir"

# ----- hooks -----------------------------------------------------------
# Demote `finished` -> `idle` when the pane gets focus.
tmux set-hook -g pane-focus-in "run-shell '$SCRIPTS/agent/clear-finished.sh \"#{pane_id}\"'"

# Pane death: drop its state file and re-aggregate the window icon.
tmux set-hook -g pane-exited "run-shell 'rm -f \"$state_dir/#{pane_id}\"; $SCRIPTS/agent/update-window-icon.sh \"#{window_id}\"'"

# ----- binding ---------------------------------------------------------
nav_key=$(tmux show-option -gqv @claude-agent-navigator-key)
popup_w=$(tmux show-option -gqv @claude-agent-popup-width)
popup_h=$(tmux show-option -gqv @claude-agent-popup-height)

tmux bind -N "Claude agent navigator" "$nav_key" \
  display-popup -E -w "$popup_w" -h "$popup_h" "$SCRIPTS/agent-sessions.sh"

# Stash plugin path so the Claude-hooks installer can be invoked from
# anywhere and still find the right scripts.
tmux setenv -g CLAUDE_AGENT_STATUS_DIR "$CURRENT_DIR"
