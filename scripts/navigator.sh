#!/usr/bin/env bash
# Navigator popup: the agents tab (agent-sessions.sh) and the sessions tab
# (session-switcher.sh) in one frame. Tab / Shift-Tab switch tabs and keep
# the query. Usage: navigator.sh [agents|sessions]
set -eu

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/nav-lib.sh
. "$SCRIPT_DIR/nav-lib.sh"

tab="${1:-agents}" query=""
export AGENT_NAV_TABBED=1
while :; do
  case "$tab" in
    agents) script=agent-sessions.sh next=sessions ;;
    sessions) script=session-switcher.sh next=agents ;;
    *) echo "usage: navigator.sh [agents|sessions]" >&2; exit 2 ;;
  esac
  rc=0
  query=$(AGENT_NAV_QUERY="$query" "$SCRIPT_DIR/$script") || rc=$?
  [ "$rc" = "$NAV_SWITCH_RC" ] || exit "$rc"
  tab="$next"
done
