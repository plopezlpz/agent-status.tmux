#!/usr/bin/env bash
# Exercise pane-option state, unseen completion, stale-report guards, and rollup.
set -euo pipefail
PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
SET="$PLUGIN_DIR/scripts/agent/set-state.sh"
CLEAR="$PLUGIN_DIR/scripts/agent/clear-state.sh"
SEEN="$PLUGIN_DIR/scripts/agent/clear-finished.sh"
DESCRIBE="$PLUGIN_DIR/scripts/agent/describe.sh"
SOCK="agent-status-state-test-$$"
TMP="$(mktemp -d)"
fail(){ echo "FAIL: $1" >&2; exit 1; }
ctl(){ TMUX='' tmux -L "$SOCK" "$@"; }
cleanup(){ ctl kill-server 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }
JQ=$(command -v jq 2>/dev/null || true)
ctl -f /dev/null new-session -d -s t -x 80 -y 24
p1="$(ctl display -pt t:0.0 '#{pane_id}')"
p2="$(ctl split-window -d -P -F '#{pane_id}' -t "$p1")"
TMUX="$(ctl display -pt "$p1" '#{socket_path},#{pid},0')"
export TMUX
tmux set-option -g @agent-log "$TMP/agent.log"
tmux set-option -g @agent-descriptions-dir "$TMP/descriptions"
# Description override and generating marker of $p1 (server start + pane id).
DK="$TMP/descriptions/$(tmux display -p "#{start_time}")-${p1#%}"; DM="${DK%/*}/.generating-${DK##*/}"
tmux set-option -g @agent-icon-working W
tmux set-option -g @agent-icon-asking A
tmux set-option -g @agent-icon-finished F
tmux set-option -g @agent-icon-idle I
tmux set-option -g @agent-color-working yellow
tmux set-option -g @agent-color-asking red
tmux set-option -g @agent-color-finished cyan
tmux set-option -g @agent-color-idle green

# Hide desktop notifier binaries while retaining tmux and standard utilities.
mkdir "$TMP/bin"
ln -s "$(command -v tmux)" "$TMP/bin/tmux"
[ -z "$JQ" ] || ln -s "$JQ" "$TMP/bin/jq"
export PATH="$TMP/bin:/usr/bin:/bin"

state(){ TMUX_PANE="$1" "$SET" "${@:2}" </dev/null; }
get(){ tmux show-option -p -q -v -t "$1" "$2" 2>/dev/null || true; }
icon(){ tmux show-option -wqv -t "$p1" @agent-icon 2>/dev/null || true; }
icon_is(){ [ "$(icon)" = "#[push-default]#[fg=$1]$2#[fg=default]#[pop-default]" ]; }

state "$p1" working "" pi-1 10 pi reset
[ "$(get "$p1" @agent-state)" = working ] || fail "working state not stored"
[ "$(get "$p1" @agent-kind)" = pi ] || fail "agent kind not stored"
[ "$(get "$p1" @agent-instance)" = pi:pi-1 ] || fail "instance was not provider-qualified"
state_at=$(get "$p1" @agent-state-at)
case "$state_at" in ''|*[!0-9]*) fail "state timestamp not stored" ;; esac
icon_is yellow W || fail "working rollup missing"

state "$p1" asking "" pi-1 9 pi
[ "$(get "$p1" @agent-state)" = working ] || fail "stale sequence overwrote state"
[ "$(get "$p1" @agent-state-at)" = "$state_at" ] || fail "stale report changed state timestamp"

tmux set-option -p -t "$p1" @agent-state-at 1
state "$p1" finished "" pi-1 11 pi
[ "$(get "$p1" @agent-state)" = idle ] || fail "completion was not stored as idle"
[ "$(get "$p1" @agent-unseen)" = 1 ] || fail "completion was not marked unseen"
finished_at=$(get "$p1" @agent-state-at)
[ "$finished_at" -gt 1 ] || fail "completion did not advance state timestamp"
icon_is cyan F || fail "unseen completion did not use finished icon"
state "$p1" idle "" pi-1 12 pi
[ "$(get "$p1" @agent-unseen)" = 1 ] || fail "plain idle acknowledged unseen completion"
[ "$(get "$p1" @agent-state-at)" = "$finished_at" ] || fail "same-state report changed state timestamp"

"$SEEN" "$p1"
[ "$(get "$p1" @agent-unseen)" = 0 ] || fail "focus acknowledgement did not clear unseen"
[ "$(get "$p1" @agent-state-at)" = "$finished_at" ] || fail "focus acknowledgement reset idle age"
icon_is green I || fail "seen idle icon missing"

state "$p1" asking "" old-instance 12 pi
[ "$(get "$p1" @agent-state)" = idle ] || fail "different untrusted instance overwrote state"
state "$p1" idle "" pi-2 1 pi reset
[ "$(get "$p1" @agent-instance)" = pi:pi-2 ] || fail "reset did not replace instance"
state "$p1" asking "" pi-2 99 omp
[ "$(get "$p1" @agent-state)" = idle ] || fail "cross-provider colliding instance overwrote state"

state "$p2" working "" pi-3 1 pi reset
icon_is yellow W || fail "multi-pane working rollup missing"
state "$p2" asking "" pi-3 2 pi
icon_is red A || fail "asking did not win rollup"
state "$p2" finished "" pi-3 3 pi
icon_is cyan F || fail "finished did not win over seen idle"
TMUX_PANE="$p2" "$CLEAR" quit old-instance </dev/null
[ "$(get "$p2" @agent-instance)" = pi:pi-3 ] || fail "stale shutdown cleared replacement instance"
TMUX_PANE="$p2" "$CLEAR" quit pi-3 pi </dev/null
[ -z "$(get "$p2" @agent-state)" ] || fail "clear left pane state"
[ -z "$(get "$p2" @agent-instance)" ] || fail "clear left pane identity"
[ -z "$(get "$p2" @agent-state-at)" ] || fail "clear left pane timestamp"
icon_is green I || fail "clear did not reaggregate window"

state "$p2" working "" pi-4 1 pi reset
tmux set-option -p -t "$p2" remain-on-exit on
window=$(tmux display -pt "$p2" '#{window_id}')
"$PLUGIN_DIR/scripts/agent/clear-pane.sh" "$p2" "$window"
[ -z "$(get "$p2" @agent-state)" ] || fail "pane-exited cleanup left retained state"
icon_is green I || fail "pane-exited cleanup did not reaggregate window"

# AI description, with a stub pi: success saves a cleaned title, failure
# keeps the old one.
mkdir -p "$TMP/fakepi"
printf '#!/bin/sh\ncat >/dev/null\nprintf "\\n\\"Refactor the VAT rounding\\"\\nextra line\\n"\n' > "$TMP/fakepi/pi"
chmod +x "$TMP/fakepi/pi"
PATH="$TMP/fakepi:$PATH" "$DESCRIBE" run "$p1"
[ "$(cat "$DK")" = 'Refactor the VAT rounding' ] || fail "generated description not saved cleanly"
[ ! -e "$DM" ] || fail "generation left its marker behind"
printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' > "$TMP/fakepi/pi"
PATH="$TMP/fakepi:$PATH" "$DESCRIBE" run "$p1"
[ "$(cat "$DK")" = 'Refactor the VAT rounding' ] || fail "failed generation changed the description"
rm -f "$DM" "$DK"

if [ -n "$JQ" ]; then
  printf '%s\n' '{"session_id":"claude-1","hook_event_name":"SessionStart"}' | \
    TMUX_PANE="$p1" AGENT_STATUS_KIND=claude "$SET" idle
  [ "$(get "$p1" @agent-instance)" = claude:claude-1 ] || fail "Claude SessionStart did not reset/qualify instance"
  [ "$(get "$p1" @agent-kind)" = claude ] || fail "Claude kind not stored"
  printf '%s\n' '{"reason":"resume","session_id":"claude-1"}' | TMUX_PANE="$p1" "$CLEAR"
  [ "$(get "$p1" @agent-state)" = idle ] || fail "Claude resume cleared live pane"
  printf '%s\n' '{"reason":"other","session_id":"old-claude"}' | TMUX_PANE="$p1" "$CLEAR"
  [ "$(get "$p1" @agent-instance)" = claude:claude-1 ] || fail "stale Claude shutdown cleared replacement"

  # A Stop with background agents still running is held as working; only the
  # final Stop (empty background_tasks) completes.
  printf '%s\n' '{"session_id":"claude-1","hook_event_name":"UserPromptSubmit"}' | \
    TMUX_PANE="$p1" AGENT_STATUS_KIND=claude "$SET" working
  printf '%s\n' '{"session_id":"claude-1","hook_event_name":"Stop","background_tasks":[{"id":"a1","type":"subagent","status":"running"}]}' | \
    TMUX_PANE="$p1" AGENT_STATUS_KIND=claude "$SET" finished
  [ "$(get "$p1" @agent-state)" = working ] || fail "Stop with background tasks completed the pane"
  [ "$(get "$p1" @agent-unseen)" = 0 ] || fail "Stop with background tasks raised unseen"
  # Only running/pending subagents and workflows hold: background shells and
  # monitors may run forever, and finished entries no longer resume the turn.
  printf '%s\n' '{"session_id":"claude-1","hook_event_name":"Stop","background_tasks":[{"id":"b1","type":"shell","status":"running"},{"id":"m1","type":"monitor","status":"running"},{"id":"a1","type":"subagent","status":"completed"}]}' | \
    TMUX_PANE="$p1" AGENT_STATUS_KIND=claude "$SET" finished
  [ "$(get "$p1" @agent-state):$(get "$p1" @agent-unseen)" = idle:1 ] || fail "background shell/monitor held the pane working"
  printf '%s\n' '{"session_id":"claude-1","hook_event_name":"UserPromptSubmit"}' | \
    TMUX_PANE="$p1" AGENT_STATUS_KIND=claude "$SET" working
  printf '%s\n' '{"session_id":"claude-1","hook_event_name":"Stop","background_tasks":[{"id":"w1","type":"local_workflow"}]}' | \
    TMUX_PANE="$p1" AGENT_STATUS_KIND=claude "$SET" finished
  [ "$(get "$p1" @agent-state)" = working ] || fail "status-less raw workflow entry did not hold"
  printf '%s\n' '{"session_id":"claude-1","hook_event_name":"Stop","background_tasks":[]}' | \
    TMUX_PANE="$p1" AGENT_STATUS_KIND=claude "$SET" finished
  [ "$(get "$p1" @agent-state):$(get "$p1" @agent-unseen)" = idle:1 ] || fail "final Stop did not complete the pane"

  # Claude's transcript_path is recorded for generated descriptions; non-.jsonl or relative
  # paths are ignored.
  printf '%s\n' '{"session_id":"claude-1","hook_event_name":"UserPromptSubmit","transcript_path":"relative.jsonl"}' | \
    TMUX_PANE="$p1" AGENT_STATUS_KIND=claude "$SET" working
  [ -z "$(get "$p1" @agent-transcript)" ] || fail "relative transcript path accepted"
  printf '{"session_id":"claude-1","hook_event_name":"Stop","transcript_path":"%s"}\n' "$TMP/claude.jsonl" | \
    TMUX_PANE="$p1" AGENT_STATUS_KIND=claude "$SET" finished
  [ "$(get "$p1" @agent-transcript)" = "$TMP/claude.jsonl" ] || fail "Claude transcript path not recorded"

  # Generation sends the latest real prompts (not tool results, meta, sidechain or
  # synthetic messages) and the latest assistant text to pi.
  {
    echo 'partial line cut by tail'
    echo '{"type":"user","message":{"role":"user","content":"first task: look at this"}}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Looking."},{"type":"tool_use","name":"Read"}]}}'
    echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"TOOL OUTPUT"}]}}'
    echo '{"type":"user","isMeta":true,"message":{"role":"user","content":"META PROMPT"}}'
    echo '{"type":"user","isSidechain":true,"message":{"role":"user","content":"SIDECHAIN PROMPT"}}'
    echo '{"type":"user","message":{"role":"user","content":"<task-notification>SYNTHETIC</task-notification>"}}'
    echo '{"type":"user","message":{"role":"user","content":"Another Claude session sent a message: SYNTHETIC"}}'
    echo 'not json at all'
    echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"now fix the VAT rounding"}]}}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Rounding fixed in computeVat."}]}}'
  } > "$TMP/claude.jsonl"
  mkdir -p "$TMP/fakepi"
  printf '#!/bin/sh\ncat > "%s"\necho "Fix VAT rounding"\n' "$TMP/pi-input" > "$TMP/fakepi/pi"; chmod +x "$TMP/fakepi/pi"
  PATH="$TMP/fakepi:$PATH" "$DESCRIBE" run "$p1"
  grep -F 'now fix the VAT rounding' "$TMP/pi-input" >/dev/null || fail "generation did not send the latest prompt"
  grep -F 'Rounding fixed in computeVat.' "$TMP/pi-input" >/dev/null || fail "generation did not send the latest assistant reply"
  if grep -E 'TOOL OUTPUT|META PROMPT|SIDECHAIN|SYNTHETIC' "$TMP/pi-input" >/dev/null; then fail "generation sent non-conversation entries"; fi
  [ "$(cat "$DK")" = 'Fix VAT rounding' ] || fail "transcript-based description not saved"
  rm -f "$DK"
  # pi session files use {"type":"message","message":{"role":...}} entries.
  printf '%s\n' '{"type":"session","version":3,"id":"x"}' \
    '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"pi: tidy the billing tests"}]}}' \
    '{"type":"custom_message","content":"SYNTHETIC"}' \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"THINKING"},{"type":"text","text":"Tests tidied."}]}}' \
    > "$TMP/pi.jsonl"
  ctx=$("$DESCRIBE" context "$TMP/pi.jsonl")
  case "$ctx" in *'pi: tidy the billing tests'*'Tests tidied.'*) ;; *) fail "pi session context not read: $ctx" ;; esac
  case "$ctx" in *THINKING*|*SYNTHETIC*) fail "pi context included thinking or custom entries" ;; esac

  printf '%s\n' '{"reason":"other","session_id":"claude-1"}' | TMUX_PANE="$p1" AGENT_STATUS_KIND=claude "$CLEAR"
  [ -z "$(get "$p1" @agent-transcript)" ] || fail "clear left the transcript path"
  printf '%s\n' '{"session_id":"claude-1","hook_event_name":"SessionStart"}' | \
    TMUX_PANE="$p1" AGENT_STATUS_KIND=claude "$SET" idle

  mkdir "$TMP/badbin"
  ln -s "$(command -v tmux)" "$TMP/badbin/tmux"
  printf '#!/bin/sh\nexit 1\n' > "$TMP/badbin/jq"
  chmod +x "$TMP/badbin/jq"
  printf '%s\n' '{"reason":"other","session_id":"claude-1"}' | \
    PATH="$TMP/badbin:/usr/bin:/bin" TMUX_PANE="$p1" "$CLEAR"
  [ "$(get "$p1" @agent-instance)" = claude:claude-1 ] || fail "unparseable shutdown failed open"
  TMUX_PANE="$p1" "$CLEAR" other "" </dev/null
  [ "$(get "$p1" @agent-instance)" = claude:claude-1 ] || fail "identity-less shutdown failed open"
  printf '%s\n' '{"reason":"other","session_id":"claude-1"}' | AGENT_STATUS_KIND=claude TMUX_PANE="$p1" "$CLEAR"
  [ -z "$(get "$p1" @agent-instance)" ] || fail "qualified Claude shutdown did not clear"
fi

echo "PASS: pane state"
