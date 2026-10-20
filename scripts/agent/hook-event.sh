#!/usr/bin/env bash
# The Kimi and MastraCode hook command: map one hook ACTION, with the
# provider's JSON payload on stdin, to the state scripts.
# Usage: hook-event.sh <kimi|mastracode> <session|working|blocked|idle|interrupt|end>
set -eu
[ -n "${TMUX_PANE:-}" ] || exit 0
kind="${1:-}" action="${2:-}"
case "$action" in session|working|blocked|idle|interrupt|end) ;; *) exit 0 ;; esac
# How each provider's command line reads: its binary names, the options that
# take a value (and those whose value is optional), and headless subcommands.
case "$kind" in
  kimi)
    names="kimi" values="-m --model --output-format --skills-dir --agent --agent-file --add-dir"
    optional="-S --session" commands="acp web server rc remote"
    ;;
  # MastraCode's other options are undocumented: a `-p` after an option value
  # is missed (the run then reports, as before).
  mastracode) names="mastracode mastracode.js mastracode.mjs" values="" optional="" commands="" ;;
  *) exit 0 ;;
esac

# Headless runs (`kimi -p`, `kimi acp|web|rc`, `mastracode --prompt`) can
# inherit TMUX_PANE from an agent pane and must not report or steal its
# identity. The payload has no mode field, so read the nearest provider
# ancestor's argv. `ps` loses quoting, so only words before the first
# non-option word count (a prompt like "fix the -p flag" is never parsed).
headless() {
  local pid=$PPID depth=0 args word seen skip
  set -f
  while [ "$depth" -lt 4 ] && [ "${pid:-0}" -gt 1 ]; do
    args=$(ps -o args= -p "$pid" 2>/dev/null) || break
    seen=0 skip=""
    for word in $args; do
      if [ "$seen" = 0 ]; then
        [[ " $names " != *" ${word##*/} "* ]] || seen=1
        continue
      fi
      case "$skip:$word" in
        value:*) skip=""; continue ;;
        optional:-*) skip="" ;;
        optional:*) skip=""; continue ;;
      esac
      case "$word" in
        -p|--prompt|--prompt=*|-p?*) set +f; return 0 ;;
        -*)
          [[ " $values " != *" $word "* ]] || skip=value
          [[ " $optional " != *" $word "* ]] || skip=optional
          ;;
        *)
          [[ " $commands " != *" $word "* ]] || { set +f; return 0; }
          break
          ;;
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

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
payload=$(cat 2>/dev/null || true)
instance="" message="" source="" reason="" prompt=""
if command -v jq >/dev/null 2>&1; then
  # One line: set-state and auto-desc turn newlines into spaces and drop
  # control characters anyway.
  fields=$(printf '%s' "$payload" | jq -r '[.session_id // "", .source // "", .reason // "", .message // .tool_name // "", (.prompt // "" | tostring | .[:500])]
    | map(tostring | gsub("\n"; " ") | gsub("\u001f"; "")) | join("\u001f")' 2>/dev/null || true)
  IFS=$'\037' read -r instance source reason message prompt <<< "$fields"
fi
case "$action" in
  session)
    # A compaction restart keeps the live turn.
    [ -n "$instance" ] && [ "$source" != compact ] || exit 0
    "$SCRIPT_DIR/set-state.sh" idle "" "$instance" "" "$kind" reset </dev/null
    "$SCRIPT_DIR/auto-desc.sh" clear "$source" </dev/null
    ;;
  working)
    # Only a prompt submit carries a prompt; tool events skip auto-desc.
    [ -z "$prompt" ] || "$SCRIPT_DIR/auto-desc.sh" set "$prompt" </dev/null || true
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
