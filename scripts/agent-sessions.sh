#!/usr/bin/env bash
# Agent-instance navigator. One card per pane that has registered
# state in $state_dir. Bound to `prefix <key>` by the plugin entrypoint.
set -eu

state_dir=$(tmux show-option -gqv @agent-state-dir 2>/dev/null || true)
: "${state_dir:=${TMUX_TMPDIR:-/tmp}/agent-status-$(id -u)}"
desc_dir=$(tmux show-option -gqv @agent-descriptions-dir 2>/dev/null || true)
: "${desc_dir:=${XDG_DATA_HOME:-$HOME/.local/share}/tmux/agent-status/descriptions}"

STATE_DIR="$state_dir"
DESC_DIR="$desc_dir"

# Glyph rank (precedence: asking > working > finished > idle).
rank_of() {
  case "$1" in
    asking)   echo 4 ;;
    working)  echo 3 ;;
    finished) echo 2 ;;
    idle)     echo 1 ;;
    *)        echo 0 ;;
  esac
}

# Display label + description-file key: the sticky window name (so saved
# descriptions survive `renumber-windows`), else the window index.
# Args <idx> <name> <auto> kept separate so names with spaces/pipes survive.
window_key() {
  if [ "$3" = "0" ]; then
    printf '%s' "$2"
  else
    printf '%s' "$1"
  fi
}

# NUL-terminated, TAB-delimited records: TYPE<TAB>TARGET<TAB>display
# TYPE 'A'=card, 'H'=heading (TARGET=__HEADER__). Headings paint with the
# popup bg so they look inert; the fzf binds below keep the cursor off them.

emit_heading() {
  # bg #2b3339 (popup bg) + dim + bold. Trailing reset.
  printf 'H\t__HEADER__\t\033[48;2;43;51;57;2;1m%s\033[0m\0' "$1"
}

emit_card() {
  local sess="$1" win_key="$2" pane_idx="$3" folder="$4" icon="$5" desc="$6"
  [ -z "$desc" ] && desc='(no description — Ctrl-E to add one)'
  [ -z "$icon" ] && icon=' '
  printf 'A\t%s:%s.%s\t\033[1m%s  %s\033[0m\n    \033[2m%s:%s:%s · %s\033[0m\0' \
    "$sess" "$win_key" "$pane_idx" "$icon" "$desc" "$sess" "$win_key" "$pane_idx" "$folder"
}

# One card per agent pane in $sess, clustered by folder and ordered by
# state precedence within each folder. Emits nothing if the session has no
# agent panes, so build_cards can call it unconditionally.
emit_agent_cards_for_session() {
  local sess="$1"
  # Two-stage so we can track group transitions across iterations (bash 3.2
  # pipes spawn subshells and lose variable state, so we stash the sorted
  # list in a tmpfile and re-read it in the current shell).
  # Sort into a tmpfile, then re-read in this shell: a bash 3.2 pipe runs
  # the while-loop in a subshell, losing the prev_group state we need to
  # detect group transitions. TAB-delimited: names/paths never contain a tab.
  local tmp
  tmp=$(mktemp -t agent-status.XXXXXX)
  while IFS=$'\t' read -r pane_id win_idx win_name auto pane_idx path; do
    local state=""
    if [ -f "$STATE_DIR/$pane_id" ]; then
      read -r state < "$STATE_DIR/$pane_id" || true
    fi
    [ -z "$state" ] && continue
    local rank=$(rank_of "$state")
    [ "$rank" -eq 0 ] && continue
    local folder
    folder=$(basename "$path")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$folder" "$rank" "$pane_id" "$win_idx" "$win_name" "$auto" "$pane_idx" "$path" "$state"
  done < <(tmux list-panes -s -t "$sess" -F $'#{pane_id}\t#{window_index}\t#{window_name}\t#{automatic-rename}\t#{pane_index}\t#{pane_current_path}' 2>/dev/null) \
    | sort -t$'\t' -k1,1 -k2,2nr > "$tmp"

  local prev_group=""
  while IFS=$'\t' read -r folder rank pane_id win_idx win_name auto pane_idx path state; do
    [ -z "$folder" ] && continue
    local win_key icon descfile desc group
    win_key=$(window_key "$win_idx" "$win_name" "$auto")
    icon=$(tmux show-option -gqv "@agent-icon-$state" 2>/dev/null || true)
    descfile="$DESC_DIR/$sess/$win_key/$pane_idx"
    desc=""; [ -f "$descfile" ] && read -r desc < "$descfile" || true
    group="$sess · $folder"
    if [ "$group" != "$prev_group" ]; then
      emit_heading "$(printf '%s' "$group" | tr '[:lower:]' '[:upper:]')"
      prev_group="$group"
    fi
    emit_card "$sess" "$win_key" "$pane_idx" "$folder" "$icon" "$desc"
  done < "$tmp"
  rm -f "$tmp"
}

build_cards() {
  local sess
  while read -r sess; do
    emit_agent_cards_for_session "$sess"
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
}

edit_description() {
  local target="${1:-}"
  # Silent no-op when ctrl-e is hit on a heading row.
  [ "$target" = "__HEADER__" ] && return 0
  [ -n "$target" ] || {
    echo "usage: --edit <sess>:<win-key>.<pane-idx>" >&2
    return 2
  }
  # Split on the LAST dot so window names containing dots survive (see the
  # matching parse in the navigation path below).
  local sess="${target%%:*}"
  local win_key="${target%.*}"; win_key="${win_key#*:}"
  local pane_idx="${target##*.}"
  local dir="$DESC_DIR/$sess/$win_key"
  local file="$dir/$pane_idx"
  local current=""
  [ -f "$file" ] && read -r current < "$file" || true
  # bash 3.2 doesn't support `read -i <default>`. Show the current value
  # in the prompt and treat an empty submission as "keep current".
  local prompt="Description for [$sess:$win_key:$pane_idx]"
  [ -n "$current" ] && prompt="$prompt (current: $current)"
  prompt="$prompt: "
  local new=""
  read -e -p "$prompt" new
  if [ -n "$new" ]; then
    mkdir -p "$dir"
    printf '%s\n' "$new" > "$file"
  fi
}

case "${1:-}" in
  --list)
    build_cards
    exit 0
    ;;
  --edit)
    edit_description "${2:-}"
    exit 0
    ;;
esac

# Main mode: run fzf, then drill into the selected card's pane.
self="$0"

# Keep the cursor off heading rows: --info=hidden drops them from the count,
# --sync + start:down land the initial cursor on a card, the down/up
# transforms re-fire past any heading, --cycle wraps instead of sticking.
sel=$(build_cards | fzf \
  --sync --read0 --ansi --reverse --no-sort --border=rounded --cycle \
  --info=hidden \
  --delimiter='	' --with-nth=3.. \
  --header='enter: switch  •  ctrl-e: edit description  •  ctrl-r: refresh  •  esc: cancel' \
  --color="bg:#2b3339,fg:#d3c6aa,hl:#a7c080,bg+:#374247,fg+:#d3c6aa,hl+:#a7c080,pointer:#a7c080,marker:#7fbbb3,border:#374247,header:#a7c080,gutter:#2b3339,separator:#374247" \
  --prompt='  ' \
  --bind 'start:down' \
  --bind 'down,ctrl-n,ctrl-j:down+transform([ {1} = H ] && echo down)' \
  --bind 'up,ctrl-p,ctrl-k:up+transform([ {1} = H ] && echo up)' \
  --bind 'enter:transform([ {1} = H ] && echo ignore || echo accept)' \
  --bind "ctrl-e:execute(\"$self\" --edit {2})+reload(\"$self\" --list)" \
  --bind "ctrl-r:reload(\"$self\" --list)") || exit 0

[ -z "$sel" ] && exit 0

# TARGET (field 2) = "<sess>:<win-key>.<pane-idx>".
target=$(printf '%s' "$sel" | awk -F'	' '{print $2}')
[ "$target" = "__HEADER__" ] && exit 0   # heading slipped through; ignore
# Split on the LAST dot so window names with dots (e.g. "v0.1.2") stay intact.
sess="${target%%:*}"
win_key="${target%.*}"; win_key="${win_key#*:}"
pane_idx="${target##*.}"

# tmux's target spec accepts either window name OR index for select-window,
# so threading win_key through works for both sticky-name and auto-name
# windows. The selected pane may have died between popup-open and Enter;
# swallow errors so the popup closes cleanly.
tmux switch-client -t "$sess" \; \
     select-window -t "$sess:$win_key" \; \
     select-pane -t "$sess:$win_key.$pane_idx" 2>/dev/null || true
