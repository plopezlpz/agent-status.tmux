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
# Nor may an installer test reach a real Claude config.
unset CLAUDE_CODE_ENTRYPOINT CLAUDE_CONFIG_DIR
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
if command -v bun >/dev/null 2>&1; then
  bun "$HERE/test-extension.ts" || rc=1
  bun "$HERE/test-providers.ts" || rc=1
else
  echo "SKIP: pi extension test (bun not installed)"
fi

exit "$rc"
