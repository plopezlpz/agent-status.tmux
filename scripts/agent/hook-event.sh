#!/usr/bin/env bash
# The Kimi, MastraCode, Codex, Gemini CLI and Qwen Code hook command: map one
# hook ACTION, with the provider's JSON payload on stdin, to the state scripts.
# Usage: hook-event.sh <kimi|mastracode|codex|gemini|qwen> <session|working|tool|blocked|idle|interrupt|end>
set -eu
[ -n "${TMUX_PANE:-}" ] || exit 0
kind="${1:-}" action="${2:-}"
case "$action" in session|working|tool|blocked|idle|interrupt|end) ;; *) exit 0 ;; esac
# How each provider's command line reads: its binary names, the options that
# take a value (and those whose value is optional, or a list of them),
# headless subcommands and options, options that keep a run interactive,
# whether -p/--prompt makes a run headless, and whether any other word (a
# prompt) does.
first="" prompts=1 foreground="" flags="" interactive="" arrays="" positional=""
case "$kind" in
  # Kimi retitles its process "kimi-code" as it starts, cut to the length of
  # its command line ("kimi -p" turns into "kimi-co"), so its argv is gone by
  # the time a hook runs. A run reports only as the foreground job of its
  # terminal: a headless one started by another agent's tool has no terminal
  # or runs in the background.
  kimi)
    names="kimi kimi- kimi-c kimi-co kimi-cod kimi-code" foreground=1
    values="-m --model --output-format --skills-dir --agent --agent-file --add-dir"
    optional="-S --session" commands="acp web server rc remote"
    ;;
  # MastraCode's headless runs (a prompt argument, --acp) fire tool hooks
  # only: below, a pane reports only what the process that registered it
  # (SessionStart) sends.
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
  # Gemini CLI relaunches itself as a child (node, a heap flag, the script),
  # which runs the hooks. A prompt argument stays interactive in a terminal;
  # -p and --acp (an editor's server) don't. Gemini also runs headless when
  # its input or output isn't a terminal, which argv doesn't show: as for
  # Kimi, a run reports only as the foreground job of its terminal, which one
  # started by another agent's tool is not.
  gemini)
    names="gemini gemini.js" foreground=1 flags="--acp --experimental-acp"
    values="-m --model -i --prompt-interactive --approval-mode --policy --admin-policy --allowed-mcp-server-names --allowed-tools -e --extensions --session-file --session-id --include-directories -o --output-format"
    optional="-r --resume -w --worktree --delete-session" commands=""
    ;;
  # Qwen Code runs its CLI in the launcher's own process (node .../qwen). A
  # prompt argument, a subcommand (serve, ...), -p and --acp run headless;
  # -i keeps a prompt interactive. It also runs headless when its input isn't
  # a terminal, which argv doesn't show: as for Kimi, a run reports only as
  # the foreground job of its terminal, which one started by another agent's
  # tool is not.
  qwen)
    names="qwen" first=1 foreground=1 positional=1 commands=""
    flags="--acp --experimental-acp" interactive="-i --prompt-interactive"
    values="-m --model --advisor --system-prompt --append-system-prompt --output-style --sandbox-image --approval-mode --channel --mcp-config --openai-logging-dir --openai-api-key --openai-base-url --input-format -o --output-format --json-fd --json-file --json-schema --input-file --session-id --max-session-turns --max-wall-time --max-tool-calls --max-subagent-depth --auth-type --proxy --telemetry-target --telemetry-otlp-endpoint --telemetry-otlp-protocol --telemetry-outfile"
    optional="-s --sandbox -r --resume --worktree"
    arrays="--fallback-model --allowed-mcp-server-names --disable-mcp-server --allowed-tools -e --extensions --include-directories --add-dir --core-tools --exclude-tools --disabled-slash-commands"
    ;;
  *) exit 0 ;;
esac
# Gemini and Qwen show what a hook prints (Qwen gives a SessionStart or
# UserPromptSubmit hook's output to the model) and take exit status 2 as a
# block: print nothing and always succeed.
case "$kind" in gemini|qwen) exec >/dev/null 2>&1; trap 'exit 0' EXIT ;; esac

# Headless runs (`kimi -p`, `kimi acp|web|rc`, `mastracode --prompt`,
# `codex exec`, Codex's background server, `gemini -p`, `qwen "fix it"`) can
# inherit TMUX_PANE from an agent pane and must not report or steal its
# identity. The payload has no mode field, so read the nearest provider
# ancestor's argv (and for Kimi, Gemini and Qwen, whether it is its
# terminal's foreground job).
# Only words before the first non-option word count (a prompt like "fix the
# -p flag" is never parsed). Where /proc has the argv, a quoted prompt stays one word, and one
# with a blank in it is a prompt. Elsewhere `ps` loses quoting, so a prompt
# given on the command line that starts with a subcommand's name ("review my
# change") reads as that subcommand.
headless() {
  local pid=$PPID depth=0 args word seen skip n ppid words pgid tpgid
  set -f
  while [ "$depth" -lt 4 ] && [ "${pid:-0}" -gt 1 ]; do
    # One ps per ancestor; its process group and its terminal's foreground
    # one are numbers (0 or -1 without a terminal), so the fields split.
    read -r ppid pgid tpgid args <<< "$(ps -o ppid=,pgid=,tpgid=,args= -p "$pid" 2>/dev/null)" || break
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
        array:-*) skip="" ;;
        array:*) continue ;;
      esac
      if [ -n "$prompts" ]; then
        case "$word" in -p|--prompt|--prompt=*|-p?*) set +f; return 0 ;; esac
      fi
      case "$word" in
        -*)
          [[ " $flags " != *" ${word%%=*} "* ]] || { set +f; return 0; }
          [[ " $interactive " != *" ${word%%=*} "* ]] || break
          [[ " $values " != *" $word "* ]] || skip=value
          [[ " $optional " != *" $word "* ]] || skip=optional
          [[ " $arrays " != *" $word "* ]] || skip=array
          ;;
        *[[:space:]]*) [ -z "$positional" ] || { set +f; return 0; }; break ;;
        *)
          [[ " $commands " != *" $word "* ]] && [ -z "$positional" ] || { set +f; return 0; }
          break
          ;;
      esac
    done
    if [ "$seen" = 1 ]; then
      agent_pid=$pid
      if [ -n "$foreground" ]; then
        [ -n "$pgid" ] && [ "$pgid" = "$tpgid" ] || { set +f; return 0; }
      fi
      break
    fi
    pid=$ppid
    depth=$((depth + 1))
  done
  set +f
  return 1
}
agent_pid=""
! headless || exit 0

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"

# Gemini's AfterTool, after every tool call, is the hot path. Its session id
# is in the environment, so the payload (with the tool's whole output) is
# never read: Gemini ignores the closed pipe.
if [ "$kind" = gemini ] && [ "$action" = tool ]; then
  [ -z "${GEMINI_SESSION_ID:-}" ] || "$SCRIPT_DIR/set-state.sh" working "" "$GEMINI_SESSION_ID" "" gemini </dev/null
  exit 0
fi

# Codex's and Qwen's payloads are what set-state and clear-state read from a
# Claude hook (session_id, hook_event_name, source, agent_id, tool_name,
# prompt, ...): hand them over untouched. A hook must print nothing
# (SessionStart and UserPromptSubmit output reaches the model) and exit 0 (2
# blocks the event).
if [ "$kind" = codex ] || [ "$kind" = qwen ]; then
  export AGENT_STATUS_KIND=$kind
  case "$action" in
    session) state=idle ;;
    working) state=working ;;
    # The model asking the user a question (request_user_input) or for more
    # permissions (request_permissions) waits on them like a permission
    # prompt, without a PermissionRequest; its PostToolUse ends the ask.
    tool)
      payload=$(cat 2>/dev/null || true)
      state=working
      case "$payload" in *'"tool_name":"request_user_input"'*|*'"tool_name":"request_permissions"'*) state=asking ;; esac
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
only="" instance="" event="" message="" source="" reason="" stop="" prompt=""
if command -v jq >/dev/null 2>&1; then
  # One line: set-state and auto-desc turn newlines into spaces and drop
  # control characters anyway. The prompt: Kimi sends its content parts,
  # MastraCode a user_message.
  fields=$(printf '%s' "$payload" | jq -r '[.session_id // "", .hook_event_name // "", .source // "", .reason // "",
      .stop_reason // "", .message // .tool_name // "",
      (.prompt // .user_message // "" | if type == "array" then map(select(type == "object" and .type == "text") | .text) | join(" ")
        elif type == "string" then . else "" end | .[:500])]
    | map(tostring | gsub("\n"; " ") | gsub("\u001f"; "")) | join("\u001f")' 2>/dev/null || true)
  IFS=$'\037' read -r instance event source reason stop message prompt <<< "$fields"
fi
# Only a prompt submit names the pane (Kimi's TurnStarted and SubagentStart
# carry a prompt too, and Gemini's AfterAgent the turn's).
case "${event:-UserPromptSubmit}" in UserPromptSubmit|BeforeAgent) ;; *) prompt="" ;; esac

if [ "$kind" = mastracode ]; then
  # MastraCode's session_id is "session-init" until its first thread exists,
  # then follows the thread (/new, a switch), with no new SessionStart: its
  # process is the identity. Only that process's TUI fires SessionStart, so
  # every other event reports only into the pane it registered. Tool hooks,
  # the hot path, leave that to set-state's own read of the pane (only); a
  # prompt, which titles the pane first, and an end check it here.
  instance="$agent_pid"
  if [ "$action" != session ] && [ "$action" != end ] && [ -z "$prompt" ]; then
    only=only
  elif [ "$action" != session ]; then
    registered=$(tmux display -p -t "$TMUX_PANE" '#{@agent-kind}:#{@agent-instance}' 2>/dev/null || true)
    if [ "$registered" != "mastracode:${instance:+mastracode:$instance}" ]; then
      # MastraCode exits without waiting for its SessionEnd hook, which may
      # run once the process is gone: it ends a registration whose process
      # is gone.
      pid=${registered#mastracode:mastracode:}
      [ "$action" = end ] && [ "$pid" != "$registered" ] && [[ "$pid" =~ ^[0-9]+$ ]] && ! ps -p "$pid" >/dev/null 2>&1 || exit 0
      instance=$pid
    fi
  fi
  # AgentEnd reports a run's end (Stop follows it, and calls a suspended run
  # complete). A suspended run waits on the user: its question or approval
  # asks (Notification, PermissionRequest).
  case "$action:$event:$stop" in
    idle:Stop:*|idle:*:suspended) exit 0 ;;
    idle:*:aborted) action=interrupt ;;
  esac
fi
# MastraCode notifies of the waits on the user (and of a finished run);
# Gemini only of a confirmation it shows.
if [ "$event" = Notification ] && [ "$kind" != gemini ]; then
  case "$reason" in ask_question|tool_approval|plan_approval|sandbox_access) ;; *) exit 0 ;; esac
fi

if [ "$kind" = kimi ] && [[ "$TMUX_PANE" =~ ^%[0-9]+$ ]]; then
  # Kimi runs a subagent as a full agent, whose turn ends with its own Stop,
  # StopFailure or Interrupt, under the session's id and no agent id. Count
  # the subagents started (@agent-subagents, in tmux, which updates it
  # atomically) and take an end while one runs as a subagent's: the last
  # end is the turn's. A prompt or a new session starts the count over.
  case "$action:$event" in
    working:SubagentStart)
      tmux set-option -p -t "$TMUX_PANE" -F @agent-subagents '#{e|+:#{@agent-subagents},1}' 2>/dev/null || true
      ;;
    idle:*|interrupt:*)
      running=$(tmux display -p -t "$TMUX_PANE" '#{@agent-subagents}' \; if -F -t "$TMUX_PANE" '#{e|>:#{@agent-subagents},0}' \
        "set-option -p -t $TMUX_PANE -F @agent-subagents '#{e|-:#{@agent-subagents},1}'" 2>/dev/null || true)
      case "$running" in ''|0|*[!0-9]*) ;; *) action=working ;; esac
      ;;
    working:UserPromptSubmit|session:*)
      [ "$source" = compact ] || tmux if -F -t "$TMUX_PANE" '#{@agent-subagents}' "set-option -p -u -t $TMUX_PANE @agent-subagents" 2>/dev/null || true
      ;;
  esac
fi

case "$action" in
  session)
    [ -n "$instance" ] || [ "$kind" = mastracode ] || exit 0
    # A compaction restart keeps the live turn.
    [ "$source" != compact ] || exit 0
    "$SCRIPT_DIR/set-state.sh" idle "" "$instance" "" "$kind" reset </dev/null
    "$SCRIPT_DIR/auto-desc.sh" clear "$source" </dev/null
    ;;
  working|tool)
    # Gemini's in-app /resume switches sessions without an event: a prompt
    # rebinds the pane to the session it goes to.
    [ "$kind" != gemini ] || [ -z "$instance" ] || "$SCRIPT_DIR/set-state.sh" working "" "$instance" "" gemini bind </dev/null || true
    [ -z "$prompt" ] || "$SCRIPT_DIR/auto-desc.sh" set "$prompt" </dev/null || true
    "$SCRIPT_DIR/set-state.sh" working "" "$instance" "" "$kind" "$only" </dev/null
    ;;
  blocked) "$SCRIPT_DIR/set-state.sh" asking "$message" "$instance" "" "$kind" "$only" </dev/null ;;
  idle) "$SCRIPT_DIR/set-state.sh" finished "" "$instance" "" "$kind" "$only" </dev/null ;;
  # The user's own Esc: settle without claiming an unseen completion.
  interrupt) "$SCRIPT_DIR/set-state.sh" idle "" "$instance" "" "$kind" "$only" </dev/null ;;
  end)
    [ -n "$instance" ] || [ "$kind" = mastracode ] || exit 0
    "$SCRIPT_DIR/clear-state.sh" "${reason:-exit}" "$instance" "$kind" </dev/null
    ;;
esac
