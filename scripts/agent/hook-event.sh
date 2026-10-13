#!/usr/bin/env bash
# Shared body of the Kimi and MastraCode hook adapters: map one hook ACTION,
# with the provider's JSON payload on stdin, to the state scripts.
# Usage: hook-event.sh <kind> <session|working|blocked|idle|interrupt|end>
set -eu
kind="${1:-}" action="${2:-}"
case "$kind" in kimi|mastracode) ;; *) exit 0 ;; esac

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
payload=$(cat 2>/dev/null || true)
instance="" message="" source="" reason=""
if command -v jq >/dev/null 2>&1; then
  instance=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null || true)
  message=$(printf '%s' "$payload" | jq -r '.message // .tool_name // ""' 2>/dev/null || true)
  source=$(printf '%s' "$payload" | jq -r '.source // ""' 2>/dev/null || true)
  reason=$(printf '%s' "$payload" | jq -r '.reason // ""' 2>/dev/null || true)
fi
case "$action" in
  session)
    # A compaction restart keeps the live turn.
    [ -n "$instance" ] && [ "$source" != compact ] || exit 0
    "$SCRIPT_DIR/set-state.sh" idle "" "$instance" "" "$kind" reset </dev/null
    "$SCRIPT_DIR/auto-desc.sh" clear "$source" </dev/null
    ;;
  working)
    printf '%s' "$payload" | "$SCRIPT_DIR/auto-desc.sh" set || true
    "$SCRIPT_DIR/set-state.sh" working "" "$instance" "" "$kind" </dev/null
    ;;
  blocked) "$SCRIPT_DIR/set-state.sh" asking "$message" "$instance" "" "$kind" </dev/null ;;
  idle) "$SCRIPT_DIR/set-state.sh" finished "" "$instance" "" "$kind" </dev/null ;;
  # The user's own Esc: settle without claiming an unseen completion.
  interrupt) "$SCRIPT_DIR/set-state.sh" idle "" "$instance" "" "$kind" </dev/null ;;
  end)
    [ -n "$instance" ] || exit 0
    "$SCRIPT_DIR/clear-state.sh" "${reason:-exit}" "$instance" "$kind" </dev/null
    ;;
esac
