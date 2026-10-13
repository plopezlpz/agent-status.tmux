#!/usr/bin/env bash
# Update the current pane's agent state and optionally notify.
# Usage: set-state.sh <working|asking|finished|idle> [message] [instance] [seq] [kind] [reset]
# `finished` is stored as idle + unseen: an idle completion not yet seen.
set -eu

[ -z "${TMUX_PANE:-}" ] && exit 0
[[ "$TMUX_PANE" =~ ^%[0-9]+$ ]] || exit 0
# A headless run (claude -p, the Agent SDK: entrypoint sdk-*) inherits the
# pane from whatever started it; the pane's own agent is someone else.
case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk-*) exit 0 ;; esac

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

# Claude hooks provide identity and event metadata on stdin; their commands
# pass the state alone. Adapters always pass positional arguments and may leave
# stdin open (Node execFile), so never read it for them: `cat` would block.
payload="" hook_name="" background="" team="" transcript="" src="" sep=$'\037'
if [ "$#" -eq 1 ] && [ ! -t 0 ]; then
  payload=$(cat) || true
fi
if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
  # background: in-flight subagents/workflows. Background shells and monitors
  # can run indefinitely and never resume the turn by themselves.
  # team: live agent-team teammates. They stay "running" while idle, so they
  # cannot hold a Stop, but each message from one resumes the lead turn.
  # Entry types are friendly labels, or the raw discriminant when unknown.
  metadata=$(printf '%s' "$payload" | jq -r 'def live(types): (.background_tasks // [])
      | if type == "array" then . else [] end
      | map(select(type == "object" and ((.type // "") | IN(types))
          and ((.status // "running") | IN("running", "pending"))))
      | length | tostring;
    [.session_id // "", .hook_event_name // "",
      live("subagent", "workflow", "local_agent", "local_workflow"),
      live("teammate", "in_process_teammate"),
      (.transcript_path // "" | tostring), (.source // "" | tostring)] | join("\u001f")' 2>/dev/null || true)
  IFS="$sep" read -r instance hook_name background team transcript src <<< "$metadata"
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

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# Keep option values bounded and sequence comparisons inside signed 64-bit.
agent_identity
case "$seq" in ""|*[!0-9]*) seq="" ;; esac
# Transcript (Claude's transcript_path): an absolute .jsonl path, printable only.
case "$transcript" in /*.jsonl) ;; *) transcript="" ;; esac
case "$transcript" in *[[:cntrl:]]*) transcript="" ;; esac
[ "${#transcript}" -le 1024 ] || transcript=""
[ "${#seq}" -le 18 ] || seq=""

agent_lock "pane-${TMUX_PANE#%}"

metadata=$(tmux display -t "$TMUX_PANE" -p $'#{pane_id}\037#{@agent-state}\037#{@agent-unseen}\037#{@agent-instance}\037#{@agent-seq}\037#{@agent-kind}\037#{@agent-state-at}\037#{pane_dead}\037#{@agent-transcript}' 2>/dev/null || true)
IFS="$sep" read -r cur_pane prev_state prev_unseen prev_instance prev_seq prev_kind prev_state_at pane_dead prev_transcript <<< "$metadata"
[ "$cur_pane" = "$TMUX_PANE" ] && [ "$pane_dead" != 1 ] || exit 0
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

changed=0
[ "$state" = "$prev_state" ] && [ "$unseen" = "${prev_unseen:-0}" ] || changed=1

# Set only changed options. Same-state reports normally advance just @agent-seq.
[ "$state" = "$prev_state" ] || tmux set-option -p -t "$TMUX_PANE" @agent-state "$state"
[ "$unseen" = "$prev_unseen" ] || tmux set-option -p -t "$TMUX_PANE" @agent-unseen "$unseen"
case "$prev_state_at" in ''|*[!0-9]*) timestamp_needed=1 ;; *) timestamp_needed=0 ;; esac
if [ "$changed" -eq 1 ] || [ "$reset" = reset ] || [ "$timestamp_needed" -eq 1 ]; then
  tmux set-option -p -t "$TMUX_PANE" @agent-state-at "$(date +%s)"
fi
if [ -n "$instance" ]; then
  [ "$instance" = "$prev_instance" ] || tmux set-option -p -t "$TMUX_PANE" @agent-instance "$instance"
elif [ "$reset" = reset ] && [ -n "$prev_instance" ]; then
  tmux set-option -p -u -t "$TMUX_PANE" @agent-instance 2>/dev/null || true
fi
if [ -n "$seq" ]; then
  [ "$seq" = "$prev_seq" ] || tmux set-option -p -t "$TMUX_PANE" @agent-seq "$seq"
elif [ "$reset" = reset ] && [ -n "$prev_seq" ]; then
  tmux set-option -p -u -t "$TMUX_PANE" @agent-seq 2>/dev/null || true
fi
if [ -n "$kind" ] && [ "$kind" != "$prev_kind" ]; then
  tmux set-option -p -t "$TMUX_PANE" @agent-kind "$kind"
fi
if [ -n "$transcript" ] && [ "$transcript" != "$prev_transcript" ]; then
  tmux set-option -p -t "$TMUX_PANE" @agent-transcript "$transcript"
fi
# Any state change cancels a pending delayed notification (see below).
[ "$changed" -eq 0 ] || tmux set-option -p -t "$TMUX_PANE" @agent-notify-token "$$"

agent_unlock

# Metadata-only reports need no log, notification, aggregation, or redraw.
[ "$changed" -eq 1 ] || exit 0

# Skip the desktop notification for the pane a client is showing with
# terminal focus (focus-events): a completion or permission prompt there is
# already in view. A completion's unseen marker stays: tmux counts a client as
# focused until a focus-out arrives, so a locked screen or a terminal without
# focus reporting would otherwise lose it entirely. Focusing the pane or the
# next prompt (working) clears it.
if [ -n "$notify_state" ]; then
  while IFS="$sep" read -r client_pane client_flags; do
    [ "$client_pane" = "$TMUX_PANE" ] || continue
    case ",$client_flags," in
      *,focused,*) notify_state="" held=" (focused, not notified)"; break ;;
    esac
  done < <(tmux list-clients -F $'#{pane_id}\037#{client_flags}' 2>/dev/null || true)
fi

prev_display="$prev_state"
if [ "$prev_state" = idle ] && [ "$prev_unseen" = 1 ]; then prev_display=finished; fi
agent_log "pane=$TMUX_PANE ${prev_display:-none}->$raw_state$held"

# send_notification: show $title/$message with the first notifier found.
send_notification() {
  if command -v alerter >/dev/null 2>&1; then
    timeout=$(tmux show-option -gqv @agent-notify-timeout 2>/dev/null || true)
    case "$timeout" in ''|*[!0-9]*) timeout=300 ;; esac
    (
      # This subshell inherits set -e: a dismissed/failed alerter must not
      # kill it before the click check.
      result=$(alerter \
        --title "$title" \
        --message "$message" \
        --group "agent-$TMUX_PANE" \
        --timeout "$timeout" \
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
    info=$(tmux display -t "$TMUX_PANE" -p $'#{pane_id}\037#{socket_path}\037#{client_name}\037#S / #W' 2>/dev/null || true)
    IFS="$sep" read -r cur_pane socket client name <<< "$info"
    [ "$cur_pane" = "$TMUX_PANE" ] || exit 0
    title="Agent • $notify_state"
    if [ "$hook_name" = StopFailure ]; then
      # A turn that died on an API error: StopFailure carries only its type
      # (rate_limit, overloaded, ...).
      title="Agent • failed"
      message="$name: $(printf '%s' "$payload" | jq -r '.error // "error" | tostring' 2>/dev/null || true)"
    elif [ -z "$message" ] && [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
      message=$(printf '%s' "$payload" | jq -r '.message // .title // ""' 2>/dev/null || true)
    fi
    [ -n "$message" ] || message="$name"
    message=$(printf '%s' "$message" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' | tr '\n\r\t' '   ' | cut -c1-240)
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
      delay=$(tmux show-option -gqv @agent-notify-team-delay 2>/dev/null || true)
      case "$delay" in ''|*[!0-9]*) delay=10 ;; esac
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

agent_update_window "$TMUX_PANE"
