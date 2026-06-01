#!/usr/bin/env bash
# Transient, per-pane auto-default navigator description from the session's
# first prompt. Shown by the navigator only when there's no Ctrl-E override.
# Keyed by $TMUX_PANE (like the state file); no-op outside tmux.
#
#   auto-desc.sh set [text]   # text from arg, else stdin JSON .prompt
#   auto-desc.sh clear        # stdin .source=="compact" -> keep (Claude)
set -eu

[ -z "${TMUX_PANE:-}" ] && exit 0
cmd="${1:-}"

state_dir=$(tmux show-option -gqv @agent-state-dir 2>/dev/null || true)
: "${state_dir:=${TMUX_TMPDIR:-/tmp}/agent-status-$(id -u)}"
file="$state_dir/$TMUX_PANE.desc"

case "$cmd" in
  set)
    raw="${2:-}"
    if [ -z "$raw" ] && [ ! -t 0 ]; then
      raw=$(jq -r '.prompt // ""' 2>/dev/null || true)
    fi
    # First prompt only: never overwrite an existing auto-desc.
    [ -e "$file" ] && exit 0
    # Collapse the whole prompt (incl. newlines) to one trimmed line, then
    # truncate — captures content from any line and tolerates leading blanks.
    cleaned=$(printf '%s' "$raw" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
    [ -z "$cleaned" ] && exit 0
    if [ "${#cleaned}" -gt 50 ]; then
      cleaned="$(printf '%s' "$cleaned" | cut -c1-49)…"
    fi
    mkdir -p "$state_dir"
    tmp="$file.$$"
    printf '%s\n' "$cleaned" > "$tmp" && mv -f "$tmp" "$file"
    ;;
  clear)
    src=""
    [ ! -t 0 ] && src=$(jq -r '.source // ""' 2>/dev/null || true)
    [ "$src" = "compact" ] && exit 0
    rm -f "$file"
    ;;
  *)
    echo "auto-desc: usage: auto-desc.sh set [text] | clear" >&2
    exit 2
    ;;
esac
