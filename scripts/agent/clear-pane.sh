#!/usr/bin/env bash
# tmux pane-died hook: clear retained dead-pane options, log, and
# reaggregate. (Hooks set by an older plugin load also run it on pane-exited.)
# Usage: clear-pane.sh <pane_id> [window_id]
# By pane-exited the pane is already gone (hence #{hook_pane}/#{hook_window},
# not #{pane_id}); with remain-on-exit, pane-died fires and the pane remains.
set -eu

pane="${1:-}" window="${2:-}"
[[ "$pane" =~ ^%[0-9]+$ ]] || exit 0
[[ "$window" =~ ^@[0-9]+$ ]] || window=""
# shellcheck source=lib.sh
. "${BASH_SOURCE[0]%/*}/lib.sh"
sep=$'\037'
agent_lock "pane-${pane#%}"

IFS="$sep" read -r cur_pane state unseen log_file log_time <<< "$(tmux display -t "$pane" -p "#{pane_id}$sep#{@agent-state}$sep#{@agent-unseen}$sep$AGENT_LOG_FIELDS" 2>/dev/null || true)"
# By pane-exited the pane is gone and display describes some other pane.
if [ "$cur_pane" = "$pane" ]; then
  agent_clear_pane "$pane"
else
  state=""
  [ -z "$window" ] || agent_update_window "$window"
fi
agent_unlock

agent_shown "$state" "$unseen"
[ -z "$state" ] || agent_log "$log_file" "$log_time" "pane=$pane $SHOWN->cleared (exit)"
