#!/usr/bin/env bash
# Compatibility wrapper; use manage-provider.sh uninstall pi.
set -eu
ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
exec bash "$ROOT/manage-provider.sh" uninstall pi
