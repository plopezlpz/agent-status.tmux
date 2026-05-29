#!/usr/bin/env bash
# Write the agent state for the current tmux pane and (optionally) notify.
# Usage: set-state.sh <state> [message]
#   <state> one of: working | asking | finished | idle
# Reads JSON on stdin (Claude hook payload) and pulls .message when present.
# No-op when not inside tmux.
set -eu

[ -z "${TMUX_PANE:-}" ] && exit 0

state="$1"
case "$state" in working|asking|finished|idle) ;;
  *) echo "set-state: invalid state '$state'" >&2; exit 2 ;;
esac

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

state_dir=$(tmux show-option -gqv @agent-state-dir 2>/dev/null || true)
: "${state_dir:=/tmp/agent-state}"
mkdir -p "$state_dir"

log_file=$(tmux show-option -gqv @agent-log 2>/dev/null || true)
: "${log_file:=$HOME/.cache/agent-status/agent.log}"

file="$state_dir/$TMUX_PANE"
prev=""; [ -f "$file" ] && read -r prev < "$file" || true

# Fast no-op: same state -> no write, no notify, no redraw.
[ "$state" = "$prev" ] && exit 0

# Atomic write so concurrent readers never see a half-written file.
tmp="$file.$$"
echo "$state" > "$tmp" && mv -f "$tmp" "$file"

mkdir -p "$(dirname "$log_file")"
printf '%s pane=%s %s->%s\n' "$(date -u +%FT%TZ)" "$TMUX_PANE" "${prev:-none}" "$state" >> "$log_file"

case "$state" in
  asking|finished)
    msg="${2:-}"
    [ -z "$msg" ] && [ ! -t 0 ] && msg=$(jq -r '.message // ""' 2>/dev/null || true)
    [ -z "$msg" ] && msg=$(tmux display -t "$TMUX_PANE" -p '#S / #W' 2>/dev/null || true)
    if command -v terminal-notifier >/dev/null 2>&1; then
      # Quote both -execute fields so spaces in $SCRIPT_DIR (e.g. plugin
      # under "~/Library/Application Support") survive Notification
      # Center's re-shell on click.
      terminal-notifier \
        -title "Agent • $state" \
        -message "$msg" \
        -execute "\"$SCRIPT_DIR/focus-pane.sh\" \"$TMUX_PANE\"" \
        -group "agent-$TMUX_PANE" \
        >/dev/null 2>&1 &
    elif command -v notify-send >/dev/null 2>&1; then
      # notify-send has no -execute equivalent without --action + a
      # listener; ship a plain notification and let the user switch
      # via `prefix A` (the navigator).
      notify-send "Agent • $state" "$msg" >/dev/null 2>&1 &
    fi
    ;;
esac

# Push-model: aggregator computes the worst-state icon for the window,
# stashes it in @agent-icon, and triggers the status redraw.
window_id=$(tmux display -t "$TMUX_PANE" -p '#{window_id}' 2>/dev/null || true)
[ -n "$window_id" ] && "$SCRIPT_DIR/update-window-icon.sh" "$window_id" || true
