#!/usr/bin/env bash
# Recompute the worst-state agent glyph for a window and stash it as a
# window-scoped tmux user option @agent-icon. The status format
# reads that option directly (no shell fork per render). Push-model:
# writers call this on every state change, readers stay cheap.
# Usage: update-window-icon.sh <window_id>
set -eu

window_id="${1:-}"
[ -n "$window_id" ] || exit 0

state_dir=$(tmux show-option -gqv @agent-state-dir 2>/dev/null || true)
: "${state_dir:=/tmp/agent-state}"

best="" top=0
while read -r pane; do
  state=""
  # `|| true` (not `|| continue`): a file without a trailing newline makes
  # read exit non-zero but still populates $state -- keep it. Only a
  # missing/empty file should skip the pane.
  { read -r state < "$state_dir/$pane"; } 2>/dev/null || true
  [ -z "$state" ] && continue
  case "$state" in
    asking)   r=4 ;;
    working)  r=3 ;;
    finished) r=2 ;;
    idle)     r=1 ;;
    *)        continue ;;
  esac
  if [ "$r" -gt "$top" ]; then top=$r; best=$state; fi
done < <(tmux list-panes -t "$window_id" -F '#{pane_id}' 2>/dev/null)

# Compare the new icon to what the window already shows; skip the
# set/unset and the refresh when nothing changed. Saves a server-wide
# redraw on every non-Claude pane death (pane-exited fires for ALL
# panes, the vast majority of which aren't ours).
new_icon=""
if [ -n "$best" ]; then
  new_icon=$(tmux show-option -gqv "@agent-icon-$best" 2>/dev/null || true)
fi
prev_icon=$(tmux show-option -wqv -t "$window_id" @agent-icon 2>/dev/null || true)

[ "$new_icon" = "$prev_icon" ] && exit 0

if [ -n "$new_icon" ]; then
  tmux set-option -w -t "$window_id" @agent-icon "$new_icon" 2>/dev/null || true
else
  tmux set-option -w -t "$window_id" -u @agent-icon 2>/dev/null || true
fi

# Centralized refresh: every code path that mutates state lands here.
tmux refresh-client -S 2>/dev/null || true
