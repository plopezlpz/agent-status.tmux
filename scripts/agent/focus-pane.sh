#!/usr/bin/env bash
# Switch tmux to the given pane (and on macOS, bring the terminal app
# to the foreground). Invoked by terminal-notifier -execute. The
# Notification Center spawns this with a minimal PATH and no $TMUX, so
# we prepend the common Homebrew prefixes and rely on tmux's default
# socket.
# Usage: focus-pane.sh <pane_id>
set -eu

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

pane="$1"
# Use the server-unique IDs (#{session_id} like $0, #{window_id} like @5)
# instead of names -- names can contain spaces or any user-typed
# character, breaking the space-split read.
read -r session window < <(tmux display -t "$pane" -p '#{session_id} #{window_id}' 2>/dev/null) || exit 0
[ -n "$session" ] && [ -n "$window" ] || exit 0

# Optional: bring the terminal app forward. Override via tmux option.
app=$(tmux show-option -gqv @agent-terminal-app 2>/dev/null || true)
: "${app:=}"
if [ -n "$app" ] && [ "$(uname -s)" = "Darwin" ]; then
  osascript -e "tell application \"$app\" to activate" 2>/dev/null || true
fi

tmux switch-client -t "$session" 2>/dev/null || true
tmux select-window -t "$window"  2>/dev/null || true
tmux select-pane   -t "$pane"    2>/dev/null || true
