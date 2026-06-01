#!/usr/bin/env bash
# Symlink the pi status extension into pi's extensions directory.
#
# Idempotent: re-running refreshes the symlink. Plugin updates (e.g. a TPM
# update pulling new commits) propagate automatically through the link.
set -eu

PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SRC="$PLUGIN_DIR/scripts/pi/agent-status.ts"
EXT_DIR="${PI_EXTENSIONS_DIR:-$HOME/.pi/agent/extensions}"
DEST="$EXT_DIR/agent-status.ts"

[ -f "$SRC" ] || { echo "agent-status: extension not found at $SRC" >&2; exit 1; }

mkdir -p "$EXT_DIR"
ln -sfn "$SRC" "$DEST"

echo "agent-status: pi extension linked: $DEST -> $SRC"
echo "agent-status: restart pi (or run /reload in a session) to activate."
