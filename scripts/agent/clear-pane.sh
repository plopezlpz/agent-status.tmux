#!/usr/bin/env bash
# tmux pane-exited / pane-died hook: clear retained dead-pane options, log,
# and reaggregate.
# Usage: clear-pane.sh <pane_id> [window_id]
# By pane-exited the pane is already gone (hence #{hook_pane}/#{hook_window},
# not #{pane_id}); with remain-on-exit, pane-died fires and the pane remains.
set -eu

pane="${1:-}" window="${2:-}"
[[ "$pane" =~ ^%[0-9]+$ ]] || exit 0
[[ "$window" =~ ^@[0-9]+$ ]] || window=""
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
sep=$'\037'
agent_lock "pane-${pane#%}"

metadata=$(tmux display -t "$pane" -p $'#{pane_id}\037#{@agent-state}\037#{@agent-unseen}\037#{window_id}' 2>/dev/null || true)
IFS="$sep" read -r cur_pane state unseen pane_window <<< "$metadata"
# By pane-exited the pane is gone and display describes some other pane.
if [ "$cur_pane" != "$pane" ]; then
  state="" unseen=""
else
  [ -n "$window" ] || window="$pane_window"
  agent_clear_pane "$pane"
fi
if [ "$state" = idle ] && [ "$unseen" = 1 ]; then state=finished; fi
agent_unlock

[ -z "$state" ] || agent_log "pane=$pane $state->cleared (exit)"

[ -z "$window" ] || "$SCRIPT_DIR/update-window-icon.sh" "$window" || true
