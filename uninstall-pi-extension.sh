#!/usr/bin/env bash
# Remove the pi status extension symlink -- but only if it is our symlink.
# Never touches an unrelated file that happens to share the name.
set -eu

PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SRC="$PLUGIN_DIR/scripts/pi/agent-status.ts"
EXT_DIR="${PI_EXTENSIONS_DIR:-$HOME/.pi/agent/extensions}"
DEST="$EXT_DIR/agent-status.ts"

if [ -L "$DEST" ] && [ "$(readlink "$DEST")" = "$SRC" ]; then
  rm -f "$DEST"
  echo "agent-status: pi extension unlinked: $DEST"
else
  echo "agent-status: no pi extension symlink of ours at $DEST; nothing removed."
fi
