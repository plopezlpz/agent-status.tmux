#!/usr/bin/env bash
# Focus a notification's pane on the originating tmux server/client.
# Usage: focus-pane.sh <pane_id> [socket_path] [client_name]
set -eu

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
pane="${1:-}" socket="${2:-}" client="${3:-}"
[[ "$pane" =~ ^%[0-9]+$ ]] || exit 0
# -u: run without TMUX or a UTF-8 locale (terminal-notifier -execute), tmux
# would otherwise print control characters and non-ASCII as '_'.
case "$socket" in "") tmux_cmd=(tmux -u) ;; /*) tmux_cmd=(tmux -u -S "$socket") ;; *) exit 0 ;; esac
# Client names are tty paths (/dev/ttys055).
case "$client" in *[!A-Za-z0-9._:/-]*) client="" ;; esac

# No id can contain a space. display -t on a vanished pane silently describes
# another one, so the pane id must match.
metadata=$("${tmux_cmd[@]}" display -t "$pane" -p '#{pane_id} #{session_id} #{window_id}' 2>/dev/null) || exit 0
read -r found session window <<< "$metadata"
[ "$found" = "$pane" ] || exit 0
[[ "$session" =~ ^\$[0-9]+$ ]] || exit 0
[[ "$window" =~ ^@[0-9]+$ ]] || exit 0

app=$("${tmux_cmd[@]}" show-option -gqv @agent-terminal-app 2>/dev/null || true)
app=$(printf '%s' "$app" | LC_ALL=C tr -d '\000-\037\177' | cut -c1-100)
if [ -n "$app" ] && [ "$(uname -s)" = Darwin ]; then
  # Pass app as argv rather than interpolating it into AppleScript source.
  osascript - "$app" <<'APPLESCRIPT' 2>/dev/null || true
on run argv
  tell application (item 1 of argv) to activate
end run
APPLESCRIPT
fi

# The client captured at notify time may be gone (reattached on another tty):
# fall back to tmux's most recently active client rather than doing nothing.
if [ -z "$client" ] || ! "${tmux_cmd[@]}" switch-client -c "$client" -t "$session" 2>/dev/null; then
  "${tmux_cmd[@]}" switch-client -t "$session" 2>/dev/null || true
fi
"${tmux_cmd[@]}" select-window -t "$window" 2>/dev/null || exit 0
"${tmux_cmd[@]}" select-pane -t "$pane" 2>/dev/null || true
