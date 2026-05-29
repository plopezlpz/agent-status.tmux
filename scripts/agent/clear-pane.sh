#!/usr/bin/env bash
# tmux pane-exited hook: drop the state file for the dead pane, then
# re-aggregate the window's worst-state icon. Kept as a script (vs.
# inlined in the hook string) so $state_dir is resolved dynamically and
# isn't fragile to spaces in the path.
# Usage: clear-pane.sh <pane_id> <window_id>
set -eu

pane="${1:-}"
window="${2:-}"
[ -n "$pane" ] || exit 0

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
state_dir=$(tmux show-option -gqv @agent-state-dir 2>/dev/null || true)
: "${state_dir:=${TMUX_TMPDIR:-/tmp}/agent-status-$(id -u)}"
log_file=$(tmux show-option -gqv @agent-log 2>/dev/null || true)
: "${log_file:=${XDG_DATA_HOME:-$HOME/.local/share}/tmux/agent-status/agent.log}"

file="$state_dir/$pane"
# Log + delete only when there was state -- the pane-exited hook fires
# server-wide on every pane death, most of which aren't ours.
if [ -f "$file" ]; then
  prev=""; read -r prev < "$file" || true
  rm -f -- "$file"
  mkdir -p "$(dirname "$log_file")"
  printf '%s pane=%s %s->cleared (exit)\n' "$(date -u +%FT%TZ)" "$pane" "${prev:-none}" >> "$log_file"
fi

[ -n "$window" ] && "$SCRIPT_DIR/update-window-icon.sh" "$window" || true
