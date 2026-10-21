#!/usr/bin/env bash
# Run the plugin's lightweight suite. Bash tests always run; TypeScript
# adapter tests run when `bun` is available.
set -u
HERE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# One isolated environment for the whole suite, the TypeScript tests
# included (see isolate.sh); each bash test sources it too, to run alone.
. "$HERE/isolate.sh"
rc=0

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
