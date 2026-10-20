#!/usr/bin/env bash
# Transient first-prompt description, stored with the pane.
#   auto-desc.sh set [text]   # text from arg; stdin form (no arg): .prompt
#   auto-desc.sh clear [src]  # stdin form: .source=="compact" -> keep
# The stdin forms serve Claude hooks installed by older releases; current
# Claude hooks leave this to set-state.sh.
set -eu

# shellcheck source=lib.sh
. "${BASH_SOURCE[0]%/*}/lib.sh"
agent_pane_guard
cmd="${1:-}"

# undescribed: the pane has no description yet.
undescribed() {
  [ -z "$(tmux show-option -p -q -v -t "$TMUX_PANE" @agent-auto-description 2>/dev/null || true)" ]
}

case "$cmd" in
  set)
    raw="${2:-}"
    if [ "$#" -eq 1 ] && [ ! -t 0 ]; then
      raw=$(jq -r '.prompt // ""' 2>/dev/null || true)
    fi
    agent_auto_text "$raw"
    [ -n "$AUTO" ] || exit 0
    # Only the first prompt counts: a described pane needs no lock.
    undescribed || exit 0
    agent_lock "pane-${TMUX_PANE#%}"
    undescribed || exit 0
    tmux set-option -p -t "$TMUX_PANE" @agent-auto-description "$AUTO"
    ;;
  clear)
    src="${2:-}"
    if [ "$#" -eq 1 ] && [ ! -t 0 ]; then
      src=$(jq -r '.source // ""' 2>/dev/null || true)
    fi
    [ "$src" = compact ] && exit 0
    agent_lock "pane-${TMUX_PANE#%}"
    tmux set-option -p -u -t "$TMUX_PANE" @agent-auto-description 2>/dev/null || true
    ;;
  *)
    echo "auto-desc: usage: auto-desc.sh set [text] | clear" >&2
    exit 2
    ;;
esac
