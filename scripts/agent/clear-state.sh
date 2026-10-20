#!/usr/bin/env bash
# Clear the current pane's registration on a real agent exit.
# Usage: clear-state.sh [reason] [instance] [kind]
# Claude SessionEnd reasons `clear` and `resume` keep the live pane registered.
set -eu

# shellcheck source=lib.sh
. "${BASH_SOURCE[0]%/*}/lib.sh"
agent_pane_guard

# shellcheck disable=SC2034 # kind: read by agent_identity
reason="${1:-}" instance="${2:-}" kind="${3:-${AGENT_STATUS_KIND:-}}" sep=$'\037'
# Only the Claude hook form (no arguments) carries a stdin payload; adapters
# pass arguments and may leave stdin open.
if [ "$#" -eq 0 ] && [ ! -t 0 ] && command -v jq >/dev/null 2>&1; then
  metadata=$(jq -r '[.reason // "", .session_id // ""] | join("\u001f")' 2>/dev/null || true)
  IFS="$sep" read -r reason instance <<< "$metadata"
  kind="${kind:-claude}"
fi
case "$reason" in clear|resume) exit 0 ;; esac
agent_identity

agent_lock "pane-${TMUX_PANE#%}"

IFS="$sep" read -r cur_pane state unseen current_instance log_file log_time <<< "$(tmux display -t "$TMUX_PANE" -p "#{pane_id}$sep#{@agent-state}$sep#{@agent-unseen}$sep#{@agent-instance}$sep$AGENT_LOG_FIELDS" 2>/dev/null || true)"
[ "$cur_pane" = "$TMUX_PANE" ] || exit 0
# Once a pane has an authoritative instance, identity-less or stale shutdowns
# fail closed. Pane-exited cleanup remains the fallback when payload parsing is unavailable.
if [ -n "$current_instance" ] && [ "$instance" != "$current_instance" ]; then
  exit 0
fi

agent_clear_pane "$TMUX_PANE"
agent_unlock

agent_shown "$state" "$unseen"
[ -z "$state" ] || agent_log "$log_file" "$log_time" "pane=$TMUX_PANE $SHOWN->cleared (reason=${reason:-none})"
