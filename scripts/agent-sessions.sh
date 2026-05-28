#!/usr/bin/env bash
# Claude agent-instance navigator. One card per pane that has registered
# state in $state_dir. Bound to `prefix <key>` by the plugin entrypoint.
set -eu

state_dir=$(tmux show-option -gqv @claude-agent-state-dir 2>/dev/null || true)
: "${state_dir:=/tmp/claude-agent-state}"
desc_dir=$(tmux show-option -gqv @claude-agent-descriptions-dir 2>/dev/null || true)
: "${desc_dir:=$HOME/.cache/claude-agent-status/descriptions}"

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

# Window key: the user-renamed window-name when sticky (automatic-rename=0),
# else the window-index. Used as BOTH the display label AND the description
# filesystem key, so descriptions follow user-renamed windows across
# `renumber-windows on` shuffles. Auto-renamed windows are ephemeral by
# nature; falling back to index is acceptable.
# Args: <idx> <name> <auto>  -- passed as separate args so window names
# containing spaces / pipes / any user-typed chars survive intact.
window_key() {
  if [ "$3" = "0" ]; then
    printf '%s' "$2"
  else
    printf '%s' "$1"
  fi
}

# Records use \0-terminated, TAB-delimited columns:
#   TYPE<TAB>TARGET<TAB>display\0
# TYPE='A' (agent card) | 'H' (group heading -- inline, cursor-unreachable).
# TARGET = navigation key for agents, or '__HEADER__' for headings.
# The count is hidden (--info=hidden) so heading rows don't show up in a
# total. Heading rows have explicit bg matching the popup background so
# they look inert even during the brief moment fzf might paint them as
# 'focused' before the down/up transform bindings skip past.

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

# Returns 0 if the session has at least one pane with a state file, 1 otherwise.
session_has_agents() {
  local sess="$1" pane
  while read -r pane; do
    [ -f "$STATE_DIR/$pane" ] && return 0
  done < <(tmux list-panes -s -t "$sess" -F '#{pane_id}' 2>/dev/null)
  return 1
}

# Emit one card per agent pane in $sess. Cards are clustered by folder
# (so panes in the same project stay adjacent) and ordered by state
# precedence within each folder (asking > working > finished > idle).
# Session grouping is implicit -- build_cards calls this once per session.
emit_agent_cards_for_session() {
  local sess="$1"
  # Two-stage so we can track group transitions across iterations (bash 3.2
  # pipes spawn subshells and lose variable state, so we stash the sorted
  # list in a tmpfile and re-read it in the current shell).
  local tmp
  tmp=$(mktemp -t claude-agent-status.XXXXXX)
  # TAB delimiter -- tmux window names can contain any user-typed char
  # including '|' and spaces, but never a literal tab from tmux's own
  # internal renaming. Same applies to pane_current_path on any sane
  # filesystem.
  while IFS=$'\t' read -r pane_id win_idx win_name auto pane_idx path; do
    local state=""
    { read -r state < "$STATE_DIR/$pane_id"; } 2>/dev/null || continue
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
    icon=$(tmux show-option -gqv "@claude-agent-icon-$state" 2>/dev/null || true)
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
    if session_has_agents "$sess"; then
      emit_agent_cards_for_session "$sess"
    fi
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
  local sess="${target%%:*}"
  local rest="${target#*:}"
  local win_key="${rest%%.*}"
  local pane_idx="${rest#*.}"
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

# Headings (TYPE=H) sit inline between groups. Three mechanisms keep them
# out of the way:
#   --info=hidden            suppresses the X/Y count line so headings
#                            don't bump the total visible to the user.
#   --sync + start:down      ensures the initial cursor lands on the
#                            first card, never on the leading heading.
#   down/up + transform      after every cursor move, if we landed on a
#                            heading re-fire the same direction so the
#                            cursor effectively can't rest on one.
#   --cycle                  makes 'up' from the first card wrap to the
#                            bottom rather than getting stuck on the
#                            leading heading.
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
  --bind "ctrl-e:execute($self --edit {2})+reload($self --list)" \
  --bind "ctrl-r:reload($self --list)") || exit 0

[ -z "$sel" ] && exit 0

# Hidden columns: TYPE<TAB>TARGET<TAB>…   TARGET = "<sess>:<win-key>.<pane-idx>"
target=$(printf '%s' "$sel" | awk -F'	' '{print $2}')
# Defensive: if a heading somehow slips through (e.g., cycle wrap + accept),
# don't navigate anywhere.
[ "$target" = "__HEADER__" ] && exit 0
sess="${target%%:*}"
rest="${target#*:}"
win_key="${rest%%.*}"
pane_idx="${rest#*.}"

# tmux's target spec accepts either window name OR index for select-window,
# so threading win_key through works for both sticky-name and auto-name
# windows. The selected pane may have died between popup-open and Enter;
# swallow errors so the popup closes cleanly.
tmux switch-client -t "$sess" \; \
     select-window -t "$sess:$win_key" \; \
     select-pane -t "$sess:$win_key.$pane_idx" 2>/dev/null || true
