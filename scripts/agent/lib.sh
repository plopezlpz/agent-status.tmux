# shellcheck shell=bash
# Shared helpers for the per-pane state scripts. Source it; don't execute it.

# Force UTF-8 output. A tmux client that doesn't believe its locale is UTF-8
# (e.g. TMUX unset with no UTF-8 LANG, as from a notification click) prints
# control characters -- our \037 and \t field separators -- and non-ASCII as '_'.
tmux() { command tmux -u "$@"; }

# Pane options owned by a registration; cleared together on exit.
AGENT_PANE_OPTIONS="@agent-state @agent-unseen @agent-instance @agent-seq @agent-kind @agent-state-at @agent-auto-description @agent-description @agent-generating @agent-transcript @agent-notify-token"

# agent_clear_pane PANE: unset the registration's options.
agent_clear_pane() {
  local option
  for option in $AGENT_PANE_OPTIONS; do
    tmux set-option -p -u -t "$1" "$option" 2>/dev/null || true
  done
}

# AGENT_ICON: a window's icon as a tmux format: the worst agent state among
# its panes (asking > working > finished > idle) in that state's
# @agent-icon-* glyph and @agent-color-* colour. Each pane adds
# "<state><unseen> " to the #{P:} list (a finished pane adds "idle1 "). tmux
# evaluates it against the target's window, so recomputing the plain
# @agent-icon value costs one command and no process, and a write can chain
# it after its own with \;:
#   set-option -wF -t PANE_OR_WINDOW @agent-icon "$AGENT_ICON"
# The plugin publishes it as @agent-icon-format for its tmux hooks; scripts
# use this copy, which works before a reload has published a new one.
AGENT_ICON=""
for _s in idle:idle finished:idle1 working:working asking:asking; do
  _g="@agent-icon-${_s%%:*}" _c="@agent-color-${_s%%:*}"
  AGENT_ICON="#{?#{m:*${_s#*:}*,#{P:#{@agent-state}#{@agent-unseen} }},#{?#{&&:#{$_g},#{$_c}},#[push-default]#[fg=#{$_c}]#{$_g}#[fg=default]#[pop-default],#{$_g}},$AGENT_ICON}"
done
unset _s _g _c

# agent_update_window TARGET: recompute the icon of TARGET's window (a pane or
# window id).
agent_update_window() {
  tmux set-option -wF -t "$1" @agent-icon "$AGENT_ICON" 2>/dev/null || true
}

# agent_bump_revision: change the global token UIs watch for any update.
agent_bump_revision() {
  tmux set-option -g @agent-revision "$(date +%s).$$.$RANDOM" 2>/dev/null || true
}

# agent_identity: bound and sanitize $instance and $kind, then scope the
# instance to its provider ("kind:id"): delayed events from another adapter
# must never collide merely because two providers chose the same session ID.
agent_identity() {
  instance="${instance:0:256}" kind="${kind:0:64}"
  case "$instance" in ""|*[!A-Za-z0-9._:-]*) instance="" ;; esac
  case "$kind" in ""|*[!A-Za-z0-9._-]*) kind="" ;; esac
  if [ -n "$instance" ] && [ -n "$kind" ]; then
    case "$instance" in "$kind:"*) ;; *) instance="$kind:$instance" ;; esac
  fi
}

# agent_log MESSAGE: append a timestamped audit line. Never fails: an
# unwritable or full log must not abort a hook before its notification and
# window update.
agent_log() {
  local log_file
  log_file=$(tmux show-option -gqv @agent-log 2>/dev/null || true)
  : "${log_file:=${XDG_DATA_HOME:-$HOME/.local/share}/tmux/agent-status/agent.log}"
  { mkdir -p "${log_file%/*}" && printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$log_file"; } 2>/dev/null || true
}

# agent_lock NAME / agent_unlock: bounded mutual exclusion per tmux server.
# The lock is a file created with noclobber (O_EXCL) holding the owner's PID,
# so taking it costs no fork. A waiter breaks a lock whose owner died without
# unlocking (SIGKILL at a hook timeout) at once, and a lock held by the same
# owner for the whole wait bound (~3s; real critical sections take
# milliseconds) as stale, so a lost unlock can never wedge a pane's hooks.
# (A wedged owner that wakes in the instant of a break could still remove
# the breaker's lock; dead owners, the real case, are broken safely.)
# Signals unlock via the EXIT trap. A process holds at most one lock, so
# ordering cannot deadlock.
#
# Locks live beside the server socket in tmux's per-user 0700 tmux-UID
# directory, which every client of the server agrees on whatever its TMPDIR.
# TMPDIR is the fallback without $TMUX ("socket,server_pid,session") or for a
# custom -S socket outside a tmux-* directory.
AGENT_LOCK=""
agent_lock() {
  local sock="${TMUX:-}" pid root="" owner seen="" tries=0 total=0
  pid="${sock#*,}"; pid="${pid%%,*}"; sock="${sock%%,*}"
  root="${sock%/*}"
  case "${root##*/}" in tmux-*) root="$root/agent-status" ;; *) root="" ;; esac
  if [ -z "$root" ] || ! agent_lock_root "$root"; then
    root="${TMPDIR:-/tmp}"; root="${root%/}/agent-status-${UID:-0}"
    sock="${sock//\//_}"
    # No usable lock directory: proceed unlocked rather than drop the update.
    agent_lock_root "$root" || return 0
  fi
  AGENT_LOCK="$root/${sock##*/}-$pid.$1"
  trap agent_unlock EXIT
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
  until agent_try_lock "$AGENT_LOCK"; do
    # Hard cap (~20s) for a lock file that can never be created.
    total=$((total + 1))
    if [ "$total" -ge 400 ]; then AGENT_LOCK=""; return 0; fi
    owner=""
    { read -r owner < "$AGENT_LOCK"; } 2>/dev/null || true
    # The bound restarts whenever the lock changes hands: a burst of waiters
    # is progress, not staleness.
    [ "$owner" = "$seen" ] || { seen="$owner"; tries=0; }
    if { [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; } || [ "$tries" -ge 60 ]; then
      ! agent_break_lock "$AGENT_LOCK" "$owner" || return 0
    fi
    tries=$((tries + 1))
    sleep 0.05
  done
}
# agent_lock_root DIR: DIR exists (created 0700 if missing) and is ours.
agent_lock_root() {
  [ -d "$1" ] || mkdir -m 700 "$1" 2>/dev/null || true
  [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ]
}
# agent_break_lock LOCK OWNER: take over LOCK if OWNER still holds it. Breakers
# serialize on LOCK.break, re-check the owner, then atomically rename their
# own lock over the stale one, so the lock is never vacant for a third
# process to grab and two waiters cannot both break the same stale owner.
AGENT_EMPTY_BREAKER=0
agent_break_lock() {
  local breaker="$1.break" now="" rc=1
  if ! agent_try_lock "$breaker"; then
    # A breaker killed mid-break must not block later breaks: one with a dead
    # PID is stale, and so is one left empty (killed between create and PID
    # write) for the whole wait bound.
    { read -r now < "$breaker"; } 2>/dev/null || true
    if [ -z "$now" ] && [ -e "$breaker" ]; then
      AGENT_EMPTY_BREAKER=$((AGENT_EMPTY_BREAKER + 1))
      if [ "$AGENT_EMPTY_BREAKER" -ge 60 ]; then agent_clear_stale "$breaker" ""; AGENT_EMPTY_BREAKER=0; fi
    else
      AGENT_EMPTY_BREAKER=0
      if [ -n "$now" ] && ! kill -0 "$now" 2>/dev/null; then agent_clear_stale "$breaker" "$now"; fi
    fi
    return 1
  fi
  { read -r now < "$1"; } 2>/dev/null || true
  if [ "$now" = "$2" ] && [ -e "$1" ]; then
    if { printf '%s\n' "$$" > "$1.new.$$"; } 2>/dev/null && mv -f "$1.new.$$" "$1" 2>/dev/null; then
      rc=0
    else
      rm -f "$1.new.$$" 2>/dev/null || true
    fi
  fi
  rm -f "$breaker" 2>/dev/null || true
  return "$rc"
}
# agent_clear_stale FILE CONTENT: remove FILE only while it still holds
# CONTENT. It is renamed aside first; a fresh file taken by another waiter in
# the meantime is linked back (link fails if FILE was taken yet again).
agent_clear_stale() {
  local moved="$1.dead.$$" now=""
  mv -f "$1" "$moved" 2>/dev/null || return 0
  { read -r now < "$moved"; } 2>/dev/null || true
  [ "$now" = "$2" ] || ln "$moved" "$1" 2>/dev/null || true
  rm -f "$moved" 2>/dev/null || true
}
agent_try_lock() {
  local rc=0
  set -C
  { printf '%s\n' "$$" > "$1"; } 2>/dev/null || rc=1
  set +C
  return "$rc"
}
# Release only a lock we still own; a waiter may have broken it as stale.
agent_unlock() {
  [ -n "$AGENT_LOCK" ] || return 0
  local owner=""
  { read -r owner < "$AGENT_LOCK"; } 2>/dev/null || true
  [ "$owner" != "$$" ] || rm -f "$AGENT_LOCK" 2>/dev/null || true
  AGENT_LOCK=""
  trap - EXIT
}
