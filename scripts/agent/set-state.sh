#!/usr/bin/env bash
# Update the current pane's agent state and optionally notify.
# Usage: set-state.sh <working|asking|finished|idle> [message] [instance] [seq] [kind] [reset]
# `finished` is stored as idle + unseen: an idle completion not yet seen.
# Claude hooks pass the state alone, with their payload on stdin (kind
# $AGENT_STATUS_KIND, else claude); for them it also keeps the first prompt as
# @agent-auto-description and tracks open permission prompts in @agent-asks.
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
    prev_state_at prev_transcript prev_asks described now notify_timeout team_delay pane_active viewers clients \
    socket client log_file log_time name <<< "$(tmux display -t "$TMUX_PANE" -p "#{pane_id}$sep#{pane_dead}$sep#{@agent-state}$sep#{@agent-unseen}$sep#{@agent-instance}$sep#{@agent-seq}$sep#{@agent-kind}$sep#{@agent-state-at}$sep#{@agent-transcript}$sep#{@agent-asks}$sep#{?@agent-auto-description,1,}$sep%s$sep#{@agent-notify-timeout}$sep#{@agent-notify-team-delay}$sep#{pane_active}$sep#{window_active_clients_list}$sep#{L/t:#{?client_control_mode,,#{client_name}=#{client_flags} }}$sep#{socket_path}$sep#{client_name}$sep$AGENT_LOG_FIELDS$sep#S / #W" 2>/dev/null || true)"
  # display -t on a vanished pane silently describes another one.
  [ "$cur_pane" = "$TMUX_PANE" ] && [ "$pane_dead" != 1 ] || exit 0
}

# A report that repeats the pane's state changes nothing, and each Claude tool
# call makes two, often several at once: settle those (working or asking,
# without seq or reset) from one read, before stdin, jq or the lock. Identity
# cannot change then either, since a pane with an instance rejects any other.
# A Claude ask still counts: it records who asks.
if [ "$unseen" = 0 ] && [ -z "$seq$reset" ] && { [ "$state" = working ] || [ "$#" -gt 1 ]; }; then
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
hook_name="" background="" team="" transcript="" src="" agent="" tool="" prompt="" hook_message="" hook_error=""
if [ "$#" -eq 1 ] && [ ! -t 0 ] && command -v jq >/dev/null 2>&1; then
  # background: in-flight subagents/workflows. Background shells and monitors
  # can run indefinitely and never resume the turn by themselves.
  # team: live agent-team teammates. They stay "running" while idle, so they
  # cannot hold a Stop, but each message from one resumes the lead turn.
  # Entry types are friendly labels, or the raw discriminant when unknown.
  # agent, tool: who asks or proceeds (agent_id: empty on the main thread),
  # as option-safe words. prompt: its start, on one line.
  # message, error: for the notification (StopFailure carries only its error
  # type: rate_limit, overloaded, ...), on one line.
  metadata=$(jq -r 'def live(types): (.background_tasks // [])
      | if type == "array" then . else [] end
      | map(select(type == "object" and ((.type // "") | IN(types))
          and ((.status // "running") | IN("running", "pending"))))
      | length | tostring;
    [.session_id // "", .hook_event_name // "",
      live("subagent", "workflow", "local_agent", "local_workflow"),
      live("teammate", "in_process_teammate"),
      (.transcript_path // "" | tostring), (.source // "" | tostring),
      (.agent_id, .tool_name | . // "" | tostring | .[:128] | gsub("[^A-Za-z0-9._:-]"; "_")),
      (.prompt // "" | tostring | sub("^\\s+"; "") | .[:500] | gsub("[\n\r\t]"; " ") | gsub("[\u0000-\u001f\u007f]"; "")),
      (.message // .title // "", .error // "error" | tostring | gsub("[\u0000-\u001f]"; " "))]
    | join("\u001f")' 2>/dev/null || true)
  IFS="$sep" read -r instance hook_name background team transcript src agent tool prompt hook_message hook_error <<< "$metadata"
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
if [ -n "$compact" ] && [ -n "$prev_state" ]; then
  state="$prev_state" unseen="${prev_unseen:-0}" raw_state=compact
fi
case "$prev_seq" in ""|*[!0-9]*) prev_seq="" ;; esac

# Only an explicit session reset may replace a known agent instance. Reports
# without identity remain accepted for backwards-compatible/manual adapters.
if [ -n "$instance" ] && [ -n "$prev_instance" ] && [ "$instance" != "$prev_instance" ] && [ "$reset" != reset ]; then
  exit 0
fi
if [ "$reset" != reset ] && [ -n "$seq" ] && [ -n "$prev_seq" ] && [ "$instance" = "$prev_instance" ] && [ "$seq" -le "$prev_seq" ]; then
  exit 0
fi

# Ordinary idle reports must not acknowledge unseen work; only focus, a reset,
# or resumed active work clears completion attention.
if [ "$raw_state" = idle ]; then
  if [ "$reset" = reset ]; then unseen=0; else unseen="${prev_unseen:-0}"; fi
fi
case "$unseen" in 0|1) ;; *) unseen=0 ;; esac

# Claude permission prompts: tool hooks of parallel tools and subagents keep
# coming while a dialog is open, so an ask holds the pane asking until the
# turn ends or the agent that asked proceeds: its asked tool returns, or it
# starts another. @agent-asks lists the open ones as "<agent_id>/<tool>".
asks="$prev_asks"
if [ -n "$hook_name" ] && [ -z "$compact" ]; then
  case "$raw_state" in
    asking) case " $asks " in *" $agent/$tool "*) ;; *) asks="${asks:+$asks }$agent/$tool" ;; esac ;;
    working)
      asks=""
      for ask in $prev_asks; do
        case "$hook_name:$ask" in
          UserPromptSubmit:*|PreToolUse:"$agent/"*|Stop*:"$agent/"*|PostToolUse*:"$agent/$tool") ;;
          *) asks="${asks:+$asks }$ask" ;;
        esac
      done
      [ -z "$asks" ] || state=asking
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
# Any state change cancels a pending delayed notification (see below), and
# recomputes the window icon.
if [ "$changed" -eq 1 ]; then
  args+=("${w[@]}" @agent-notify-token "$$" \; set-option -wF -t "$TMUX_PANE" @agent-icon "$AGENT_ICON" \;)
fi
# The first prompt describes the pane until a new session. It is free text,
# so it goes last: tmux skips the rest of a chain after a failed command.
if [ "$hook_name" = UserPromptSubmit ] && [ -z "$described" ]; then
  agent_auto_text "$prompt"
  [ -z "$AUTO" ] || args+=("${w[@]}" @agent-auto-description "$AUTO")
elif [ "$hook_name" = SessionStart ] && [ -z "$compact" ] && [ -n "$described" ]; then
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
