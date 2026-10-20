#!/usr/bin/env bash
# The Kimi, MastraCode and Codex hook command: map one hook ACTION, with the
# provider's JSON payload on stdin, to the state scripts.
# Usage: hook-event.sh <kimi|mastracode|codex> <session|working|tool|blocked|idle|interrupt|end>
set -eu
[ -n "${TMUX_PANE:-}" ] || exit 0
kind="${1:-}" action="${2:-}"
case "$action" in session|working|tool|blocked|idle|interrupt|end) ;; *) exit 0 ;; esac
# How each provider's command line reads: its binary names, the options that
# take a value (and those whose value is optional), headless subcommands, and
# whether -p/--prompt makes a run headless.
first="" prompts=1
case "$kind" in
  kimi)
    names="kimi" values="-m --model --output-format --skills-dir --agent --agent-file --add-dir"
    optional="-S --session" commands="acp web server rc remote"
    ;;
  # MastraCode's other options are undocumented: a `-p` after an option value
  # is missed (the run then reports, as before).
  mastracode) names="mastracode mastracode.js mastracode.mjs" values="" optional="" commands="" ;;
  # Codex: only the binary itself counts (or a script run by an interpreter),
  # never a word of another command line; its -p is --profile. app-server
  # covers the shared background server, which runs the hooks of every
  # session attached to it with the environment of the terminal that started
  # it, so its TMUX_PANE is not the session's pane.
  codex)
    names="codex" first=1 prompts=""
    values="-c --config --enable --disable --remote --remote-auth-token-env -i --image -m --model --local-provider -p --profile -s --sandbox -C --cd --add-dir -a --ask-for-approval"
    optional="" commands="exec e review app-server exec-server mcp-server cloud sandbox"
    ;;
  *) exit 0 ;;
esac

# Headless runs (`kimi -p`, `kimi acp|web|rc`, `mastracode --prompt`,
# `codex exec`, Codex's background server) can inherit TMUX_PANE from an agent
# pane and must not report or steal its identity. The payload has no mode
# field, so read the nearest provider ancestor's argv. Only words before the
# first non-option word count (a prompt like "fix the -p flag" is never
# parsed). Where /proc has the argv, a quoted prompt stays one word, and one
# with a blank in it is a prompt. Elsewhere `ps` loses quoting, so a prompt
# given on the command line that starts with a subcommand's name ("review my
# change") reads as that subcommand.
headless() {
  local pid=$PPID depth=0 args word seen skip n ppid words
  set -f
  while [ "$depth" -lt 4 ] && [ "${pid:-0}" -gt 1 ]; do
    read -r ppid args <<< "$(ps -o ppid=,args= -p "$pid" 2>/dev/null)" || break
    [ -n "$args" ] || break
    # shellcheck disable=SC2206 # split on blanks, globbing is off
    words=($args)
    if [ -r "/proc/$pid/cmdline" ]; then
      words=()
      while IFS= read -r -d '' word || [ -n "$word" ]; do words+=("$word"); done 2>/dev/null < "/proc/$pid/cmdline" || true
      # None, or one rewritten into a title: back to the split.
      if [ "${#words[@]}" = 0 ] || { [ "${#words[@]}" = 1 ] && [[ "${words[0]}" == *[[:space:]]* ]]; }; then
        # shellcheck disable=SC2206
        words=($args)
      fi
    fi
    seen=0 skip="" n=0
    for word in "${words[@]}"; do
      n=$((n + 1))
      if [ "$seen" = 0 ]; then
        if [[ " $names " == *" ${word##*/} "* ]]; then seen=1; continue; fi
        # Codex: argv[0], or the script an interpreter runs.
        [ -z "$first" ] || { [ "$n" = 1 ] && [[ " node bash sh " == *" ${word##*/} "* ]]; } || break
        continue
      fi
      case "$skip:$word" in
        value:*) skip=""; continue ;;
        optional:-*) skip="" ;;
        optional:*) skip=""; continue ;;
      esac
      if [ -n "$prompts" ]; then
        case "$word" in -p|--prompt|--prompt=*|-p?*) set +f; return 0 ;; esac
      fi
      case "$word" in
        -*)
          [[ " $values " != *" $word "* ]] || skip=value
          [[ " $optional " != *" $word "* ]] || skip=optional
          ;;
        *[[:space:]]*) break ;;
        *)
          [[ " $commands " != *" $word "* ]] || { set +f; return 0; }
          break
          ;;
      esac
    done
    [ "$seen" = 0 ] || break
    pid=$ppid
    depth=$((depth + 1))
  done
  set +f
  return 1
}
! headless || exit 0

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"

# Codex's payload is what set-state and clear-state read from a Claude hook
# (session_id, hook_event_name, source, agent_id, tool_name, prompt, ...):
# hand it over untouched. A hook must print nothing (SessionStart and
# UserPromptSubmit output reaches the model) and exit 0 (2 blocks the event).
if [ "$kind" = codex ]; then
  export AGENT_STATUS_KIND=codex
  case "$action" in
    session) state=idle ;;
    working) state=working ;;
    # The model asking the user a question (request_user_input) waits on
    # them like a permission prompt; its PostToolUse ends the ask.
    tool)
      payload=$(cat 2>/dev/null || true)
      state=working
      case "$payload" in *'"tool_name":"request_user_input"'*) state=asking ;; esac
      "$SCRIPT_DIR/set-state.sh" "$state" <<< "$payload" >/dev/null 2>&1 || true
      exit 0
      ;;
    blocked) state=asking ;;
    idle) state=finished ;;
    # The user's own Esc: settle without claiming an unseen completion.
    interrupt) state=idle ;;
    end) "$SCRIPT_DIR/clear-state.sh" >/dev/null 2>&1 || true; exit 0 ;;
  esac
  "$SCRIPT_DIR/set-state.sh" "$state" >/dev/null 2>&1 || true
  exit 0
fi

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
  working|tool)
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
