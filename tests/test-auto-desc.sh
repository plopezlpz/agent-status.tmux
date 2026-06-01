#!/usr/bin/env bash
# Unit-test auto-desc.sh: cleaning, first-prompt-only, trim, stdin source,
# clear, and the compact guard. Uses a sentinel pane in the resolved state dir.
set -euo pipefail
PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
SCRIPT="$PLUGIN_DIR/scripts/agent/auto-desc.sh"
state_dir="$(tmux show-option -gqv @agent-state-dir 2>/dev/null || true)"
: "${state_dir:=${TMUX_TMPDIR:-/tmp}/agent-status-$(id -u)}"
export TMUX_PANE="%autodesctest$$"
file="$state_dir/$TMUX_PANE.desc"
mkdir -p "$state_dir"
trap 'rm -f "$file"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
rm -f "$file"

bash "$SCRIPT" set "  fix   the login bug  "
[ -f "$file" ] || fail "set did not write"
[ "$(cat "$file")" = "fix the login bug" ] || fail "not cleaned: [$(cat "$file")]"

bash "$SCRIPT" set "a different prompt"
[ "$(cat "$file")" = "fix the login bug" ] || fail "second set overwrote (not first-prompt-only)"

rm -f "$file"
bash "$SCRIPT" set "this is a really long first prompt that should be truncated to about fifty chars ok"
out="$(cat "$file")"
case "$out" in *…) : ;; *) fail "no ellipsis on long input: $out" ;; esac
[ "${#out}" -le 60 ] || fail "too long: $out"

rm -f "$file"
bash "$SCRIPT" set "$(printf 'first line here\nsecond line')"
[ "$(cat "$file")" = "first line here" ] || fail "multi-line not first line: [$(cat "$file")]"

rm -f "$file"
bash "$SCRIPT" set "    "
[ -e "$file" ] && fail "empty input wrote a file"

rm -f "$file"
echo '{"prompt":"from stdin json"}' | bash "$SCRIPT" set
[ "$(cat "$file")" = "from stdin json" ] || fail "stdin .prompt unused: [$(cat "$file" 2>/dev/null)]"

bash "$SCRIPT" clear
[ -e "$file" ] && fail "clear did not remove"

echo "keep me" > "$file"
echo '{"source":"compact"}' | bash "$SCRIPT" clear
{ [ -f "$file" ] && [ "$(cat "$file")" = "keep me" ]; } || fail "compact clear should keep the file"

echo "PASS: auto-desc"
