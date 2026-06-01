#!/usr/bin/env bash
# Verify the tmux entrypoint advertises @agent-scripts-dir pointing at the
# directory that holds the state scripts. Runs against a throwaway tmux
# socket so the user's real server is never touched.
set -euo pipefail

PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
SOCK="agent-status-test-$$"

command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }

cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; }
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

tmux -L "$SOCK" new-session -d -s t -x 80 -y 24
# run-shell executes with $TMUX pointing at this test server, so the bare
# `tmux` calls inside the entrypoint target the test server, not the default.
tmux -L "$SOCK" run-shell "$PLUGIN_DIR/agent-status.tmux" 2>/dev/null || true

# Under symlinked installs (e.g. a TPM symlink pointing at a dev clone) the
# resolved dir may differ from $PLUGIN_DIR, so assert the contract (option set
# and usable), not path equality.
dir="$(tmux -L "$SOCK" show-option -gqv @agent-scripts-dir 2>/dev/null || true)"

[ -n "$dir" ] || fail "@agent-scripts-dir not set"
[ -x "$dir/set-state.sh" ] || fail "@agent-scripts-dir ($dir) has no executable set-state.sh"
echo "PASS: engine advertises @agent-scripts-dir ($dir)"
