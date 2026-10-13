#!/usr/bin/env bash
# agent-status.tmux — MastraCode hook adapter.
set -eu
[ -n "${TMUX_PANE:-}" ] || exit 0
case "${1:-}" in session|working|blocked|idle|interrupt|end) action="$1" ;; *) exit 0 ;; esac

# Headless runs (`mastracode --prompt`) can inherit TMUX_PANE from an agent
# pane and must not report or steal its identity. The hook payload has no mode
# field, so read the nearest mastracode ancestor's argv once per hook. `ps`
# loses quoting, so only words before the first non-option word count; with
# MastraCode's other options undocumented, a `-p` after an option value is
# missed (the run then reports, as before).
headless() {
  local pid=$PPID depth=0 args word seen
  set -f
  while [ "$depth" -lt 4 ] && [ "${pid:-0}" -gt 1 ]; do
    args=$(ps -o args= -p "$pid" 2>/dev/null) || break
    seen=0
    for word in $args; do
      if [ "$seen" = 0 ]; then
        case "${word##*/}" in mastracode|mastracode.js|mastracode.mjs) seen=1 ;; esac
        continue
      fi
      case "$word" in
        -p|--prompt|--prompt=*|-p?*) set +f; return 0 ;;
        -*) ;;
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
# An older checkout named by @agent-scripts-dir may predate hook-event.sh.
[ -x "$SCRIPT_DIR/hook-event.sh" ] || exit 0
exec "$SCRIPT_DIR/hook-event.sh" mastracode "$action"
