#!/usr/bin/env bash
# Clear the current pane's registration on a real agent exit.
# Usage: clear-state.sh [reason] [instance] [kind]
# Claude SessionEnd reasons `clear` and `resume` keep the live pane registered.
set -eu

[ -z "${TMUX_PANE:-}" ] && exit 0
[[ "$TMUX_PANE" =~ ^%[0-9]+$ ]] || exit 0
# A headless run (claude -p, the Agent SDK: entrypoint sdk-*) inherits the
# pane from whatever started it; the pane's own agent is someone else.
case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk-*) exit 0 ;; esac
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

reason="${1:-}" instance="${2:-}" kind="${3:-${AGENT_STATUS_KIND:-}}" sep=$'\037'
# Only the Claude hook form (no arguments) carries a stdin payload; adapters
# pass arguments and may leave stdin open.
if [ "$#" -eq 0 ] && [ ! -t 0 ] && command -v jq >/dev/null 2>&1; then
  metadata=$(jq -r '[.reason // "", .session_id // ""] | join("\u001f")' 2>/dev/null || true)
  IFS="$sep" read -r reason instance <<< "$metadata"
fi
case "$reason" in clear|resume) exit 0 ;; esac
instance="${instance:0:256}"
kind="${kind:0:64}"
case "$kind" in ""|*[!A-Za-z0-9._-]*) kind="" ;; esac
if [ -n "$instance" ] && [ -n "$kind" ]; then
  case "$instance" in "$kind:"*) ;; *) instance="$kind:$instance" ;; esac
fi

agent_lock "pane-${TMUX_PANE#%}"

metadata=$(tmux display -t "$TMUX_PANE" -p $'#{pane_id}\037#{@agent-state}\037#{@agent-unseen}\037#{@agent-instance}' 2>/dev/null || true)
IFS="$sep" read -r cur_pane state unseen current_instance <<< "$metadata"
[ "$cur_pane" = "$TMUX_PANE" ] || exit 0
# Once a pane has an authoritative instance, identity-less or stale shutdowns
# fail closed. Pane-exited cleanup remains the fallback when payload parsing is unavailable.
if [ -n "$current_instance" ] && [ "$instance" != "$current_instance" ]; then
  exit 0
fi
if [ "$state" = idle ] && [ "$unseen" = 1 ]; then state=finished; fi

for option in $AGENT_PANE_OPTIONS; do
  tmux set-option -p -u -t "$TMUX_PANE" "$option" 2>/dev/null || true
done
agent_unlock

[ -z "$state" ] || agent_log "pane=$TMUX_PANE $state->cleared (reason=${reason:-none})"

window_id=$(agent_window_of "$TMUX_PANE")
[ -n "$window_id" ] && "$SCRIPT_DIR/update-window-icon.sh" "$window_id" || true
