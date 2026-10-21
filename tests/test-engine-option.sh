#!/usr/bin/env bash
# Verify the tmux entrypoint advertises @agent-scripts-dir pointing at the
# directory that holds the state scripts. Runs against a throwaway tmux
# socket so the user's real server is never touched.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/isolate.sh"

PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
SOCK="agent-status-test-$$"

command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }

TMP="$(mktemp -d)"
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

tmux -L "$SOCK" -f /dev/null new-session -d -s t -x 80 -y 24
# run-shell executes with $TMUX pointing at this test server, so the bare
# `tmux` calls inside the entrypoint target the test server, not the default.
tmux -L "$SOCK" run-shell "$PLUGIN_DIR/agent-status.tmux" 2>/dev/null || true

# Under symlinked installs (e.g. a TPM symlink pointing at a dev clone) the
# resolved dir may differ from $PLUGIN_DIR, so assert the contract (option set
# and usable), not path equality.
dir="$(tmux -L "$SOCK" show-option -gqv @agent-scripts-dir 2>/dev/null || true)"

[ -n "$dir" ] || fail "@agent-scripts-dir not set"
[ -x "$dir/set-state.sh" ] || fail "@agent-scripts-dir ($dir) has no executable set-state.sh"
[ "$(tmux -L "$SOCK" show-option -gqv @agent-icon-working)" = '●' ] || fail "working icon is not a circle"
[ "$(tmux -L "$SOCK" show-option -gqv @agent-icon-idle)" = '○' ] || fail "idle icon is not outlined"
[ "$(tmux -L "$SOCK" show-option -gqv @agent-color-working)" = yellow ] || fail "working color is not yellow"
[ "$(tmux -L "$SOCK" show-option -gqv @agent-color-finished)" = cyan ] || fail "done color is not cyan"
# The suggest command is run by UIs through sh with a pane id appended.
cmd="$(tmux -L "$SOCK" show-option -gqv @agent-suggest-command 2>/dev/null || true)"
case "$cmd" in */describe.sh\'\ suggest) ;; *) fail "@agent-suggest-command is not describe.sh suggest: $cmd" ;; esac
rc=0; sh -c "$cmd \"\$1\"" sh not-a-pane 2>/dev/null || rc=$?
[ "$rc" = 2 ] || fail "@agent-suggest-command did not run through sh (status $rc)"
# A reload from a moved checkout points the adapters at it.
cp -R "$PLUGIN_DIR/agent-status.tmux" "$PLUGIN_DIR/scripts" "$TMP/"
tmux -L "$SOCK" run-shell "$TMP/agent-status.tmux" 2>/dev/null || true
moved="$(tmux -L "$SOCK" show-option -gqv @agent-scripts-dir 2>/dev/null || true)"
[ "$moved" = "$(cd "$TMP" && pwd)/scripts/agent" ] || fail "@agent-scripts-dir did not follow a moved checkout: $moved"
echo "PASS: engine advertises @agent-scripts-dir ($dir), @agent-suggest-command and Herdr-style indicators"
