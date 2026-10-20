#!/usr/bin/env bash
# Recompute a window's @agent-icon. tmux hooks set by an older plugin load
# run this until the next reload; nothing else does.
# Usage: update-window-icon.sh <window_id> [layout]
set -eu

window_id="${1:-}"
[[ "$window_id" =~ ^@[0-9]+$ ]] || exit 0
# shellcheck source=lib.sh
. "${BASH_SOURCE[0]%/*}/lib.sh"
agent_update_window "$window_id"
