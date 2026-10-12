#!/usr/bin/env bash
# Mark a completed (idle + unseen) pane as seen when it gains focus.
# Usage: clear-finished.sh <pane_id>
set -eu

pane="${1:-}"
[[ "$pane" =~ ^%[0-9]+$ ]] || exit 0
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
finished(){ [ "$(tmux display -t "$pane" -p '#{pane_id}:#{@agent-state}:#{@agent-unseen}' 2>/dev/null || true)" = "$pane:idle:1" ]; }
# Focus changes are frequent; skip the lock unless there is work to do.
finished || exit 0
agent_lock "pane-${pane#%}"
finished || exit 0

tmux set-option -p -t "$pane" @agent-unseen 0 2>/dev/null || true
agent_unlock

agent_log "pane=$pane finished->idle (focus)"

window_id=$(agent_window_of "$pane")
[ -n "$window_id" ] && "$SCRIPT_DIR/update-window-icon.sh" "$window_id" || true
