#!/usr/bin/env bash
# rex-title.sh: in a Rex pane (outside tmux), with AGENT_AUTO_TITLE=on, a
# session's first prompt gets pi's title as the pane's label, through
# set-state.sh for Claude Code's hooks and directly for adapters (pi). Once
# per session, never over a label someone gave (the stand-in rex says what
# it would have done), and nothing without AGENT_AUTO_TITLE=on.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/isolate.sh"
PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
AGENT="$PLUGIN_DIR/scripts/agent"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }

mkdir "$TMP/bin"
ln -s "$(command -v jq)" "$TMP/bin/jq"
# rex: each call's arguments (JSON) on a line of its own, and its answer.
cat > "$TMP/bin/rex" <<STUB
#!/bin/sh
args=\$(tr -d '\n'); printf '%s\n' "\$args" >> '$TMP/rex-calls'
case "\$args" in *'"mode": "drop"'*) echo '"dropped"'; exit ;; esac
cat '$TMP/rex-says' 2>/dev/null || echo '"set"'
STUB
cat > "$TMP/bin/pi" <<STUB
#!/bin/sh
cat > '$TMP/pi-in'
cat '$TMP/pi-says'
STUB
chmod +x "$TMP/bin/rex" "$TMP/bin/pi"
echo 'Checkout Totals Bug' > "$TMP/pi-says"
unset TMUX TMUX_PANE
export PATH="$TMP/bin:/usr/bin:/bin" AGENT_PI_FALLBACK_PATH='' REX_SESSION=session:1 REX_BLOCK=block:1 AGENT_AUTO_TITLE=on

calls(){ [ -f "$TMP/rex-calls" ] && wc -l < "$TMP/rex-calls" | tr -d ' ' || echo 0; }
last(){ tail -n 1 "$TMP/rex-calls" | jq -r "$1"; }
until_calls(){ for _ in $(seq 1 60); do [ "$(calls)" = "$1" ] && return 0; sleep 0.1; done; return 1; }
prompt(){ printf '%s\n' "{\"session_id\":\"$1\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"$2\"${3:+,$3}}" | AGENT_STATUS_KIND=claude "$AGENT/set-state.sh" working; }

# A session's first prompt: titled, in the background (the hook doesn't wait
# for a slow pi).
printf '#!/bin/sh\nsleep 2\nexec %s\n' "$TMP/bin/pi-fast" > "$TMP/bin/pi-slow"
mv "$TMP/bin/pi" "$TMP/bin/pi-fast"; mv "$TMP/bin/pi-slow" "$TMP/bin/pi"; chmod +x "$TMP/bin/pi"
t0=$SECONDS
prompt c-1 'the cart total is wrong after a coupon'
[ $((SECONDS - t0)) -le 1 ] || fail "the hook waited for the title"
until_calls 1 || fail "the first prompt was not titled"
mv "$TMP/bin/pi-fast" "$TMP/bin/pi"
[ "$(last .title):$(last .block):$(last .session):$(last .mine)" = "Checkout Totals Bug:block:1:session:1:" ] || fail "wrong label request: $(tail -n 1 "$TMP/rex-calls")"
grep -F 'the cart total is wrong after a coupon' "$TMP/pi-in" >/dev/null || fail "pi was not given the prompt"
# Its later prompts, a subagent's and other hooks' reports: nothing.
prompt c-1 'and the tax'
prompt c-1 'subagent task' '"agent_id":"a1"'
printf '%s\n' '{"session_id":"c-1","hook_event_name":"PreToolUse","tool_name":"Bash"}' | AGENT_STATUS_KIND=claude "$AGENT/set-state.sh" working
printf '%s\n' '{"session_id":"c-1","hook_event_name":"Stop"}' | AGENT_STATUS_KIND=claude "$AGENT/set-state.sh" finished
sleep 0.5
[ "$(calls)" = 1 ] || fail "a later report titled the pane again"

# A new session in the pane: titled over the label set for the last one.
echo 'Tax Rounding' > "$TMP/pi-says"
prompt c-2 'why is the tax rounded down'
until_calls 2 || fail "a new session was not titled"
[ "$(last .title):$(last .mine)" = "Tax Rounding:Checkout Totals Bug" ] || fail "the last label set was not offered for replacing: $(tail -n 1 "$TMP/rex-calls")"
# Someone renamed the pane: rex keeps it, and the next session may replace
# only what was set last.
echo '"kept"' > "$TMP/rex-says"
echo 'Shipping Rates' > "$TMP/pi-says"
prompt c-3 'shipping costs are wrong'
until_calls 3 || fail "a third session was not titled"
rm -f "$TMP/rex-says"
echo 'Fourth Title' > "$TMP/pi-says"
prompt c-4 'something else'
until_calls 4 || fail "a fourth session was not titled"
[ "$(last .mine)" = "Tax Rounding" ] || fail "a kept label was taken as set: $(last .mine)"

# A session with a name (--name, /rename) isn't titled (see below), nor is a
# headless run or a pane without AGENT_AUTO_TITLE=on.
printf '%s\n' '{"session_id":"c-6","hook_event_name":"UserPromptSubmit","prompt":"headless"}' | CLAUDE_CODE_ENTRYPOINT=sdk-cli AGENT_STATUS_KIND=claude "$AGENT/set-state.sh" working
printf '%s\n' '{"session_id":"c-7","hook_event_name":"UserPromptSubmit","prompt":"off"}' | AGENT_AUTO_TITLE= AGENT_STATUS_KIND=claude "$AGENT/set-state.sh" working
sleep 0.5
[ "$(calls)" = 4 ] || fail "a headless or opted-out session was titled"

# The session's end takes the title back; a /clear doesn't (the pane goes on).
end(){ printf '%s\n' "{\"session_id\":\"$1\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"$2\"}" | AGENT_STATUS_KIND=claude "$AGENT/clear-state.sh"; }
end c-4 clear
sleep 0.3
[ "$(calls)" = 4 ] || fail "a /clear took the title back"
end c-4 prompt_input_exit
[ "$(calls)" = 5 ] && [ "$(last .mode):$(last .mine)" = "drop:Fourth Title" ] || fail "the session's end did not take the title back: $(tail -n 1 "$TMP/rex-calls")"
end c-4 other
[ "$(calls)" = 5 ] || fail "a title already taken back was dropped again"
# A session given a name takes the title back, so its name shows.
echo 'Named Title' > "$TMP/pi-says"
prompt c-8 'titled first'
until_calls 6 || fail "c-8 was not titled"
prompt c-8 'then named' '"session_title":"my name"'
[ "$(calls)" = 7 ] && [ "$(last .mode)" = drop ] || fail "a named session kept the title"
prompt c-9 'named from the start' '"session_title":"its name"'
sleep 0.3
[ "$(calls)" = 7 ] || fail "a session named from its start was titled"

# An adapter (pi) passes its session and prompt.
echo 'Pi Title' > "$TMP/pi-says"
"$AGENT/rex-title.sh" prompt pi-1 'a prompt from pi'
until_calls 8 || fail "an adapter's prompt was not titled"
[ "$(last .title)" = "Pi Title" ] || fail "wrong adapter title: $(last .title)"
"$AGENT/rex-title.sh" prompt pi-1 'its second prompt'
sleep 0.5
[ "$(calls)" = 8 ] || fail "an adapter's second prompt titled the pane again"
# Its quit takes the title back.
"$AGENT/rex-title.sh" drop
[ "$(calls)" = 9 ] && [ "$(last .mode):$(last .mine)" = "drop:Pi Title" ] || fail "an adapter's quit did not take the title back"

# Without a title from pi, nothing is asked of rex.
: > "$TMP/pi-says"
"$AGENT/rex-title.sh" prompt pi-2 'no title for this one'
sleep 0.5
[ "$(calls)" = 9 ] || fail "rex was asked to set an empty title"
# Records are private.
[ -z "$(find "$XDG_STATE_HOME/agent-status" -perm -o=r 2>/dev/null)" ] || fail "records readable by others: $(ls -la "$XDG_STATE_HOME/agent-status/rex")"

echo "PASS: rex title"
