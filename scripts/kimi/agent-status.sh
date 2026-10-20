#!/usr/bin/env bash
# Kimi hooks installed by older releases run this through a symlink in the
# provider's hooks dir; the installer now points them at
# scripts/agent/hook-event.sh. Re-run `manage-provider.sh install kimi`.
self=$(readlink "$0" 2>/dev/null) || self=$0
exec "${self%/*}/../agent/hook-event.sh" kimi "$@"
