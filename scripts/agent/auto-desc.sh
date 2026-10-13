#!/usr/bin/env bash
# Transient first-prompt description, stored with the pane.
#   auto-desc.sh set [text]   # text from arg; Claude form (no arg): stdin .prompt
#   auto-desc.sh clear [src]  # Claude form: stdin .source=="compact" -> keep
set -eu

[ -z "${TMUX_PANE:-}" ] && exit 0
[[ "$TMUX_PANE" =~ ^%[0-9]+$ ]] || exit 0
# A headless run (claude -p, the Agent SDK: entrypoint sdk-*) inherits the
# pane from whatever started it; the pane's own agent is someone else.
case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk-*) exit 0 ;; esac
cmd="${1:-}"
# shellcheck source=lib.sh
. "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/lib.sh"
agent_lock "pane-${TMUX_PANE#%}"

case "$cmd" in
  set)
    raw="${2:-}"
    if [ "$#" -eq 1 ] && [ ! -t 0 ]; then
      raw=$(jq -r '.prompt // ""' 2>/dev/null || true)
    fi
    current=$(tmux show-option -p -q -v -t "$TMUX_PANE" @agent-auto-description 2>/dev/null || true)
    [ -z "$current" ] || exit 0
    cleaned=$(printf '%s' "$raw" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
    [ -n "$cleaned" ] || exit 0
    if [ "${#cleaned}" -gt 50 ]; then
      cleaned="$(printf '%s' "$cleaned" | cut -c1-49)…"
    fi
    tmux set-option -p -t "$TMUX_PANE" @agent-auto-description "$cleaned"
    tmux set-option -g @agent-revision "$(date +%s).$$.$RANDOM" 2>/dev/null || true
    ;;
  clear)
    src="${2:-}"
    if [ "$#" -eq 1 ] && [ ! -t 0 ]; then
      src=$(jq -r '.source // ""' 2>/dev/null || true)
    fi
    [ "$src" = compact ] && exit 0
    tmux set-option -p -u -t "$TMUX_PANE" @agent-auto-description 2>/dev/null || true
    tmux set-option -g @agent-revision "$(date +%s).$$.$RANDOM" 2>/dev/null || true
    ;;
  *)
    echo "auto-desc: usage: auto-desc.sh set [text] | clear" >&2
    exit 2
    ;;
esac
