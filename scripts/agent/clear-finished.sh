#!/usr/bin/env bash
# Demote `finished` -> `idle` for a pane when it gains focus.
# Usage: clear-finished.sh <pane_id>
# No-op for any other state -- asking should persist through focus.
set -eu

pane="$1"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

state_dir=$(tmux show-option -gqv @claude-agent-state-dir 2>/dev/null || true)
: "${state_dir:=/tmp/claude-agent-state}"
log_file=$(tmux show-option -gqv @claude-agent-log 2>/dev/null || true)
: "${log_file:=$HOME/.cache/claude-agent-status/agent.log}"

file="$state_dir/$pane"
state=""
[ -f "$file" ] && read -r state < "$file" || true
[ "$state" = "finished" ] || exit 0

# Atomic write -- prevents readers from seeing a half-written file.
tmp="$file.$$"
echo "idle" > "$tmp" && mv -f "$tmp" "$file"

mkdir -p "$(dirname "$log_file")"
printf '%s pane=%s finished->idle (focus)\n' "$(date -u +%FT%TZ)" "$pane" >> "$log_file"

window_id=$(tmux display -t "$pane" -p '#{window_id}' 2>/dev/null || true)
[ -n "$window_id" ] && "$SCRIPT_DIR/update-window-icon.sh" "$window_id" || true
