#!/usr/bin/env bash
# Mark a completed (idle + unseen) pane as seen when it gains focus.
# Usage: clear-finished.sh <pane_id>
set -eu

pane="${1:-}"
[[ "$pane" =~ ^%[0-9]+$ ]] || exit 0
# shellcheck source=lib.sh
. "${BASH_SOURCE[0]%/*}/lib.sh"
sep=$'\037'
# finished: the pane shows an unseen completion (reads the log fields too).
finished() {
  IFS="$sep" read -r cur shown log_file log_time <<< "$(tmux display -t "$pane" -p "#{pane_id}$sep#{@agent-state}#{@agent-unseen}$sep$AGENT_LOG_FIELDS" 2>/dev/null || true)"
  [ "$cur:$shown" = "$pane:idle1" ]
}
# Focus changes are frequent; skip the lock unless there is work to do.
finished || exit 0
agent_lock "pane-${pane#%}"
finished || exit 0

tmux set-option -p -t "$pane" @agent-unseen 0 \; set-option -wF -t "$pane" @agent-icon "$AGENT_ICON" 2>/dev/null || true
agent_unlock

agent_log "$log_file" "$log_time" "pane=$pane finished->idle (focus)"
