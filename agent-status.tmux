#!/usr/bin/env bash
# agent-status.tmux -- TPM entrypoint.
#
# Live agent status for lifecycle-authoritative provider panes in tmux:
#   - per-pane semantic state (working / asking / idle) plus unseen completion
#     driven by agent lifecycle hooks
#   - aggregated worst-state icon set as the @agent-icon
#     window-scoped option (add `#{?@agent-icon,...}` to your
#     window-status-format)
#   - clickable notifications (alerter / terminal-notifier / notify-send)
#   - agent descriptions (first prompt, overrides, AI-suggested) for a UI:
#     a UI such as paddock reads all of the above from tmux options

set -eu
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRIPTS="$CURRENT_DIR/scripts"
# tmux shim forcing UTF-8 output (keeps \037 field separators intact).
# shellcheck source=scripts/agent/lib.sh
. "$SCRIPTS/agent/lib.sh"

# The hooks need tmux 3.8 (pane-moved, #{hook_window} on pane-exited). Ask
# the server for the hook rather than parse version strings (3.8a, next-3.9).
if ! tmux show-hooks -g pane-moved >/dev/null 2>&1; then
  tmux display-message "agent-status: needs tmux 3.8 or later (this server is $(tmux display -p '#{version}'))"
  exit 0
fi

# ----- options, set in one tmux call -----------------------------------
printf -v _suggest '%q suggest' "$SCRIPTS/agent/describe.sh"
_options=(
  # Defaults: -o sets only if unset, so user overrides win.
  set-option -gqo @agent-icon-working  '●' \;
  set-option -gqo @agent-icon-asking   '●' \;
  set-option -gqo @agent-icon-finished '●' \;
  set-option -gqo @agent-icon-idle     '○' \;
  # Upgrade the old built-in Nerd Font glyphs without replacing user overrides.
  if -F '#{==:#{@agent-icon-working},󱐋}'  'set-option -g @agent-icon-working ●' \;
  if -F '#{==:#{@agent-icon-asking},󰘥}'   'set-option -g @agent-icon-asking ●' \;
  if -F '#{==:#{@agent-icon-finished},󰗠}' 'set-option -g @agent-icon-finished ●' \;
  if -F '#{==:#{@agent-icon-idle},󱚣}'     'set-option -g @agent-icon-idle ○' \;
  set-option -gqo @agent-color-working  'yellow' \;
  set-option -gqo @agent-color-asking   'red' \;
  set-option -gqo @agent-color-finished 'cyan' \;
  set-option -gqo @agent-color-idle     'green' \;
  # Model for suggested titles (describe.sh suggest; pi --model pattern).
  set-option -gqo @agent-describe-model 'openai-codex/gpt-6-luna' \;
  # Pane options hold transient state; the audit log lives under
  # XDG_DATA_HOME, like tmux-resurrect.
  set-option -gqo @agent-log "${XDG_DATA_HOME:-$HOME/.local/share}/tmux/agent-status/agent.log" \;
  # Optional: macOS terminal app to activate on notification click (e.g.
  # "Ghostty", "iTerm", "Terminal"). Empty = don't activate any app.
  set-option -gqo @agent-terminal-app '' \;
  # Seconds an alerter notification waits for a click before auto-closing
  # (0 = never). Keep this bounded: each pending notification owns a process.
  set-option -gqo @agent-notify-timeout '300' \;
  # Seconds a Claude agent-team lead's completion notification waits while
  # its teammates are alive; dropped if the lead resumes. 0 = notify at once.
  set-option -gqo @agent-notify-team-delay '10' \;
  # Set on every load, since they name this checkout and this version: how a
  # UI asks for a title suggestion (the command, run with a pane id as its
  # last argument, prints one); where other tools can find the shared
  # scripts; and the window icon format the hooks below evaluate (lib.sh).
  set-option -g @agent-suggest-command "$_suggest" \;
  set-option -g @agent-scripts-dir "$SCRIPTS/agent" \;
  set-option -g @agent-icon-format "$AGENT_ICON" \;
  # pane-focus-in only fires when the server has focus-events on -- tmux's
  # default is off, so users without it set would see icons stick on
  # "finished" forever. Required, set unconditionally.
  set-option -g focus-events on
)
tmux "${_options[@]}"

# Recompute every window's icon, since the glyphs, colours or format may have
# changed: one tmux call per 150 windows (tmux caps a command at 16 KB).
_icons=()
while read -r _window; do
  _icons+=(set-option -wF -t "$_window" @agent-icon '#{E:@agent-icon-format}' \;)
  [ "${#_icons[@]}" -lt 1050 ] || { tmux "${_icons[@]}" 2>/dev/null || true; _icons=(); }
done < <(tmux list-windows -a -F '#{window_id}' 2>/dev/null)
[ "${#_icons[@]}" -eq 0 ] || tmux "${_icons[@]}" 2>/dev/null || true

# ----- hooks -----------------------------------------------------------
# add_hook NAME CMD: append CMD as a global hook, idempotently. Plugin entries
# from any load -- this checkout or an earlier one, whatever its directory is
# called -- are dropped and user hooks kept, so every reload converges to one
# plugin entry. Plugin entries are the ones that run a script any release
# hooked up, or evaluate @agent-icon-format; matching on CMD would not do,
# since tmux rewrites hook quoting when it stores it.
add_hook() {
  local name="$1" line survivors="" ours=""
  while IFS= read -r line; do
    case "$line" in
      "") ;;
      */scripts/agent/clear-finished.sh*|*/scripts/agent/clear-pane.sh*|\
      */scripts/agent/update-window-icon.sh*|*/scripts/agent/on-pane-exit.sh*|\
      *@agent-icon-format*) ours=1 ;;
      # Strip the "<name>[<idx>] " prefix; the remainder is the hook's
      # original command, ready to feed back to set-hook.
      *) survivors="$survivors${line#"$name"\[*\] }
" ;;
    esac
  done < <(tmux show-hooks -g "$name" 2>/dev/null || true)
  if [ -n "$ours" ]; then
    tmux set-hook -gu "$name"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      tmux set-hook -ga "$name" "$line" || echo "agent-status: could not restore $name hook: $line" >&2
    done <<< "$survivors"
  fi
  tmux set-hook -ga "$name" "$2"
}

# Opt-in: with @agent-icon-in-status on, put the window icon in front of both
# window status formats, so a config needs no format edits. A format that
# already shows @agent-icon is left alone, so a reload never adds it twice. Set
# your own formats before this plugin loads.
if [ "$(tmux show-option -gqv @agent-icon-in-status)" = on ]; then
  for _fmt in window-status-format window-status-current-format; do
    _cur=$(tmux show-option -gwqv "$_fmt")
    case "$_cur" in
      *@agent-icon*) ;;
      *) tmux set-option -gw "$_fmt" "#{?@agent-icon,#{@agent-icon} ,}$_cur" ;;
    esac
  done
fi

# Routine events start no process: tmux tests and recomputes what it can
# itself. Scripts run with run-shell -b, so a slow one never blocks tmux's
# command queue.
# background CMD: BG, `run-shell -b CMD` as tmux parses it. tmux unquotes the
# string, then run-shell expands formats and hands the result to sh; _agent
# is the scripts dir quoted for both, so any path works.
printf -v _agent '%q' "$SCRIPTS/agent"; _agent=${_agent//#/##}
background() {
  local s=${1//\\/\\\\}; s=${s//\"/\\\"}; s=${s//\$/\\\$}
  BG="run-shell -b \"$s\""
}
# Mark an unseen idle completion as seen when the pane gets focus.
background "$_agent/clear-finished.sh #{pane_id}"
add_hook pane-focus-in "if -F '#{&&:#{==:#{@agent-state},idle},#{==:#{@agent-unseen},1}}' { $BG }"

# Recompute the window icon when panes leave or join a window: kill-pane,
# join-pane/move-pane and cross-window swap-pane change both windows'
# layouts; a window made by break-pane only reports pane-moved; an exited
# pane's options are gone with it. A hook command runs in the hook's window
# only while the pane that fired it exists, so name #{hook_window}: -t does not
# expand formats, run-shell -C does (## leaves the icon format to set-option).
# The window may be gone (-q). An unchanged icon is not written, since every
# write redraws every client.
_icon="run-shell -C \"if -F -t '#{hook_window}' '##{!=:##{@agent-icon},##{E:@agent-icon-format}}' { set-option -wqF -t '#{hook_window}' @agent-icon '##{E:@agent-icon-format}' }\""
add_hook pane-exited "$_icon"
add_hook window-layout-changed "$_icon"
add_hook pane-moved "$_icon"
# A remain-on-exit pane fires pane-died instead and keeps its options: clear
# them. By then #{pane_id} may name another pane, so use the hook_* formats.
background "$_agent/clear-pane.sh #{hook_pane} #{hook_window}"
add_hook pane-died "$BG"
