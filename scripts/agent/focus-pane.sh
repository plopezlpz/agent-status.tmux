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
metadata=$("${tmux_cmd[@]}" display -t "$pane" -p '#{pane_id} #{session_id} #{window_id} #{pid} #{socket_path}' 2>/dev/null) || exit 0
read -r found session window server_pid server <<< "$metadata"
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

# remote PID: the client runs under sshd or mosh-server (a phone, another
# machine). The click happened at this machine's screen.
remote() {
  local pid="$1" depth=0 comm
  while [ "$depth" -lt 12 ] && [ "${pid:-0}" -gt 1 ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    case "${comm##*/}" in sshd*|mosh-server|etserver) return 0 ;; esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    depth=$((depth + 1))
  done
  return 1
}
# Focus a local client: the one captured at notify time while it is still
# attached, else the most recently active. With only remote clients attached,
# leave their views alone; with none, still select the pane for the next attach.
pick="" newest=-1 remotes=0
while read -r name pid activity; do
  if remote "$pid"; then remotes=$((remotes + 1)); continue; fi
  if [ "$name" = "$client" ]; then pick="$name"; break; fi
  case "$activity" in ''|*[!0-9]*) activity=0 ;; esac
  [ "$activity" -le "$newest" ] || { newest="$activity"; pick="$name"; }
done < <("${tmux_cmd[@]}" list-clients -F '#{client_name} #{client_pid} #{client_activity}' 2>/dev/null || true)
if [ -n "$pick" ]; then
  "${tmux_cmd[@]}" switch-client -c "$pick" -t "$session" 2>/dev/null || exit 0
elif [ "$remotes" -gt 0 ]; then
  exit 0
fi
"${tmux_cmd[@]}" select-window -t "$window" 2>/dev/null || exit 0
"${tmux_cmd[@]}" select-pane -t "$pane" 2>/dev/null || true
# Mark a completion seen. pane-focus-in usually does, but not while another
# client (a phone left attached) already shows the pane: tmux sees no focus
# change then.
TMUX="$server,$server_pid,0" "${BASH_SOURCE[0]%/*}/clear-finished.sh" "$pane" || true
