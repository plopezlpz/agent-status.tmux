#!/usr/bin/env bash
# agent-status.tmux — Kimi Code hook adapter.
set -eu
[ -n "${TMUX_PANE:-}" ] || exit 0
case "${1:-}" in session|working|blocked|idle|end) action="$1" ;; *) exit 0 ;; esac

# Headless runs (`kimi -p`, `kimi acp|web|rc`) can inherit TMUX_PANE from an
# agent pane and must not report or steal its identity. Kimi's hook payload has
# no mode field, so read the nearest kimi ancestor's argv once per hook. `ps`
# loses quoting, so only words before the first non-option word count (a
# prompt like "fix the -p flag" is never parsed); Kimi's value-taking options
# skip their value, -S/--session only when one follows.
headless() {
  local pid=$PPID depth=0 args word seen skip
  set -f
  while [ "$depth" -lt 4 ] && [ "${pid:-0}" -gt 1 ]; do
    args=$(ps -o args= -p "$pid" 2>/dev/null) || break
    seen=0 skip=""
    for word in $args; do
      if [ "$seen" = 0 ]; then
        [ "${word##*/}" != kimi ] || seen=1
        continue
      fi
      case "$skip:$word" in
        value:*) skip=""; continue ;;
        optional:-*) skip="" ;;
        optional:*) skip=""; continue ;;
      esac
      case "$word" in
        -p|--prompt|--prompt=*|-p?*) set +f; return 0 ;;
        -m|--model|--output-format|--skills-dir|--agent|--agent-file|--add-dir) skip=value ;;
        -S|--session) skip=optional ;;
        -*) ;;
        acp|web|server|rc|remote) set +f; return 0 ;;
        *) break ;;
      esac
    done
    [ "$seen" = 0 ] || break
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || break
    depth=$((depth + 1))
  done
  set +f
  return 1
}
! headless || exit 0

SCRIPT_DIR=$(tmux show-option -gqv @agent-scripts-dir 2>/dev/null || true)
: "${SCRIPT_DIR:=${HOME}/.tmux/plugins/agent-status.tmux/scripts/agent}"
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
    # Kimi sends startup/resume; a compaction restart keeps the live turn.
    [ -n "$instance" ] && [ "$source" != compact ] || exit 0
    "$SCRIPT_DIR/set-state.sh" idle "" "$instance" "" kimi reset </dev/null
    "$SCRIPT_DIR/auto-desc.sh" clear "$source" </dev/null
    ;;
  working)
    printf '%s' "$payload" | "$SCRIPT_DIR/auto-desc.sh" set || true
    "$SCRIPT_DIR/set-state.sh" working "" "$instance" "" kimi </dev/null
    ;;
  blocked) "$SCRIPT_DIR/set-state.sh" asking "$message" "$instance" "" kimi </dev/null ;;
  idle) "$SCRIPT_DIR/set-state.sh" finished "" "$instance" "" kimi </dev/null ;;
  end)
    [ -n "$instance" ] || exit 0
    "$SCRIPT_DIR/clear-state.sh" "${reason:-exit}" "$instance" kimi </dev/null
    ;;
esac
