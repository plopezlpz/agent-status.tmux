# shellcheck shell=bash
# Source it first thing in every bash test, and in run.sh: a test run on its
# own gets what the suite gives every test.
# - A private tmux socket dir: plain `tmux` calls can't reach the user's
#   server, and tmux 3.8 leaves socket files behind on exit (removed with it).
# - No headless marker (the hooks ignore headless runs, such as claude -p, and
#   the suite may be run from one), and no real Claude, Codex, Gemini or Qwen
#   config for an installer test to reach.
# - Notifiers that do nothing first on PATH, in $AGENT_STATUS_QUIET: a test's
#   finished or asking pane sends no desktop notification. A test that resets
#   PATH puts that directory first again; one that checks notifications puts
#   its own stand-ins in front of it.
# Outside such a run, the sourcing script runs again inside one, and this
# copy cleans up after it and exits with its status.
unset TMUX CLAUDE_CODE_ENTRYPOINT CLAUDE_CONFIG_DIR CODEX_HOME GEMINI_CLI_HOME QWEN_HOME
if [ -z "${AGENT_STATUS_QUIET:-}" ] || [ ! -d "$AGENT_STATUS_QUIET" ]; then
  # /tmp keeps socket paths under the macOS 104-byte limit.
  TMUX_TMPDIR=$(mktemp -d /tmp/agent-status-tests.XXXXXX) || exit 1
  AGENT_STATUS_QUIET="$TMUX_TMPDIR/quiet"
  export TMUX_TMPDIR AGENT_STATUS_QUIET
  isolate_cleanup() {
    local s
    for s in "$TMUX_TMPDIR"/tmux-*/*; do
      [ ! -S "$s" ] || tmux -S "$s" kill-server 2>/dev/null || true
    done
    rm -rf "$TMUX_TMPDIR"
  }
  trap isolate_cleanup EXIT
  mkdir "$AGENT_STATUS_QUIET" || exit 1
  for _n in alerter terminal-notifier notify-send; do
    printf '#!/bin/sh\nexit 0\n' > "$AGENT_STATUS_QUIET/$_n"
    chmod +x "$AGENT_STATUS_QUIET/$_n"
  done
  PATH="$AGENT_STATUS_QUIET:$PATH"
  _rc=0
  bash "${BASH_SOURCE[1]}" ${1+"$@"} || _rc=$?
  exit "$_rc"
fi
