#!/usr/bin/env bash
# Remove this plugin's entries from Claude Code's hooks config (kept for older
# instructions; same as `install-claude-hooks.sh uninstall`).
exec bash "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/install-claude-hooks.sh" uninstall
