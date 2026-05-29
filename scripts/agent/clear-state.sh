#!/usr/bin/env bash
# Claude SessionEnd handler. Drop the pane's agent state -- but ONLY when
# Claude is really exiting.
#
# SessionEnd fires for more than just quitting: `/clear` (reason "clear") and
# resuming another conversation (reason "resume") end the *session* while the
# Claude process and the tmux pane stay alive. Deleting the state then makes
# the pane vanish from the navigator and lose its window icon mid-work -- the
# bug this guard fixes. We branch on the SessionEnd `.reason` from stdin and
# keep the pane registered for those continuing cases (SessionStart resets it
# to idle right after). A real exit (reason "other"/"logout"/... ) clears it.
set -eu

[ -z "${TMUX_PANE:-}" ] && exit 0

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

state_dir=$(tmux show-option -gqv @agent-state-dir 2>/dev/null || true)
: "${state_dir:=${TMUX_TMPDIR:-/tmp}/agent-status-$(id -u)}"
log_file=$(tmux show-option -gqv @agent-log 2>/dev/null || true)
: "${log_file:=${XDG_DATA_HOME:-$HOME/.local/share}/tmux/agent-status/agent.log}"

# SessionEnd pipes JSON with a `.reason`. No stdin (manual run) -> treat as a
# real clear. jq missing -> reason stays empty -> falls through to delete.
reason=""
[ ! -t 0 ] && reason=$(jq -r '.reason // ""' 2>/dev/null || true)

file="$state_dir/$TMUX_PANE"
prev=""; [ -f "$file" ] && read -r prev < "$file" || true

mkdir -p "$(dirname "$log_file")"

case "$reason" in
  clear|resume)
    # Session is continuing in the same live process -- keep the pane visible.
    printf '%s pane=%s %s->kept (reason=%s)\n' \
      "$(date -u +%FT%TZ)" "$TMUX_PANE" "${prev:-none}" "$reason" >> "$log_file"
    exit 0
    ;;
esac

rm -f "$file"
printf '%s pane=%s %s->cleared (reason=%s)\n' \
  "$(date -u +%FT%TZ)" "$TMUX_PANE" "${prev:-none}" "${reason:-none}" >> "$log_file"

window_id=$(tmux display -t "$TMUX_PANE" -p '#{window_id}' 2>/dev/null || true)
[ -n "$window_id" ] && "$SCRIPT_DIR/update-window-icon.sh" "$window_id" || true
