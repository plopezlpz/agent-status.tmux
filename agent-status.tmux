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
#   - agent descriptions (first prompt, overrides, AI-generated) for a UI:
#     a UI such as paddock reads all of the above from tmux options

set -eu
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRIPTS="$CURRENT_DIR/scripts"
# tmux shim forcing UTF-8 output (keeps \037 field separators intact).
# shellcheck source=scripts/agent/lib.sh
. "$SCRIPTS/agent/lib.sh"

# ----- defaults (-gqo = set only if unset, so user overrides win) ------
tmux set-option -gqo @agent-icon-working  '●'
tmux set-option -gqo @agent-icon-asking   '●'
tmux set-option -gqo @agent-icon-finished '●'
tmux set-option -gqo @agent-icon-idle     '○'
# Upgrade the old built-in Nerd Font glyphs without replacing user overrides.
[ "$(tmux show-option -gqv @agent-icon-working)"  != '󱐋' ] || tmux set-option -g @agent-icon-working  '●'
[ "$(tmux show-option -gqv @agent-icon-asking)"   != '󰘥' ] || tmux set-option -g @agent-icon-asking   '●'
[ "$(tmux show-option -gqv @agent-icon-finished)" != '󰗠' ] || tmux set-option -g @agent-icon-finished '●'
[ "$(tmux show-option -gqv @agent-icon-idle)"     != '󱚣' ] || tmux set-option -g @agent-icon-idle     '○'
tmux set-option -gqo @agent-color-working  'yellow'
tmux set-option -gqo @agent-color-asking   'red'
tmux set-option -gqo @agent-color-finished 'cyan'
tmux set-option -gqo @agent-color-idle     'green'
# Model for generated titles (describe.sh suggest and generate; pi --model
# pattern).
tmux set-option -gqo @agent-describe-model 'openai-codex/gpt-6-luna'
# How a UI asks for a title suggestion: the command, run with a pane id as its
# last argument, prints one. Set on every load: it names this checkout.
printf -v _suggest '%q suggest' "$SCRIPTS/agent/describe.sh"
tmux set-option -g @agent-suggest-command "$_suggest"
# Pane options hold transient state; the audit log lives under XDG_DATA_HOME,
# like tmux-resurrect.
tmux set-option -gqo @agent-log "${XDG_DATA_HOME:-$HOME/.local/share}/tmux/agent-status/agent.log"
# Advertise where the per-pane state scripts live so provider extensions can
# locate shared scripts without a baked path.
tmux set-option -gqo @agent-scripts-dir       "$SCRIPTS/agent"
# Optional: macOS terminal app to activate on notification click (e.g.
# "Ghostty", "iTerm", "Terminal"). Empty = don't activate any app.
tmux set-option -gqo @agent-terminal-app ''
# Seconds an alerter notification waits for a click before auto-closing
# (0 = never). Keep this bounded: each pending notification owns a process.
tmux set-option -gqo @agent-notify-timeout '300'
# Seconds a Claude agent-team lead's completion notification waits while its
# teammates are alive; dropped if the lead resumes. 0 = notify at once.
tmux set-option -gqo @agent-notify-team-delay '10'
tmux set-option -gqo @agent-revision '0'

# ----- prerequisites ---------------------------------------------------
# pane-focus-in only fires when the server has focus-events on -- tmux's
# default is off, so users without it set would see icons stick on
# "finished" forever. Required, set unconditionally.
tmux set-option -g focus-events on

# Timestamp panes created by older releases, then reconcile cached window icons
# once on load. A pane closing mid-loop must not abort the plugin load.
now=$(date +%s)
while IFS=$'\037' read -r pane state state_at; do
  [ -z "$state" ] || [ -n "$state_at" ] || tmux set-option -p -t "$pane" @agent-state-at "$now" 2>/dev/null || true
done < <(tmux list-panes -a -F $'#{pane_id}\037#{@agent-state}\037#{@agent-state-at}' 2>/dev/null)
while read -r window; do
  [ -z "$window" ] || "$SCRIPTS/agent/update-window-icon.sh" "$window" || true
done < <(tmux list-windows -a -F '#{window_id}' 2>/dev/null | sort -u)

# ----- hooks -----------------------------------------------------------
# Hooks whose command contains this needle are "ours".
PLUGIN_NEEDLE='agent-status.tmux/scripts/agent'

# add_hook NAME CMD: append CMD as a global hook, idempotently. If a prior
# plugin entry exists, rebuild the list keeping non-plugin (user) hooks and
# re-add CMD -- so every reload converges to one plugin entry. Matches on
# PLUGIN_NEEDLE, not CMD, since tmux rewrites hook quoting when it stores it.
add_hook() {
  local name="$1" cmd="$2"
  local existing
  existing=$(tmux show-hooks -g "$name" 2>/dev/null || true)

  # Any prior plugin entry present? Rebuild keeping non-plugin entries.
  if [ -n "$existing" ] && printf '%s\n' "$existing" | grep -qF -- "$PLUGIN_NEEDLE"; then
    local survivors line
    survivors=""
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      case "$line" in *"$PLUGIN_NEEDLE"*) continue ;; esac
      # Strip the "<name>[<idx>] " prefix; the remainder is the hook's
      # original command, ready to feed back to set-hook.
      survivors="$survivors${line#"$name"\[*\] }
"
    done <<< "$existing"
    tmux set-hook -gu "$name"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      tmux set-hook -ga "$name" "$line" || echo "agent-status: could not restore $name hook: $line" >&2
    done <<< "$survivors"
  fi

  tmux set-hook -ga "$name" "$cmd"
}

# All hooks use run-shell -b so a slow script never blocks tmux's command queue.
# Mark an unseen idle completion as seen when the pane gets focus.
add_hook pane-focus-in \
  "run-shell -b '$SCRIPTS/agent/clear-finished.sh \"#{pane_id}\"'"

# Clear a closed pane's registration and re-aggregate its window. By
# pane-exited the pane is gone and #{pane_id} names another pane, so use the
# hook_* formats; remain-on-exit panes fire pane-died instead.
add_hook pane-exited \
  "run-shell -b '$SCRIPTS/agent/clear-pane.sh \"#{hook_pane}\" \"#{hook_window}\"'"
add_hook pane-died \
  "run-shell -b '$SCRIPTS/agent/clear-pane.sh \"#{hook_pane}\" \"#{hook_window}\"'"

# Reconcile icons when panes leave or join a window: kill-pane, join-pane/
# move-pane and cross-window swap-pane change both windows' layouts; a window
# made by break-pane only reports pane-moved (skipped where tmux lacks it).
add_hook window-layout-changed \
  "run-shell -b '$SCRIPTS/agent/update-window-icon.sh \"#{hook_window}\" layout'"
add_hook pane-moved \
  "run-shell -b '$SCRIPTS/agent/update-window-icon.sh \"#{hook_window}\" layout'" 2>/dev/null || true
