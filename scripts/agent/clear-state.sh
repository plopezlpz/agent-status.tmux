#!/usr/bin/env bash
# Drop the agent state for the current tmux pane.
# Used on Claude SessionEnd so the pane stops registering as an agent in
# the navigator and the window status icon clears.
set -eu

[ -z "${TMUX_PANE:-}" ] && exit 0

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

state_dir=$(tmux show-option -gqv @agent-state-dir 2>/dev/null || true)
: "${state_dir:=${TMUX_TMPDIR:-/tmp}/agent-status-$(id -u)}"
log_file=$(tmux show-option -gqv @agent-log 2>/dev/null || true)
: "${log_file:=${XDG_DATA_HOME:-$HOME/.local/share}/tmux/agent-status/agent.log}"

file="$state_dir/$TMUX_PANE"
prev=""; [ -f "$file" ] && read -r prev < "$file" || true
rm -f "$file"

mkdir -p "$(dirname "$log_file")"
printf '%s pane=%s %s->cleared\n' "$(date -u +%FT%TZ)" "$TMUX_PANE" "${prev:-none}" >> "$log_file"

window_id=$(tmux display -t "$TMUX_PANE" -p '#{window_id}' 2>/dev/null || true)
[ -n "$window_id" ] && "$SCRIPT_DIR/update-window-icon.sh" "$window_id" || true
