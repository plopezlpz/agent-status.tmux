#!/usr/bin/env bash
# Mark a completed (idle + unseen) pane as seen when it gains focus; also a
# completion a late ask holds (@agent-settled 1), which shows once it ends.
# Usage: clear-finished.sh <pane_id>
set -eu

pane="${1:-}"
[[ "$pane" =~ ^%[0-9]+$ ]] || exit 0
# shellcheck source=lib.sh
. "${BASH_SOURCE[0]%/*}/lib.sh"
sep=$'\037'
# finished: the pane shows an unseen completion, or holds one behind an ask
# (reads the log fields too).
finished() {
  IFS="$sep" read -r cur shown settled log_file log_time <<< "$(tmux display -t "$pane" -p "#{pane_id}$sep#{@agent-state}#{@agent-unseen}$sep#{@agent-settled}$sep$AGENT_LOG_FIELDS" 2>/dev/null || true)"
  [ "$cur" = "$pane" ] && { [ "$shown" = idle1 ] || [ "$shown:$settled" = asking0:1 ]; }
}
# Focus changes are frequent; skip the lock unless there is work to do.
finished || exit 0
agent_lock "pane-${pane#%}"
finished || exit 0

if [ "$shown" = asking0 ]; then
  # The ask still shows: only what it ends in changes.
  tmux set-option -p -t "$pane" @agent-settled 0 2>/dev/null || true
  agent_unlock
  agent_log "$log_file" "$log_time" "pane=$pane settled->seen (focus)"
  exit 0
fi
tmux set-option -p -t "$pane" @agent-unseen 0 \; set-option -wF -t "$pane" @agent-icon "$AGENT_ICON" 2>/dev/null || true
agent_unlock

agent_log "$log_file" "$log_time" "pane=$pane finished->idle (focus)"
