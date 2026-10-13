#!/usr/bin/env bash
# Cache the worst agent presentation state in window option @agent-icon.
# Usage: update-window-icon.sh <window_id> [layout]
# `layout` (window-layout-changed / pane-moved hooks) only reconciles: it
# exits after one tmux call unless the window's agent panes changed since the
# cached @agent-icon-key, and redraws the navigator only when the icon changes.
set -eu

window_id="${1:-}" mode="${2:-}"
[[ "$window_id" =~ ^@[0-9]+$ ]] || exit 0
# shellcheck source=lib.sh
. "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/lib.sh"

# Key: "state:unseen " for each agent pane, in pane order (as list-panes
# below builds it). Resizes, zooms and splits leave it unchanged.
key_format='#{P:#{?@agent-state,#{@agent-state}:#{@agent-unseen} ,}}'
if [ "$mode" = layout ]; then
  info=$(tmux display -t "$window_id" -p "#{window_id}"$'\037'"#{@agent-icon-key}"$'\037'"$key_format" 2>/dev/null || true)
  IFS=$'\037' read -r cur_window cached key <<< "$info"
  # A vanished window may describe another; reconciling it is harmless but
  # wasteful, and the real one needs nothing.
  [ "$cur_window" = "$window_id" ] || exit 0
  [ "$key" != "$cached" ] || exit 0
fi

agent_lock "window-${window_id#@}"

# Navigator reloads watch this cheap global token; update it even when the
# window's worst-state icon is unchanged (another card may have changed).
[ "$mode" = layout ] || tmux set-option -g @agent-revision "$(date +%s).$$.$RANDOM" 2>/dev/null || true

best="" top=0 key=""
while IFS=$'\t' read -r state unseen; do
  [ -n "$state" ] || continue
  key="$key$state:$unseen "
  case "$state:$unseen" in
    asking:*) r=4; shown=asking ;;
    working:*) r=3; shown=working ;;
    idle:1) r=2; shown=finished ;;
    idle:*) r=1; shown=idle ;;
    *) continue ;;
  esac
  if [ "$r" -gt "$top" ]; then top=$r; best=$shown; fi
done < <(tmux list-panes -t "$window_id" -F $'#{@agent-state}\t#{@agent-unseen}' 2>/dev/null)

new_icon=""
if [ -n "$best" ]; then
  glyph=$(tmux show-option -gqv "@agent-icon-$best" 2>/dev/null || true)
  color=$(tmux show-option -gqv "@agent-color-$best" 2>/dev/null || true)
  if [ -n "$glyph" ] && [ -n "$color" ]; then
    new_icon="#[push-default]#[fg=$color]$glyph#[fg=default]#[pop-default]"
  else
    new_icon="$glyph"
  fi
fi
info=$(tmux display -t "$window_id" -p "#{window_id}"$'\037'"#{@agent-icon-key}"$'\037'"#{@agent-icon}" 2>/dev/null || true)
IFS=$'\037' read -r cur_window cached prev_icon <<< "$info"
[ "$cur_window" = "$window_id" ] || exit 0
if [ "$key" != "$cached" ]; then
  if [ -n "$key" ]; then
    tmux set-option -w -t "$window_id" @agent-icon-key "$key" 2>/dev/null || true
  else
    tmux set-option -w -t "$window_id" -u @agent-icon-key 2>/dev/null || true
  fi
fi
if [ "$new_icon" = "$prev_icon" ]; then exit 0; fi

if [ -n "$new_icon" ]; then
  tmux set-option -w -t "$window_id" @agent-icon "$new_icon" 2>/dev/null || true
else
  tmux set-option -w -t "$window_id" -u @agent-icon 2>/dev/null || true
fi
[ "$mode" != layout ] || tmux set-option -g @agent-revision "$(date +%s).$$.$RANDOM" 2>/dev/null || true
agent_unlock

tmux refresh-client -S 2>/dev/null || true
