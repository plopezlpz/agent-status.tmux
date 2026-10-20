#!/usr/bin/env bash
# Run the plugin's lightweight suite. Bash tests always run; TypeScript
# adapter tests run when `bun` is available.
set -u
HERE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
rc=0

# Give every test tmux server a private socket dir: plain `tmux` calls can't
# reach the user's server, and tmux 3.8 leaves socket files behind on exit.
# /tmp keeps socket paths under the macOS 104-byte limit.
TMUX_TMPDIR=$(mktemp -d /tmp/agent-status-tests.XXXXXX) || exit 1
export TMUX_TMPDIR
unset TMUX
# The hooks ignore headless runs (claude -p): the suite may be run from one.
# Nor may an installer test reach a real Claude, Codex, Gemini or Qwen config.
unset CLAUDE_CODE_ENTRYPOINT CLAUDE_CONFIG_DIR CODEX_HOME GEMINI_CLI_HOME QWEN_HOME
# Nor may a test's finished or asking pane send a desktop notification: the
# notifiers found first on PATH do nothing. A test that checks notifications
# puts its own stand-ins in front of these.
mkdir "$TMUX_TMPDIR/quiet" || exit 1
for n in alerter terminal-notifier notify-send; do
  printf '#!/bin/sh\nexit 0\n' > "$TMUX_TMPDIR/quiet/$n"
  chmod +x "$TMUX_TMPDIR/quiet/$n"
done
PATH="$TMUX_TMPDIR/quiet:$PATH"
cleanup() {
  local s
  for s in "$TMUX_TMPDIR"/tmux-*/*; do
    [ -S "$s" ] && tmux -S "$s" kill-server 2>/dev/null
  done
  rm -rf "$TMUX_TMPDIR"
}
trap cleanup EXIT

bash "$HERE/test-engine-option.sh" || rc=1
bash "$HERE/test-installer.sh" || rc=1
bash "$HERE/test-provider-installers.sh" || rc=1
bash "$HERE/test-install-all.sh" || rc=1
bash "$HERE/test-icon-in-status.sh" || rc=1
bash "$HERE/test-auto-desc.sh" || rc=1
bash "$HERE/test-state.sh" || rc=1
bash "$HERE/test-hooks.sh" || rc=1
bash "$HERE/test-describe.sh" || rc=1
bash "$HERE/test-claude-hooks.sh" || rc=1
bash "$HERE/test-codex.sh" || rc=1
bash "$HERE/test-hook-event.sh" || rc=1
if command -v bun >/dev/null 2>&1; then
  bun "$HERE/test-extension.ts" || rc=1
  bun "$HERE/test-providers.ts" || rc=1
else
  echo "SKIP: pi extension test (bun not installed)"
fi

exit "$rc"
