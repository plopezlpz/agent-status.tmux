#!/usr/bin/env bash
# Wire the plugin's per-state scripts into Claude Code's hooks config, or
# with `uninstall` remove them.
# Usage: install-claude-hooks.sh [install|uninstall]
#
# Idempotent: hook entries pointing at this plugin's scripts (from this
# checkout or any other, under any spelling of its path) are replaced by the
# current ones, kept where they are when unchanged. Safe to re-run after the
# plugin updates (e.g., after a TPM update pulls in new commits). Entries
# that belong to other tools are never touched.
#
# The settings file ($CLAUDE_SETTINGS, else settings.json in
# $CLAUDE_CONFIG_DIR or ~/.claude) is written only when this changes it, and
# the old one is backed up first. manage-provider.sh does the editing, as it
# does for the other agents.
set -eu

ACTION="${1:-install}"
case "$ACTION" in install|uninstall) ;; *) echo "usage: $0 [install|uninstall]" >&2; exit 2 ;; esac

PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
exec bash "$PLUGIN_DIR/manage-provider.sh" "$ACTION" claude
