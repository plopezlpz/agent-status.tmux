#!/usr/bin/env bash
# Recompute the worst-state agent glyph for a window and stash it as a
# window-scoped tmux user option @claude-agent-icon. The status format
# reads that option directly (no shell fork per render). Push-model:
# writers call this on every state change, readers stay cheap.
# Usage: update-window-icon.sh <window_id>
set -eu

window_id="${1:-}"
[ -n "$window_id" ] || exit 0

state_dir=$(tmux show-option -gqv @claude-agent-state-dir 2>/dev/null || true)
: "${state_dir:=/tmp/claude-agent-state}"

best="" top=0
while read -r pane; do
  state=""
  { read -r state < "$state_dir/$pane"; } 2>/dev/null || continue
  case "$state" in
    asking)   r=4 ;;
    working)  r=3 ;;
    finished) r=2 ;;
    idle)     r=1 ;;
    *)        continue ;;
  esac
  if [ "$r" -gt "$top" ]; then top=$r; best=$state; fi
done < <(tmux list-panes -t "$window_id" -F '#{pane_id}' 2>/dev/null)

if [ -n "$best" ]; then
  icon=$(tmux show-option -gqv "@claude-agent-icon-$best" 2>/dev/null || true)
  tmux set-option -w -t "$window_id" @claude-agent-icon "$icon" 2>/dev/null || true
else
  tmux set-option -w -t "$window_id" -u @claude-agent-icon 2>/dev/null || true
fi

# Centralized refresh: every code path that mutates state ends up here,
# so the status line repaints regardless of how we got called.
tmux refresh-client -S 2>/dev/null || true
