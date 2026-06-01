#!/usr/bin/env bash
# Install/uninstall the pi extension into a throwaway extensions dir and assert
# symlink creation, idempotency, and that uninstall never clobbers a file that
# isn't our symlink.
set -euo pipefail

PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
EXT_SRC="$PLUGIN_DIR/scripts/pi/agent-status.ts"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export PI_EXTENSIONS_DIR="$TMP/extensions"
LINK="$PI_EXTENSIONS_DIR/agent-status.ts"

fail() { echo "FAIL: $1" >&2; exit 1; }

# install creates a symlink to the shipped extension
bash "$PLUGIN_DIR/install-pi-extension.sh" >/dev/null
[ -L "$LINK" ] || fail "symlink not created"
[ "$(readlink "$LINK")" = "$EXT_SRC" ] || fail "wrong target: $(readlink "$LINK")"

# install is idempotent
bash "$PLUGIN_DIR/install-pi-extension.sh" >/dev/null
[ -L "$LINK" ] || fail "symlink missing after re-install"
[ "$(readlink "$LINK")" = "$EXT_SRC" ] || fail "target changed after re-install"

# uninstall removes our symlink
bash "$PLUGIN_DIR/uninstall-pi-extension.sh" >/dev/null
[ -e "$LINK" ] && fail "symlink not removed by uninstall"

# uninstall must NOT touch an unrelated, same-named regular file
echo "not ours" > "$LINK"
bash "$PLUGIN_DIR/uninstall-pi-extension.sh" >/dev/null
[ -f "$LINK" ] || fail "uninstall removed an unrelated file"
[ "$(cat "$LINK")" = "not ours" ] || fail "uninstall modified an unrelated file"

echo "PASS: pi installer"
