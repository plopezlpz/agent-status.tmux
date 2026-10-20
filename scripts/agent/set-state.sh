#!/usr/bin/env bash
# Update the current pane's agent state and optionally notify.
# Usage: set-state.sh <working|asking|finished|idle> [message] [instance] [seq] [kind] [reset|bind|only]
# `bind` is a reset unless the pane already reports that instance; `only`
# reports only into a pane that already does.
# `finished` is stored as idle + unseen: an idle completion not yet seen.
# Claude hooks (and Codex hooks, through hook-event.sh) pass the state alone,
# with their payload on stdin (kind $AGENT_STATUS_KIND, else claude); for them
# it also keeps the first prompt as @agent-auto-description and tracks open
# permission prompts in @agent-asks (and, for Codex, @agent-settled).
set -eu

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
agent_pane_guard

raw_state="${1:-}"
message="${2:-}"
instance="${3:-}"
seq="${4:-}"
kind="${5:-${AGENT_STATUS_KIND:-}}"
reset="${6:-}"

case "$raw_state" in
  working)  state=working; unseen=0; notify_state="" ;;
  asking)   state=asking;  unseen=0; notify_state=asking ;;
  finished) state=idle;    unseen=1; notify_state=finished ;;
  idle)     state=idle;    unseen=""; notify_state="" ;;
  *) echo "set-state: invalid state '$raw_state'" >&2; exit 2 ;;
esac

# read_pane: all a report needs from tmux, in one call: the pane's agent
# options, the time (%s), notification and log settings, and whether the
# most recently active client shows the pane with terminal focus.
sep=$'\037'
read_pane() {
  IFS="$sep" read -r cur_pane pane_dead prev_state prev_unseen prev_instance prev_seq prev_kind \
    prev_state_at prev_transcript prev_asks prev_settled described now notify_timeout team_delay pane_active viewers clients \
    socket client log_file log_time name <<< "$(tmux display -t "$TMUX_PANE" -p "#{pane_id}$sep#{pane_dead}$sep#{@agent-state}$sep#{@agent-unseen}$sep#{@agent-instance}$sep#{@agent-seq}$sep#{@agent-kind}$sep#{@agent-state-at}$sep#{@agent-transcript}$sep#{@agent-asks}$sep#{@agent-settled}$sep#{?@agent-auto-description,1,}$sep%s$sep#{@agent-notify-timeout}$sep#{@agent-notify-team-delay}$sep#{pane_active}$sep#{window_active_clients_list}$sep#{L/t:#{?client_control_mode,,#{client_name}=#{client_flags} }}$sep#{socket_path}$sep#{client_name}$sep$AGENT_LOG_FIELDS$sep#S / #W" 2>/dev/null || true)"
  # display -t on a vanished pane silently describes another one.
  [ "$cur_pane" = "$TMUX_PANE" ] && [ "$pane_dead" != 1 ] || exit 0
}

# A report that repeats the pane's state changes nothing, and each Claude tool
# call makes two, often several at once: settle those (working or asking,
# without seq or reset) from one read, before stdin, jq or the lock. Identity
# cannot change then either, since a pane with an instance rejects any other.
# A Claude ask still counts: it records who asks.
if [ "$unseen" = 0 ] && [ -z "$seq" ] && { [ -z "$reset" ] || [ "$reset" = only ]; } && { [ "$state" = working ] || [ "$#" -gt 1 ]; }; then
  read_pane
  case "$prev_state_at" in ''|*[!0-9]*) ;; *)
    if [ "$state:0" = "$prev_state:$prev_unseen" ] && [ -n "$prev_instance" ] && [ "${kind:-$prev_kind}" = "$prev_kind" ]; then
      exit 0
    fi
  esac
fi

# Claude hooks provide identity and event metadata on stdin; their commands
# pass the state alone. Adapters always pass positional arguments and may leave
# stdin open (Node execFile), so never read it for them: jq would block.
hook_name="" background="" team="" transcript="" src="" agent="" tool="" prompt="" hook_message="" hook_error="" call="" returned="" title=""
if [ "$#" -eq 1 ] && [ ! -t 0 ] && command -v jq >/dev/null 2>&1; then
  # background: in-flight subagents/workflows. Background shells and monitors
  # can run indefinitely and never resume the turn by themselves.
  # team: live agent-team teammates. They stay "running" while idle, so they
  # cannot hold a Stop, but each message from one resumes the lead turn.
  # Entry types are friendly labels, or the raw discriminant when unknown.
  # agent, tool: who asks or proceeds (agent_id: empty on the main thread),
  # as option-safe words. prompt: its start, on one line, without the text
  # pasted into it (Claude marks it) unless that is all there is.
  # message, error: for the notification (StopFailure carries only its error
  # type: rate_limit, overloaded, ...), on one line.
  # call (Codex): a hash of the tool's command (a shell command or a patch),
  # the same in its PreToolUse, PermissionRequest and PostToolUse, which
  # carry no common call id.
  # returned (Claude): the subagent a main-thread Agent (Task) call ran in
  # the foreground and that has now returned. title (Claude): the session's
  # own title (--name, /rename), if it has one.
  metadata=$(jq -r --arg kind "$kind" 'def live(types): (.background_tasks // [])
      | if type == "array" then . else [] end
      | map(select(type == "object" and ((.type // "") | IN(types))
          and ((.status // "running") | IN("running", "pending"))))
      | length | tostring;
    def word: . // "" | tostring | .[:128] | gsub("[^A-Za-z0-9._:-]"; "_");
    def line: tostring | .[:500] | gsub("[\n\r\t]"; " ") | gsub("[\u0000-\u001f\u007f]"; "");
    [.session_id // "", .hook_event_name // "",
      live("subagent", "workflow", "local_agent", "local_workflow"),
      live("teammate", "in_process_teammate"),
      (.transcript_path // "" | tostring), (.source // "" | tostring),
      (.agent_id, .tool_name | word),
      (.prompt // "" | tostring
        | (gsub("<pasted_content[^>]*>[\\s\\S]*?</pasted_content[^>]*>"; " ") | select(test("\\S")))
          // gsub("</?pasted_content[^>]*>"; " ")
        | sub("^\\s+"; "") | line),
      (.message // .title // "", .error // "error" | tostring | gsub("[\u0000-\u001f]"; " ")),
      (if $kind == "codex" then .tool_input.command? // null else null end
        | if type == "string" then .[:4096] + "#\(length)" | explode
            | reduce .[] as $c (5381; (. * 33 + $c) % 4294967296) | tostring else "" end),
      (if .hook_event_name == "PostToolUse" and (.agent_id // "") == "" and (.tool_name | IN("Agent", "Task"))
          and (.tool_response | type) == "object" and .tool_response.status == "completed"
        then .tool_response.agentId else "" end | word),
      (.session_title // "" | line)]
    | join("\u001f")' 2>/dev/null || true)
  IFS="$sep" read -r instance hook_name background team transcript src agent tool prompt hook_message hook_error call returned title <<< "$metadata"
  [ -z "$hook_name" ] || kind="${kind:-claude}"
fi
# Auto-compaction restarts the session mid-turn (SessionStart source=compact)
# under the same session ID: keep the live state, refresh metadata only.
compact=""
if [ "$hook_name" = SessionStart ]; then
  if [ "$src" = compact ]; then compact=1; else [ -n "$reset" ] || reset=reset; fi
fi
# A Claude Stop while background agents are still running is not a finish:
# each report-back resumes the turn. Keep the pane working, unnotified, so only
# the final Stop (no running subagent/workflow) alerts.
held=""
case "$background" in ''|*[!0-9]*) background=0 ;; esac
if [ "$raw_state" = finished ] && [ "$background" -gt 0 ]; then
  raw_state=working state=working unseen=0 notify_state="" held=" (background=$background)"
fi

# Keep option values bounded and sequence comparisons inside signed 64-bit.
agent_identity
case "$seq" in ""|*[!0-9]*) seq="" ;; esac
# Transcript (Claude's transcript_path): an absolute .jsonl path, printable only.
case "$transcript" in /*.jsonl) ;; *) transcript="" ;; esac
case "$transcript" in *[[:cntrl:]]*) transcript="" ;; esac
[ "${#transcript}" -le 1024 ] || transcript=""
[ "${#seq}" -le 18 ] || seq=""

agent_lock "pane-${TMUX_PANE#%}"
read_pane
# A subagent's end only ends its own asks: it never wakes a pane that has
# settled (its parent may have stopped before it).
if [ "$hook_name" = SubagentStop ] && [ "$prev_state" != asking ]; then exit 0; fi
# Nor do its other events: Codex subagents run in the background and may
# outlive their parent's turn, and nothing settles the pane after them. An
# ask from one still shows; @agent-settled keeps the settled pane's unseen
# value until its asks end. A main-thread event settles or resumes the pane
# itself. So do Claude dialogs without a tool: an MCP server may ask between
# turns.
settled=""
dialog=""
case "$raw_state:$hook_name" in asking:Elicitation|asking:Notification|working:ElicitationResult) dialog=1 ;; esac
if [ -n "$compact" ]; then
  settled="$prev_settled"
elif { [ "$kind" = codex ] && [ -n "$hook_name" ] && [ -n "$agent" ]; } || [ -n "$dialog" ]; then
  case "$prev_state" in
    idle) [ "$state" = asking ] || exit 0; settled="${prev_unseen:-0}" ;;
    asking) settled="$prev_settled" ;;
  esac
fi
case "$settled" in ''|0|1) ;; *) settled=0 ;; esac
if [ -n "$compact" ] && [ -n "$prev_state" ]; then
  state="$prev_state" unseen="${prev_unseen:-0}" raw_state=compact
fi
case "$prev_seq" in ""|*[!0-9]*) prev_seq="" ;; esac
# Earlier releases stored a Claude session id unscoped, without a kind: the
# same agent. The write below upgrades it.
same="$prev_instance"
if [ -z "$prev_kind" ] && [ -n "$kind" ] && [ "$kind:$prev_instance" = "$instance" ]; then same="$instance"; fi
# The OpenCode 1.x TUI binds the root session it shows, and its server
# plugin the root session of each prompt: a pane already bound to it keeps
# its label and state. A real rebind also drops the old session's label.
rebind=""
if [ "$reset" = only ]; then
  [ -n "$instance" ] && [ "$kind:$instance" = "$prev_kind:$prev_instance" ] || exit 0
  reset=""
elif [ "$reset" = bind ]; then
  [ -n "$instance" ] && [ "$instance" != "$same" ] || exit 0
  reset=reset rebind=1
fi

# Only an explicit session reset may replace a known agent instance. Reports
# without identity remain accepted for backwards-compatible/manual adapters.
if [ -n "$instance" ] && [ -n "$same" ] && [ "$instance" != "$same" ] && [ "$reset" != reset ]; then
  exit 0
fi
if [ "$reset" != reset ] && [ -n "$seq" ] && [ -n "$prev_seq" ] && [ "$instance" = "$same" ] && [ "$seq" -le "$prev_seq" ]; then
  exit 0
fi

# Ordinary idle reports must not acknowledge unseen work; only focus, a reset,
# or resumed active work clears completion attention.
if [ "$raw_state" = idle ]; then
  if [ "$reset" = reset ]; then unseen=0; else unseen="${prev_unseen:-0}"; fi
fi
case "$unseen" in 0|1) ;; *) unseen=0 ;; esac

# Claude and Codex permission prompts: tool hooks of parallel tools and
# subagents keep coming while a dialog is open, so an ask holds the pane
# asking until the turn ends or the agent that asked proceeds: its asked tool
# returns, it starts another, it gets a new prompt or it ends (Claude: or the
# Agent call that ran it in the foreground returns).
# @agent-asks lists the open ones as "<agent_id>/<tool>#<call>@<opened>".
# Codex runs an agent's shell calls in parallel and names every one Bash, so
# call is the hash of its command (none for a tool without one, and none
# from Claude). Only its own call's return ends it (a tool without a
# command: any return of that tool; write_stdin: the Bash call it writes
# to), or a later call: siblings of the asking call start with it (Claude
# runs read-only tools in parallel), while a call starting a few seconds on
# comes after the answer (a denied call returns nothing).
# Claude dialogs without a tool (an MCP server's form or URL, a sandboxed
# command's network request) carry no agent: "/@<opened>", ended by the
# answer to the form or by the main thread's next tool hook. Their
# notification adds one only when nothing else asks: a tool's own prompt has
# its PermissionRequest.
# Earlier releases kept Claude asks as "<agent_id>/<tool>": a pane may still
# hold one.
asks="$prev_asks"
if [ -n "$hook_name" ] && [ -z "$compact" ]; then
  case "$raw_state" in
    asking)
      key="$agent/$tool${call:+#$call}"
      case " $asks " in
        *" $key@"*|*" $key "*) ;;
        *) [ "$hook_name" = Notification ] && [ -n "$asks" ] || asks="${asks:+$asks }$key@$now" ;;
      esac
      ;;
    working)
      asks=""
      for ask in $prev_asks; do
        # A prompt to the main thread ends every ask.
        [ "$hook_name:$agent" != UserPromptSubmit: ] || continue
        case "$hook_name:$ask" in
          UserPromptSubmit:"$agent/"*|Stop*:"$agent/"*|SubagentStop:"$agent/"*) continue ;;
          PostToolUse*:"$agent/$tool#$call@"*|PostToolUse*:"$agent/$tool@"*|PostToolUse*:"$agent/$tool") continue ;;
          PostToolUse*:"$agent/@"*|ElicitationResult:"$agent/@"*) continue ;;
          PostToolUse*:"$agent/write_stdin"[#@]*) [ "$tool" != Bash ] || continue ;;
          PreToolUse:"$agent/"*)
            opened="${ask##*@}"
            case "$opened:$now" in *[!0-9:]*|:*|*:) continue ;; esac
            [ $((now - opened)) -lt 3 ] || continue
            ;;
        esac
        [ -z "$returned" ] || case "$ask" in "$returned/"*) continue ;; esac
        asks="${asks:+$asks }$ask"
      done
      [ -z "$asks" ] || state=asking
      # A subagent's last ask on a settled pane ended: settled again.
      if [ -z "$asks" ] && [ -n "$settled" ]; then
        state=idle unseen="$settled" raw_state=idle settled=""
      fi
      ;;
    *) asks="" ;;
  esac
fi

changed=0
[ "$state" = "$prev_state" ] && [ "$unseen" = "${prev_unseen:-0}" ] || changed=1

# Write only changed options, all in one tmux call (each call redraws every
# client). Same-state reports normally advance just @agent-seq.
w=(set-option -p -t "$TMUX_PANE")
args=()
[ "$state" = "$prev_state" ] || args+=("${w[@]}" @agent-state "$state" \;)
[ "$unseen" = "$prev_unseen" ] || args+=("${w[@]}" @agent-unseen "$unseen" \;)
case "$prev_state_at" in ''|*[!0-9]*) timestamp_needed=1 ;; *) timestamp_needed=0 ;; esac
if [ "$changed" -eq 1 ] || [ "$reset" = reset ] || [ "$timestamp_needed" -eq 1 ]; then
  args+=("${w[@]}" @agent-state-at "$now" \;)
fi
if [ -n "$instance" ]; then
  [ "$instance" = "$prev_instance" ] || args+=("${w[@]}" @agent-instance "$instance" \;)
elif [ "$reset" = reset ] && [ -n "$prev_instance" ]; then
  args+=("${w[@]}" -u @agent-instance \;)
fi
if [ -n "$seq" ]; then
  [ "$seq" = "$prev_seq" ] || args+=("${w[@]}" @agent-seq "$seq" \;)
elif [ "$reset" = reset ] && [ -n "$prev_seq" ]; then
  args+=("${w[@]}" -u @agent-seq \;)
fi
if [ -n "$kind" ] && [ "$kind" != "$prev_kind" ]; then
  args+=("${w[@]}" @agent-kind "$kind" \;)
fi
if [ -n "$transcript" ] && [ "$transcript" != "$prev_transcript" ]; then
  args+=("${w[@]}" @agent-transcript "$transcript" \;)
fi
if [ "$asks" != "$prev_asks" ]; then
  if [ -n "$asks" ]; then args+=("${w[@]}" @agent-asks "$asks" \;); else args+=("${w[@]}" -u @agent-asks \;); fi
fi
if [ "$settled" != "$prev_settled" ]; then
  if [ -n "$settled" ]; then args+=("${w[@]}" @agent-settled "$settled" \;); else args+=("${w[@]}" -u @agent-settled \;); fi
fi
# Any state change cancels a pending delayed notification (see below), and
# recomputes the window icon.
if [ "$changed" -eq 1 ]; then
  args+=("${w[@]}" @agent-notify-token "$$" \; set-option -wF -t "$TMUX_PANE" @agent-icon "$AGENT_ICON" \;)
fi
# The first prompt describes the pane until a new session (a Codex
# subagent's prompt doesn't), and a title the session has (Claude: --name,
# /rename) instead, from its start or the next prompt. It is free text, so it
# goes last: tmux skips the rest of a chain after a failed command.
text=""
if [ -z "$agent" ]; then
  case "$hook_name" in SessionStart|UserPromptSubmit) text="$title" ;; esac
  [ -n "$text" ] || [ "$hook_name" != UserPromptSubmit ] || [ -n "$described" ] || text="$prompt"
fi
[ -z "$text" ] || agent_auto_text "$text"
if [ -n "$text" ] && [ -n "$AUTO" ]; then
  args+=("${w[@]}" @agent-auto-description "$AUTO")
elif [ -n "$described" ] && { [ -n "$rebind" ] || { [ "$hook_name" = SessionStart ] && [ -z "$compact" ]; }; }; then
  args+=("${w[@]}" -u @agent-auto-description)
fi
# The pane vanished since the read: nothing left to update.
[ "${#args[@]}" -eq 0 ] || tmux "${args[@]}" 2>/dev/null || exit 0

agent_unlock

# Metadata-only reports need no log, notification, aggregation, or redraw.
[ "$changed" -eq 1 ] || exit 0

# Skip the desktop notification when the pane is already in view: the most
# recently active client shows it with terminal focus (focus-events). Only
# that client counts: tmux treats a client as focused until its terminal
# reports otherwise, and one left attached elsewhere (a phone over mosh)
# never does. A completion's unseen marker stays, since a locked screen or a
# terminal without focus reporting looks the same; focusing the pane or the
# next prompt (working) clears it.
top="${clients%% *}"
if [ -n "$notify_state" ] && [ -n "$top" ] && [ "$pane_active" = 1 ] &&
  [[ ",$viewers," == *",${top%%=*},"* && ",${top#*=}," == *,focused,* ]]; then
  notify_state="" held=" (focused, not notified)"
fi

agent_shown "$prev_state" "$prev_unseen"
agent_log "$log_file" "$log_time" "pane=$TMUX_PANE ${SHOWN:-none}->$raw_state$held"

# send_notification: show $title/$message with the first notifier found.
send_notification() {
  if command -v alerter >/dev/null 2>&1; then
    case "$notify_timeout" in ''|*[!0-9]*) notify_timeout=300 ;; esac
    (
      # This subshell inherits set -e: a dismissed/failed alerter must not
      # kill it before the click check.
      result=$(alerter \
        --title "$title" \
        --message "$message" \
        --group "agent-$TMUX_PANE" \
        --timeout "$notify_timeout" \
        --json 2>/dev/null) || true
      act=$(printf '%s' "$result" | jq -r '.activationType // empty' 2>/dev/null || true)
      case "$act" in
        contentsClicked|actionClicked) "$SCRIPT_DIR/focus-pane.sh" "$TMUX_PANE" "$socket" "$client" ;;
      esac
    ) >/dev/null 2>&1 &
  elif command -v terminal-notifier >/dev/null 2>&1; then
    printf -v click '%q %q %q %q' "$SCRIPT_DIR/focus-pane.sh" "$TMUX_PANE" "$socket" "$client"
    terminal-notifier \
      -title "$title" \
      -message "$message" \
      -execute "$click" \
      -group "agent-$TMUX_PANE" \
      >/dev/null 2>&1 &
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$message" >/dev/null 2>&1 &
  fi
}

case "$notify_state" in
  asking|finished)
    title="Agent • $notify_state"
    if [ "$hook_name" = StopFailure ]; then
      title="Agent • failed" message="$name: $hook_error"
    elif [ -z "$message" ]; then
      message="$hook_message"
    fi
    [ -n "$message" ] || message="$name"
    clean_text "$message"; message=$CLEAN
    case "$socket" in /*) ;; *) socket="" ;; esac
    case "$client" in *[!A-Za-z0-9._:/-]*) client="" ;; esac
    # An agent-team lead's turn ends each time it waits on its teammates, and
    # their next message resumes it moments later. With teammates alive, a
    # finished notification waits @agent-notify-team-delay seconds and is
    # dropped if the pane has changed state since (new token) or been seen
    # (unseen cleared). The pane state is not delayed.
    delay=0
    case "$team" in ''|*[!0-9]*) team=0 ;; esac
    if [ "$notify_state" = finished ] && [ "$team" -gt 0 ]; then
      case "$team_delay" in ''|*[!0-9]*) delay=10 ;; *) delay="$team_delay" ;; esac
    fi
    if [ "$delay" -gt 0 ]; then
      (
        sleep "$delay"
        now=$(tmux display -t "$TMUX_PANE" -p $'#{pane_id}\037#{@agent-state}\037#{@agent-unseen}\037#{@agent-notify-token}' 2>/dev/null || true)
        [ "$now" = "$TMUX_PANE${sep}idle${sep}1${sep}$$" ] || exit 0
        send_notification
      ) </dev/null >/dev/null 2>&1 &
    else
      send_notification
    fi
    ;;
esac
