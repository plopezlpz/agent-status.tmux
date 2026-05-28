#!/usr/bin/env bash
# tmux pane-exited hook: drop the state file for the dead pane, then
# re-aggregate the window's worst-state icon. Kept as a script (vs.
# inlined in the hook string) so $state_dir is resolved dynamically and
# isn't fragile to spaces in the path.
# Usage: on-pane-exit.sh <pane_id> <window_id>
set -eu

pane="${1:-}"
window="${2:-}"
[ -n "$pane" ] || exit 0

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
state_dir=$(tmux show-option -gqv @claude-agent-state-dir 2>/dev/null || true)
: "${state_dir:=/tmp/claude-agent-state}"

rm -f -- "$state_dir/$pane"

[ -n "$window" ] && "$SCRIPT_DIR/update-window-icon.sh" "$window"
