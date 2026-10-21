#!/usr/bin/env bash
# Unit-test the pane-scoped first-prompt description.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/isolate.sh"
PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
SCRIPT="$PLUGIN_DIR/scripts/agent/auto-desc.sh"
SOCK="agent-status-desc-test-$$"
TMP="$(mktemp -d)"
fail(){ echo "FAIL: $1" >&2; exit 1; }
ctl(){ TMUX='' tmux -L "$SOCK" "$@"; }
cleanup(){ ctl kill-server 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }
ctl -f /dev/null new-session -d -s t -x 80 -y 24
TMUX_PANE="$(ctl display -pt t:0.0 '#{pane_id}')"
TMUX="$(ctl display -pt "$TMUX_PANE" '#{socket_path},#{pid},0')"
export TMUX_PANE TMUX
get(){ tmux show-option -p -q -v -t "$TMUX_PANE" @agent-auto-description 2>/dev/null || true; }
unset_desc(){ tmux set-option -p -u -t "$TMUX_PANE" @agent-auto-description 2>/dev/null || true; }

bash "$SCRIPT" set "  fix   the login bug  "
[ "$(get)" = "fix the login bug" ] || fail "not cleaned: [$(get)]"

bash "$SCRIPT" set "a different prompt"
[ "$(get)" = "fix the login bug" ] || fail "second set overwrote first prompt"

unset_desc
bash "$SCRIPT" set "this is a really long first prompt that should be truncated to about fifty chars ok"
out="$(get)"
case "$out" in *…) : ;; *) fail "no ellipsis on long input: $out" ;; esac
[ "${#out}" -le 60 ] || fail "too long: $out"

unset_desc
# Cut by characters, whatever the locale: never half a UTF-8 character.
LC_ALL=C bash "$SCRIPT" set "$(printf 'é%.0s' $(seq 60))"
out="$(get)"
[ "$out" = "$(printf 'é%.0s' $(seq 49))…" ] || fail "multibyte prompt cut by bytes: [$out]"

unset_desc
bash "$SCRIPT" set "$(printf 'first line here\nsecond line')"
[ "$(get)" = "first line here second line" ] || fail "multi-line not collapsed: [$(get)]"

unset_desc
bash "$SCRIPT" set "$(printf '\n\nreal content here')"
[ "$(get)" = "real content here" ] || fail "leading blanks not handled: [$(get)]"

unset_desc
bash "$SCRIPT" set "    "
[ -z "$(get)" ] || fail "empty input wrote an option"

# tmux would read a trailing ";" as a command separator.
unset_desc
bash "$SCRIPT" set ";"
[ "$(get)" = ";" ] || fail "';' prompt not kept: [$(get)]"
unset_desc
bash "$SCRIPT" set 'run it\;'
[ "$(get)" = 'run it\;' ] || fail "trailing '\\;' not kept: [$(get)]"

unset_desc
bash "$SCRIPT" set $'safe\033bad\037end'
[ "$(get)" = safebadend ] || fail "control characters were retained: [$(get)]"
unset_desc
# Concurrent first prompts: the lock lets one write; the others find the
# pane described. A tmux on PATH logs each write.
mkdir "$TMP/bin"
printf '#!/bin/sh\ncase " $* " in *" set-option "*" @agent-auto-description "*) echo "$*" >> "%s/writes" ;; esac\nexec "%s" "$@"\n' "$TMP" "$(command -v tmux)" > "$TMP/bin/tmux"
chmod +x "$TMP/bin/tmux"
pids=""
for i in 1 2 3 4 5 6; do PATH="$TMP/bin:$PATH" bash "$SCRIPT" set "concurrent value $i" & pids="$pids $!"; done
for p in $pids; do wait "$p"; done
[ "$(wc -l < "$TMP/writes" | tr -d ' ')" = 1 ] || fail "concurrent first prompts wrote $(wc -l < "$TMP/writes" | tr -d ' ') times"
case "$(get)" in "concurrent value "[1-6]) ;; *) fail "concurrent first prompts left [$(get)]" ;; esac
unset_desc

echo '{"prompt":"from stdin json"}' | bash "$SCRIPT" set
[ "$(get)" = "from stdin json" ] || fail "stdin .prompt unused: [$(get)]"

bash "$SCRIPT" clear </dev/null
[ -z "$(get)" ] || fail "clear did not unset option"

tmux set-option -p -t "$TMUX_PANE" @agent-auto-description "keep me"
echo '{"source":"compact"}' | bash "$SCRIPT" clear
[ "$(get)" = "keep me" ] || fail "compact clear should keep option"

echo "PASS: auto-desc"
