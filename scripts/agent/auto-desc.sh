#!/usr/bin/env bash
# Transient first-prompt description, stored with the pane.
#   auto-desc.sh set [text]   # text from arg; stdin form (no arg): .prompt
#   auto-desc.sh clear [src]  # stdin form: .source=="compact" -> keep
# Claude's hooks now leave this to set-state.sh; the stdin form serves the
# Kimi and MastraCode adapters and Claude hooks installed by older releases.
set -eu

# shellcheck source=lib.sh
. "${BASH_SOURCE[0]%/*}/lib.sh"
agent_pane_guard
cmd="${1:-}"
agent_lock "pane-${TMUX_PANE#%}"

case "$cmd" in
  set)
    raw="${2:-}"
    if [ "$#" -eq 1 ] && [ ! -t 0 ]; then
      raw=$(jq -r '.prompt // ""' 2>/dev/null || true)
    fi
    current=$(tmux show-option -p -q -v -t "$TMUX_PANE" @agent-auto-description 2>/dev/null || true)
    [ -z "$current" ] || exit 0
    agent_auto_text "$raw"
    [ -n "$AUTO" ] || exit 0
    tmux set-option -p -t "$TMUX_PANE" @agent-auto-description "$AUTO"
    ;;
  clear)
    src="${2:-}"
    if [ "$#" -eq 1 ] && [ ! -t 0 ]; then
      src=$(jq -r '.source // ""' 2>/dev/null || true)
    fi
    [ "$src" = compact ] && exit 0
    tmux set-option -p -u -t "$TMUX_PANE" @agent-auto-description 2>/dev/null || true
    ;;
  *)
    echo "auto-desc: usage: auto-desc.sh set [text] | clear" >&2
    exit 2
    ;;
esac
