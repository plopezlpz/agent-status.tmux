#!/usr/bin/env bash
# Optional Paddock notifications: safe argv, fallback, backend text and stale
# cancellation. Every notifier and tmux server is private to this test.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/isolate.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/agent/lib.sh"
. "$ROOT/scripts/agent/notification-format.sh"
TMP=$(mktemp -d)
TMP=$(cd "$TMP" && pwd -P)
SOCK="agent-notification-test-$$"
cleanup() { command tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
fail() {
  echo "FAIL: $*" >&2
  if [ -f "$TMP/notified/out" ]; then while IFS= read -r line; do printf 'notifier: %s\n' "$line" >&2; done < "$TMP/notified/out"; fi
  if [ -f "$TMP/args" ]; then while IFS= read -r line; do printf 'formatter arg: %s\n' "$line" >&2; done < "$TMP/args"; fi
  exit 1
}
export FORMAT_ARGS="$TMP/args" FORMAT_MODE=ok
cat > "$TMP/formatter with spaces" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$FORMAT_ARGS"
case "$FORMAT_MODE" in
  fail) exit 1 ;;
  partial) printf 'only one line'; exit 0 ;;
  extra) printf 'one\ntwo\nthree'; exit 0 ;;
  slow) sleep 1 ;;
  hang) sleep 30 ;;
  inherited-pipe) sleep 30 & ;;
  excessive) while :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done ;;
esac
case "$2" in asking) state=waiting ;; *) state=$2 ;; esac
printf 'π %s\n%s\n' "$state" 'project/…/topic (topic)'
SH
chmod +x "$TMP/formatter with spaces"
formatter="$TMP/formatter with spaces"
# shellcheck disable=SC2016 # Deliberately literal shell-looking input.
paddock_notification "$formatter" finished pi '-literal; $(not-a-command) <&>' unicode || fail 'formatter failed'
[ "$NOTIFY_TITLE" = 'π finished' ] && [ "$NOTIFY_MESSAGE" = 'project/…/topic (topic)' ] || fail 'two-line output'
# shellcheck disable=SC2016
[ "$(sed -n '4p' "$FORMAT_ARGS")" = '-literal; $(not-a-command) <&>' ] || fail 'path was not one literal argument'
paddock_notification "$formatter" asking pi /tmp nerd || fail 'nerd mode failed'
[ "$NOTIFY_TITLE" = 'π waiting' ] && [ "$(sed -n '5p' "$FORMAT_ARGS")" = nerd ] || fail 'mode/state arguments'
for FORMAT_MODE in fail partial extra hang inherited-pipe excessive; do
  export FORMAT_MODE
  started=$SECONDS
  if paddock_notification "$formatter" finished pi /tmp unicode; then fail "accepted $FORMAT_MODE output"; fi
  [ "$((SECONDS - started))" -lt 5 ] || fail "$FORMAT_MODE exceeded the collection deadline"
done
export FORMAT_MODE=ok
if paddock_notification "$TMP/missing" finished pi /tmp unicode; then fail 'missing formatter accepted'; fi
if PATH=/nonexistent paddock_notification "$formatter" finished pi /tmp unicode; then fail 'ran without watchdog'; fi

# End-to-end state sink with three recording notifier backends.
command -v tmux >/dev/null 2>&1 || { echo 'SKIP: tmux not installed'; exit 0; }
TMUX='' command tmux -L "$SOCK" -f /dev/null new-session -d -s test -c "$TMP"
pane=$(command tmux -L "$SOCK" display -pt test '#{pane_id}')
export TMUX
TMUX=$(command tmux -L "$SOCK" display -pt "$pane" '#{socket_path},#{pid},0')
tmux set-option -g @agent-log "$TMP/log"
tmux set-option -g @agent-notify-paddock "$formatter"
tmux set-option -g @agent-notify-icons nerd
SET="$ROOT/scripts/agent/set-state.sh"
mkdir "$TMP/tools" "$TMP/notified"
ln -s "$(type -P tmux)" "$TMP/tools/tmux"
for tool in jq perl; do
  found=$(command -v "$tool" || true)
  [ -z "$found" ] || ln -s "$found" "$TMP/tools/$tool"
done
cat > "$TMP/recorder" <<'SH'
#!/bin/sh
{ for arg; do printf '[%s]' "$arg"; done; echo; cat; } > "$NOTIFIED/.$$"
mv "$NOTIFIED/.$$" "$NOTIFIED/out"
SH
chmod +x "$TMP/recorder"
export NOTIFIED="$TMP/notified"
event() { TMUX_PANE="$pane" "$SET" "$1" "${2:-}" "notification-test" "" pi </dev/null; }
wait_for_notice() {
  for _ in $(seq 1 60); do [ ! -f "$NOTIFIED/out" ] || return 0; sleep 0.1; done
  fail "notification missing (${backend:-unknown}); state=$(tmux display -pt "$pane" '#{@agent-state}:#{@agent-unseen}:#{@agent-notify-token}'); args=$(tr '\n' '|' < "$FORMAT_ARGS")"
}
for backend in alerter terminal-notifier notify-send; do
  mkdir "$TMP/$backend"
  ln -s "$TMP/recorder" "$TMP/$backend/$backend"
  export PATH="$TMP/$backend:$TMP/tools:/usr/bin:/bin"
  rm -f "$NOTIFIED/out"
  event working
  event finished
  wait_for_notice
  case "$backend" in
    alerter) grep -Fq '[--title][π finished][--message=project/…/topic (topic)]' "$NOTIFIED/out" || fail 'alerter compact format' ;;
    terminal-notifier) grep -Fq '[-title][π finished]' "$NOTIFIED/out" && [ "$(sed 1d "$NOTIFIED/out")" = 'project/…/topic (topic)' ] || fail 'terminal-notifier compact format' ;;
    notify-send) [ "$(cat "$NOTIFIED/out")" = '[--][π finished][project/…/topic (topic)]' ] || fail 'notify-send compact format' ;;
  esac
  [ "$(sed -n '4p' "$FORMAT_ARGS")" = "$TMP" ] || fail 'pane path not passed'
  [ "$(sed -n '5p' "$FORMAT_ARGS")" = nerd ] || fail 'configured icon mode not passed'
done

# Broken optional formatters retain ordinary notification messages.
export FORMAT_MODE=fail
rm -f "$NOTIFIED/out"
event working
event asking '-literal <b>&</b>'
wait_for_notice
[ "$(cat "$NOTIFIED/out")" = '[--][Agent • asking][-literal &lt;b&gt;&amp;&lt;/b&gt;]' ] || fail 'fallback lost legacy/escaped message'

# A new state arriving while formatting cancels the old completion.
export FORMAT_MODE=slow
rm -f "$NOTIFIED/out" "$FORMAT_ARGS"
event working
event finished
for _ in $(seq 1 50); do [ ! -f "$FORMAT_ARGS" ] || break; sleep 0.02; done
[ -f "$FORMAT_ARGS" ] || fail 'slow formatter not started'
event working
sleep 1.3
[ ! -f "$NOTIFIED/out" ] || fail 'stale formatted notification was sent'

# When supplied, test the actual Paddock binary against the same state sink.
if [ -n "${PADDOCK_TEST_BIN:-}" ]; then
  tmux set-option -g @agent-notify-paddock "$PADDOCK_TEST_BIN"
  tmux set-option -g @agent-notify-icons unicode
  expected=$("$PADDOCK_TEST_BIN" notification finished pi "$TMP" unicode)
  rm -f "$NOTIFIED/out"
  event finished
  wait_for_notice
  [ "$(cat "$NOTIFIED/out")" = "[--][${expected%%$'\n'*}][${expected#*$'\n'}]" ] || fail 'real Paddock output differs'
fi
# Hook failures keep their distinct state, without exposing the hook's text.
if command -v jq >/dev/null 2>&1; then
  export FORMAT_MODE=ok
  tmux set-option -g @agent-notify-paddock "$formatter"
  rm -f "$NOTIFIED/out"
  printf '%s\n' '{"session_id":"notify-failure","hook_event_name":"SessionStart"}' | TMUX_PANE="$pane" AGENT_STATUS_KIND=claude "$SET" idle
  printf '%s\n' '{"session_id":"notify-failure","hook_event_name":"StopFailure","error":"private-error-text"}' | TMUX_PANE="$pane" AGENT_STATUS_KIND=claude "$SET" finished
  wait_for_notice
  [ "$(cat "$NOTIFIED/out")" = '[--][π failed][project/…/topic (topic)]' ] || fail 'failure state lost or hook text exposed'
  [ "$(sed -n '2p' "$FORMAT_ARGS")" = failed ] || fail 'failure not passed to formatter'
fi
echo 'ok: optional Paddock notification formatting, fallbacks and cancellation'
