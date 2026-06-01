#!/usr/bin/env bash
# Run the plugin's test suite. The bash tests always run; the pi extension
# unit test runs only when `bun` is available (it's a TypeScript module).
set -u
HERE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
rc=0

bash "$HERE/test-engine-option.sh" || rc=1
bash "$HERE/test-installer.sh" || rc=1
if command -v bun >/dev/null 2>&1; then
  bun "$HERE/test-extension.ts" || rc=1
else
  echo "SKIP: pi extension test (bun not installed)"
fi

exit "$rc"
