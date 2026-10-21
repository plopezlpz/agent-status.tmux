#!/usr/bin/env bash
# @agent-icon-in-status on puts the window icon in front of both window status
# formats, once, and leaves a format that already shows it alone. Off (the
# default), the formats are untouched. Throwaway tmux sockets only.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/isolate.sh"
PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }
SOCK="agent-status-icon-test-$$"
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; }
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
ICON='#{?@agent-icon,#{@agent-icon} ,}'
t() { tmux -L "$SOCK" "$@"; }
load() { t run-shell "$PLUGIN_DIR/agent-status.tmux" 2>/dev/null || true; }
fmt() { t show-option -gwqv "$1"; }

t -f /dev/null new-session -d -s s -x 80 -y 24
default=$(fmt window-status-format)
load
[ "$(fmt window-status-format)" = "$default" ] || fail "the option is off by default, yet the format changed"

t set-option -g @agent-icon-in-status on
t set-option -gw window-status-format 'A#I:#W'
t set-option -gw window-status-current-format 'B#I:#W'
load
[ "$(fmt window-status-format)" = "${ICON}A#I:#W" ] || fail "window-status-format: $(fmt window-status-format)"
[ "$(fmt window-status-current-format)" = "${ICON}B#I:#W" ] || fail "window-status-current-format: $(fmt window-status-current-format)"
load
[ "$(fmt window-status-format)" = "${ICON}A#I:#W" ] || fail "a reload added the icon twice"

t set-option -gw window-status-format '#I #{@agent-icon} #W'
load
[ "$(fmt window-status-format)" = '#I #{@agent-icon} #W' ] || fail "a format already showing the icon was changed"
# A server that ran a release with the old Nerd Font glyphs gets the new
# default glyphs on reload; a glyph the user chose stays.
t set-option -g @agent-icon-working '󱐋'
t set-option -g @agent-icon-idle 'I'
load
[ "$(t display -p '#{==:#{@agent-icon-working},●}')" = 1 ] || fail "a reload kept the old working glyph"
[ "$(t display -p '#{@agent-icon-idle}')" = I ] || fail "a reload replaced the user's idle glyph"
echo "PASS: @agent-icon-in-status, glyph upgrade"
