#!/usr/bin/env bash
# Agent navigator: one event-backed card per registered tmux pane.
set -eu

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SEP=$'\037'
TAB=$'\t'
# fzf waits ESCDELAY ms (default 100) after Esc for an escape sequence. tmux
# hands the popup whole sequences already, so a short wait makes Esc close fast.
export ESCDELAY="${ESCDELAY:-10}"

# One tmux lookup per popup. Reloaded list processes inherit this cache and only
# need the single list-panes snapshot below.
if [ "${AGENT_NAV_THEME_LOADED:-}" != 1 ]; then
  theme=$(tmux display-message -p $'#{@agent-descriptions-dir}\037#{@agent-icon-working}\037#{@agent-icon-asking}\037#{@agent-icon-finished}\037#{@agent-icon-idle}\037#{@agent-color-working}\037#{@agent-color-asking}\037#{@agent-color-finished}\037#{@agent-color-idle}\037#{start_time}' 2>/dev/null || true)
  IFS="$SEP" read -r DESC_DIR ICON_WORKING ICON_ASKING ICON_FINISHED ICON_IDLE COLOR_WORKING COLOR_ASKING COLOR_FINISHED COLOR_IDLE SERVER_START <<< "$theme"
  : "${DESC_DIR:=${XDG_DATA_HOME:-$HOME/.local/share}/tmux/agent-status/descriptions}"
  export AGENT_NAV_THEME_LOADED=1 DESC_DIR ICON_WORKING ICON_ASKING ICON_FINISHED ICON_IDLE
  export COLOR_WORKING COLOR_ASKING COLOR_FINISHED COLOR_IDLE SERVER_START
fi
: "${DESC_DIR:=${XDG_DATA_HOME:-$HOME/.local/share}/tmux/agent-status/descriptions}"
# Descriptions are keyed by server start time and pane id: pane ids restart at
# %0 with the server, so a bare id would hand an old title to a new pane.
case "${SERVER_START:-}" in ''|*[!0-9]*) SERVER_START=0 ;; esac
: "${ICON_WORKING:=●}" "${ICON_ASKING:=●}" "${ICON_FINISHED:=●}" "${ICON_IDLE:=○}"
: "${COLOR_WORKING:=yellow}" "${COLOR_ASKING:=red}" "${COLOR_FINISHED:=cyan}" "${COLOR_IDLE:=green}"
export AGENT_NAV_THEME_LOADED=1 DESC_DIR ICON_WORKING ICON_ASKING ICON_FINISHED ICON_IDLE
export COLOR_WORKING COLOR_ASKING COLOR_FINISHED COLOR_IDLE SERVER_START

# desc_paths PANE: DESC_FILE (Ctrl-E/Ctrl-G override) and GEN_FILE (the
# "generating…" marker). clear-pane.sh removes the same two paths on exit.
desc_paths() {
  DESC_FILE="$DESC_DIR/$SERVER_START-${1#%}"
  GEN_FILE="$DESC_DIR/.generating-$SERVER_START-${1#%}"
}

# pane_alive PANE: display -p succeeds even for a vanished pane, so compare ids.
pane_alive() {
  [ "$(tmux display -p -t "$1" '#{pane_id}' 2>/dev/null)" = "$1" ]
}

shown_state() {
  if [ "$1" = idle ] && [ "${2:-0}" = 1 ]; then SHOWN=finished; else SHOWN="$1"; fi
}

rank_of() {
  case "$1" in
    asking) RANK=4 ;;
    working) RANK=3 ;;
    finished) RANK=2 ;;
    idle) RANK=1 ;;
    *) RANK=0 ;;
  esac
}

# sgr_of COLOR: tmux colour name or #rrggbb -> SGR foreground parameters.
sgr_of() {
  case "$1" in
    red) SGR=31 ;; green) SGR=32 ;; yellow) SGR=33 ;;
    blue) SGR=34 ;; magenta) SGR=35 ;; cyan) SGR=36 ;; white) SGR=37 ;;
    \#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
      SGR="38;2;$((16#${1:1:2}));$((16#${1:3:2}));$((16#${1:5:2}))" ;;
    *) SGR="" ;;
  esac
}

# icon_of STATE: sets ICON (coloured glyph), LABEL (word) and STATE_SGR.
icon_of() {
  local icon color
  case "$1" in
    asking) icon="$ICON_ASKING"; color="$COLOR_ASKING"; LABEL=waiting ;;
    working) icon="$ICON_WORKING"; color="$COLOR_WORKING"; LABEL=working ;;
    finished) icon="$ICON_FINISHED"; color="$COLOR_FINISHED"; LABEL=finished ;;
    idle) icon="$ICON_IDLE"; color="$COLOR_IDLE"; LABEL=idle ;;
  esac
  sgr_of "$color"; STATE_SGR="$SGR"
  if [ -n "$SGR" ]; then printf -v ICON '\033[%sm%s\033[0m' "$SGR" "$icon"; else ICON="$icon"; fi
}

window_key() {
  if [ "$3" = 0 ]; then WIN_KEY="$2"; else WIN_KEY="$1"; fi
}

clean_text() {
  local text="$1" controls char
  text=${text//$'\n'/ }; text=${text//$'\r'/ }; text=${text//$'\t'/ }
  controls=$'\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177'
  while [ -n "$controls" ]; do
    char=${controls%"${controls#?}"}; controls=${controls#?}; text=${text//"$char"/}
  done
  utf8_cut 240 "$text"; CLEAN="$CUT"
}

# utf8_cut N TEXT: the first N characters of TEXT (not bytes, so a multibyte
# character is never split), even when the caller's locale is not UTF-8.
utf8_cut() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
    *) local LC_ALL=C.UTF-8 2>/dev/null ;;
  esac
  CUT=${2:0:$1}
}

# state_age EPOCH NOW: compact time since the last state change.
state_age() {
  local at="$1" now="$2" age minutes
  case "$at" in ''|*[!0-9]*) AGE='<1m'; return ;; esac
  age=$((now - at)); [ "$age" -ge 0 ] || age=0
  minutes=$((age / 60))
  if [ "$minutes" -lt 1 ]; then AGE='<1m'
  elif [ "$minutes" -lt 60 ]; then AGE="${minutes}m"
  elif [ "$minutes" -lt 1440 ]; then AGE="$((minutes / 60))h"
  else AGE="$((minutes / 1440))d"
  fi
}

# Two-line card:  <icon>  description
#                    <state age, state-coloured>  ·  session › folder · kind · win:pane
emit_card() {
  local pane="$1" desc_target="$2" sess="$3" folder="$4" win_key="$5" pane_idx="$6" kind="$7" age="$8"
  local title status location
  if [ -n "$9" ]; then
    clean_text "$9"; printf -v title '\033[1m%s\033[0m' "$CLEAN"
  else
    title=$'\033[2;3mno description · ctrl-e to add one\033[0m'
  fi
  [ -z "${GENERATING:-}" ] || title="$title"$'  \033[38;2;158;149;199m✦ generating…\033[0m'
  status="$LABEL $age"
  [ -z "$STATE_SGR" ] || printf -v status '\033[%sm%s\033[0m' "$STATE_SGR" "$status"
  location="$sess › $folder"
  [ -z "$kind" ] || location="$location · $kind"
  location="$location · $win_key:$pane_idx"
  clean_text "$location"; location="$CLEAN"
  printf 'A\t%s\t%s\t%s  %s\n   %s\033[2m  ·  %s\033[0m\0' \
    "$pane" "$desc_target" "${ICON:- }" "$title" "$status" "$location"
}

build_cards() {
  local now
  now=$(date +%s)
  while IFS="$SEP" read -r sess folder rank pane win_idx win_name auto pane_idx shown kind auto_desc state_at; do
    [ -n "$pane" ] || continue
    local win_key desc_target desc
    window_key "$win_idx" "$win_name" "$auto"; win_key="$WIN_KEY"
    desc_target="$pane"
    desc_paths "$pane"
    desc=""
    [ ! -f "$DESC_FILE" ] || read -r desc < "$DESC_FILE" || true
    [ -n "$desc" ] || desc="$auto_desc"
    GENERATING=""; [ ! -e "$GEN_FILE" ] || GENERATING=1
    icon_of "$shown"
    state_age "$state_at" "$now"
    emit_card "$pane" "$desc_target" "$sess" "$folder" "$win_key" "$pane_idx" "$kind" "$AGE" "$desc"
  done < <(
    # One tmux snapshot for every session and pane. Transient state and the
    # first-prompt label live in pane options; only Ctrl-E overrides use files.
    while IFS="$SEP" read -r sess win_idx win_name auto pane pane_idx path state unseen kind auto_desc state_at; do
      [ -n "$state" ] || continue
      local shown rank folder
      shown_state "$state" "$unseen"; shown="$SHOWN"
      rank_of "$shown"; rank="$RANK"
      [ "$rank" -gt 0 ] || continue
      folder=${path##*/}; [ -n "$folder" ] || folder=${path:-?}  # "/" or unknown
      printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' \
        "$sess" "$folder" "$rank" "$pane" "$win_idx" "$win_name" "$auto" "$pane_idx" "$shown" "$kind" "$auto_desc" "$state_at"
    done < <(tmux list-panes -a -F $'#{session_name}\037#{window_index}\037#{window_name}\037#{automatic-rename}\037#{pane_id}\037#{pane_index}\037#{pane_current_path}\037#{@agent-state}\037#{@agent-unseen}\037#{@agent-kind}\037#{@agent-auto-description}\037#{@agent-state-at}' 2>/dev/null) \
      | sort -t"$SEP" -k1,1 -k2,2 -k3,3nr
  )
}

# save_description PANE TEXT: store a Ctrl-E override (empty TEXT clears it,
# falling back to the automatic first-prompt description).
save_description() {
  local target="$1"
  [[ "$target" =~ ^%[0-9]+$ ]] || return 2
  pane_alive "$target" || return 0  # no orphan files for a vanished pane
  desc_paths "$target"
  clean_text "$2"
  if [ -n "$CLEAN" ]; then
    mkdir -p "$DESC_DIR"; printf '%s\n' "$CLEAN" > "$DESC_FILE"
  else
    rm -f "$DESC_FILE"
  fi
  tmux set-option -g @agent-revision "$(date +%s).$$.$RANDOM" 2>/dev/null || true
}

# Standalone editor, kept for scripting; the navigator uses describe_dialog.
edit_description() {
  local target="${1:-}"
  [[ "$target" =~ ^%[0-9]+$ ]] || { echo "usage: --edit <pane-id>" >&2; return 2; }
  local current="" new=""
  desc_paths "$target"
  [ ! -f "$DESC_FILE" ] || read -r current < "$DESC_FILE" || true
  clean_text "$current"; current="$CLEAN"
  local prompt="Description for [$target]"
  [ -z "$current" ] || prompt="$prompt (current: $current)"
  read -e -r -p "$prompt: " new
  [ -z "$new" ] || save_description "$target" "$new"
}

# ----- description dialog -------------------------------------------------
# Ctrl-E opens a small framed dialog centred over the navigator: which agent
# it is, where, its state, and one text field. Enter saves, Esc cancels.
key_hint() { printf '\033[38;2;150;166;200m%s\033[0m \033[2m%s\033[0m   ' "$1" "$2"; }
nav_footer() {
  local f
  f="$(key_hint '⏎' jump)$(key_hint '^e' describe)$(key_hint '^g' generate)$(key_hint '^r' refresh)$(key_hint '^/' preview)$(key_hint esc close)"
  printf '%s' "${f%   }"
}
NAV_GHOST='filter by task, project, agent or state'

describe_dialog() {
  local target="$1" current="" override info id auto kind loc path state unseen state_at header footer
  local rows=0 cols=0 w=68 h=10 top side out rc=0 query
  [[ "$target" =~ ^%[0-9]+$ ]] || return 0
  desc_paths "$target"
  [ ! -f "$DESC_FILE" ] || read -r current < "$DESC_FILE" || true
  info=$(tmux display -p -t "$target" $'#{pane_id}\037#{@agent-auto-description}\037#{@agent-kind}\037#{session_name}:#{window_index}.#{pane_index}\037#{pane_current_path}\037#{@agent-state}\037#{@agent-unseen}\037#{@agent-state-at}' 2>/dev/null) || return 0
  IFS="$SEP" read -r id auto kind loc path state unseen state_at <<< "$info"
  [ "$id" = "$target" ] || return 0  # display -p succeeds for a vanished pane
  override="$current"
  [ -n "$current" ] || current="$auto"
  clean_text "$current"; current="$CLEAN"
  case "$path" in "$HOME") path='~' ;; "$HOME"/*) path="~${path#"$HOME"}" ;; esac
  clean_text "${kind:-agent}  ·  $loc  ·  $path"; header="$CLEAN"
  shown_state "${state:-idle}" "$unseen"; icon_of "$SHOWN"; state_age "$state_at" "$(date +%s)"
  local status="$LABEL $AGE"
  [ -z "$STATE_SGR" ] || printf -v status '\033[%sm%s\033[0m' "$STATE_SGR" "$status"
  # Trailing ' ' line: breathing room between the details and the field.
  header=$'\033[1m'"$header"$'\033[0m\n'"$ICON $status"$'\n '
  footer="$(key_hint '⏎' save)$(key_hint esc cancel)$(key_hint blank '= automatic')"
  # Centre the box: size the margins from the popup's terminal.
  read -r rows cols < <(stty size < /dev/tty 2>/dev/null || echo '24 80')
  [ "$cols" -ge $((w + 4)) ] || w=$((cols - 4))
  top=$(( (rows - h) / 2 )); [ "$top" -ge 0 ] || top=0
  side=$(( (cols - w) / 2 )); [ "$side" -ge 0 ] || side=0
  out=$(fzf < /dev/null \
    --with-shell='/bin/sh -c' --disabled --print-query --query="$current" --reverse \
    --margin="$top,$side" --border=rounded --border-label=$'\033[1m describe agent \033[0m' \
    --border-label-pos=3 --padding=1,2 --header="$header" --header-first --ansi \
    --prompt='  ✎ ' --ghost='describe this agent' --info=hidden --no-scrollbar \
    --input-border=line --footer="${footer%   }" --footer-border=none \
    --color='bg:#181818,fg:#e4e4e4,header:#e4e4e4,prompt:#e1d89e,query:#f5f5f5,ghost:#a0a0a0' \
    --color='border:#484848,label:#e4e4e4,input-border:#484848') || rc=$?
  # 0/1 = Enter (1: nothing to select, query still printed); 130 = Esc.
  case "$rc" in 0|1) ;; *) return 0 ;; esac
  query=$(printf '%s\n' "$out" | head -n 1)
  # Enter on the untouched automatic description must not pin it as an override.
  [ -n "$override" ] || [ "$query" != "$current" ] || return 0
  save_description "$target" "$query"
}

# ----- AI description (ctrl-g) ---------------------------------------------
# Ask pi for a short task title from the pane's context. It takes seconds, so
# the work runs under the tmux server (survives the popup closing); a marker
# file shows "generating…" on the card until the result is saved.
generate_start() {
  local target="$1" path_q self_arg token cmd
  [[ "$target" =~ ^%[0-9]+$ ]] || return 0
  pane_alive "$target" || return 0
  # fnm's per-shell bin dirs can go stale; its default alias is a stable fallback.
  PATH="$PATH:$HOME/.local/share/fnm/aliases/default/bin"
  command -v pi >/dev/null 2>&1 || { tmux display-message "agent navigator: pi not found for ctrl-g"; return 0; }
  desc_paths "$target"; mkdir -p "$DESC_DIR"
  # The marker holds the run's token: one run per pane at a time, and only its
  # owner removes it. A marker older than 3 minutes outlived its run (pi is
  # capped at 2), so it is reclaimed.
  token="$$.$RANDOM"
  if ! ( set -C; printf '%s\n' "$token" > "$GEN_FILE" ) 2>/dev/null; then
    if [ -n "$(find "$GEN_FILE" -mmin -3 2>/dev/null)" ]; then
      tmux display-message "agent navigator: already generating a description for $target" 2>/dev/null || true
      return 0
    fi
    printf '%s\n' "$token" > "$GEN_FILE"
  fi
  tmux set-option -g @agent-revision "$(date +%s).$$.$RANDOM" 2>/dev/null || true
  # The server's environment may lack this shell's PATH (pi lives under fnm).
  printf -v path_q '%q' "$PATH"; printf -v self_arg '%q' "$0"
  # run-shell format-expands its command; %q leaves '#' alone, so double it.
  cmd="PATH=$path_q $self_arg --generate-run $target $token"
  tmux run-shell -b "${cmd//#/##}" 2>/dev/null || rm -f "$GEN_FILE"
}

# transcript_context FILE: the latest real user prompts (up to 3, oldest first)
# and the end of the latest assistant reply, from a Claude transcript or a pi
# session file. Reads only the file's tail and skips unparseable lines,
# tool results, sidechains and synthetic messages (notifications, reminders).
transcript_context() {
  local file="$1" size
  [ -f "$file" ] && [ -r "$file" ] && command -v jq >/dev/null 2>&1 || return 0
  size=$(wc -c < "$file" 2>/dev/null) || size=0; size=${size// /}
  # Drop the first line only when the tail cut it in half.
  { if [ "${size:-0}" -gt 3000000 ]; then tail -c 3000000 "$file" | sed 1d; else cat "$file"; fi; } 2>/dev/null | jq -R -r '
    def text: if type == "string" then .
      elif type == "array" then [.[] | select(type == "object" and .type == "text") | .text // ""] | join(" ")
      else "" end;
    def synthetic: test("^\\s*(<[a-z_-]+|\\[SYSTEM NOTIFICATION|Another Claude session sent|The user sent a new message while)");
    fromjson? | select(type == "object")
    | (if .type == "user" or .type == "assistant" then
         select((.isMeta != true) and (.isSidechain != true)) | {r: .type, c: .message.content}
       elif .type == "message" then {r: .message.role, c: .message.content}
       else empty end)
    | select(.r == "user" or .r == "assistant")
    | select(.r != "user" or ((.c | type) != "array") or ([.c[]? | select(type == "object" and .type == "tool_result")] | length) == 0)
    | {r, t: (.c | text | gsub("[\\n\\r\\t]+"; " ") | gsub("^ +| +$"; ""))}
    | select((.t | length) > 0) | select(.r != "user" or (.t | synthetic | not))
    | "\(.r)\t\(.t)"' 2>/dev/null | awk -F '\t' '
      $1 == "user" { u[++n] = substr($2, 1, 500) }
      $1 == "assistant" { a = $2 }
      END {
        if (n) { print "Latest user prompts (oldest first):"; for (i = (n > 3 ? n - 2 : 1); i <= n; i++) print "- " u[i] }
        if (a != "") { if (length(a) > 1200) a = "…" substr(a, length(a) - 1199); print "Latest assistant reply (end):"; print a }
      }'
}

# generate_cleanup: EXIT trap of --generate-run. Removes the marker only while
# this run still owns it, then refreshes open navigators.
generate_cleanup() {
  local owner=""
  [ ! -f "$GEN_FILE" ] || read -r owner < "$GEN_FILE" || true
  [ "$owner" != "$GEN_TOKEN" ] || rm -f "$GEN_FILE"
  tmux set-option -g @agent-revision "$(date +%s).$$.$RANDOM" 2>/dev/null || true
}

generate_run() {
  local target="$1" owner="" info id auto kind path transcript current="" latest="" conversation="" context screen_lines=80 model title
  local limit="${AGENT_NAV_GENERATE_TIMEOUT:-120}" timeout_bin
  local -a runner=()
  [[ "$target" =~ ^%[0-9]+$ ]] || return 0
  desc_paths "$target"
  # generate_start passes the marker token; a direct run claims the marker.
  GEN_TOKEN="${2:-}"
  if [ -n "$GEN_TOKEN" ]; then
    [ ! -f "$GEN_FILE" ] || read -r owner < "$GEN_FILE" || true
    [ "$owner" = "$GEN_TOKEN" ] || return 0  # superseded or cleared meanwhile
  else
    GEN_TOKEN="$$.$RANDOM"; mkdir -p "$DESC_DIR"; printf '%s\n' "$GEN_TOKEN" > "$GEN_FILE"
  fi
  trap generate_cleanup EXIT
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
  info=$(tmux display -p -t "$target" $'#{pane_id}\037#{@agent-auto-description}\037#{@agent-kind}\037#{pane_current_path}\037#{@agent-transcript}' 2>/dev/null) || return 0
  IFS="$SEP" read -r id auto kind path transcript <<< "$info"
  [ "$id" = "$target" ] || return 0  # display -p succeeds for a vanished pane
  [ ! -f "$DESC_FILE" ] || read -r current < "$DESC_FILE" || true
  # The conversation is the best signal; the screen is a fallback (TUIs on the
  # alternate screen have no scrollback, so it is mostly the visible UI).
  case "$transcript" in /*.jsonl) conversation=$(transcript_context "$transcript") ;; esac
  [ -z "$conversation" ] || screen_lines=30
  context=$(tmux capture-pane -p -J -S -300 -t "$target" 2>/dev/null \
    | awk 'NF' | tail -n "$screen_lines" | cut -c1-200)
  model=$(tmux show-option -gqv @agent-describe-model 2>/dev/null || true)
  # Cap pi's runtime: coreutils timeout, else a perl watchdog that, like
  # timeout, kills pi's whole process group (children would hold the pipe
  # open), else no cap.
  timeout_bin=$(command -v timeout || command -v gtimeout || true)
  if [ -n "$timeout_bin" ]; then runner=("$timeout_bin" "$limit")
  elif command -v perl >/dev/null 2>&1; then
    runner=(perl -e '$t = shift; defined($p = fork) or exit 127;
      if (!$p) { setpgrp(0, 0); exec @ARGV or exit 127 }
      setpgrp($p, $p); $SIG{ALRM} = sub { kill "TERM", -$p; exit 124 }; alarm $t;
      waitpid($p, 0); exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$limit")
  fi
  title=$(printf 'Agent: %s\nFolder: %s\nFirst prompt: %s\nCurrent title: %s\n%s\nVisible terminal (may be stale UI):\n%s\n' \
      "${kind:-unknown}" "$path" "$auto" "$current" "$conversation" "$context" \
    | ${runner[@]+"${runner[@]}"} pi --print --no-session --no-tools --model "${model:-openai-codex/gpt-6-luna}" --thinking minimal \
        --system-prompt 'You label coding-agent terminal sessions for a task switcher. Reply with ONE line only: what the agent is working on now, as a concise title of at most 60 characters, imperative mood, no quotes, no trailing period. Weigh the latest user prompts most; the first prompt may be outdated.' \
        'Write the title for this session.' 2>/dev/null | awk 'NF { print; exit }') || title=""
  title="${title#\"}"; title="${title%\"}"
  if [ -z "$title" ]; then
    tmux display-message "agent navigator: could not generate a description" 2>/dev/null || true
    return 0
  fi
  # Keep a Ctrl-E edit made while pi was running, and drop the result if the
  # marker was cleared (pane exit) or reclaimed by a newer run.
  [ ! -f "$DESC_FILE" ] || read -r latest < "$DESC_FILE" || true
  owner=""; [ ! -f "$GEN_FILE" ] || read -r owner < "$GEN_FILE" || true
  [ "$latest" = "$current" ] && [ "$owner" = "$GEN_TOKEN" ] || return 0
  utf8_cut 80 "$title"
  save_description "$target" "$CUT"
}

# Border label: title plus a count per state, attention first.
summary_label() {
  local waiting=0 working=0 finished=0 idle=0 pane state unseen out n s
  while IFS="$SEP" read -r pane state unseen; do
    [ -n "$pane" ] || continue
    shown_state "$state" "$unseen"
    case "$SHOWN" in
      asking) waiting=$((waiting + 1)) ;; working) working=$((working + 1)) ;;
      finished) finished=$((finished + 1)) ;; idle) idle=$((idle + 1)) ;;
    esac
  done < <(tmux list-panes -a -F $'#{pane_id}\037#{@agent-state}\037#{@agent-unseen}' 2>/dev/null)
  out=$'\033[1m agents \033[0m'
  for s in asking working finished idle; do
    case "$s" in asking) n=$waiting ;; working) n=$working ;; finished) n=$finished ;; idle) n=$idle ;; esac
    [ "$n" -gt 0 ] || continue
    icon_of "$s"; out="$out $ICON $n $LABEL "
  done
  [ "$((waiting + working + finished + idle))" -gt 0 ] || out=$'\033[1m agents \033[0m\033[2m none running \033[0m'
  printf '%s' "$out"
}

# Preview: a header naming what is shown (live output of which pane, which
# agent) over a rule, then the pane's live tail with trailing blank rows dropped.
preview_pane() {
  local pane="$1"
  [[ "$pane" =~ ^%[0-9]+$ ]] || return 0
  local screen where loc kind cmd cols rule body_lines
  # capture-pane fails for a missing pane (display -p does not).
  screen=$(tmux capture-pane -e -p -t "$pane" 2>/dev/null) || { printf '\033[2mpane is gone\033[0m\n'; return 0; }
  where=$(tmux display -p -t "$pane" $'#{session_name}:#{window_index}.#{pane_index}\037#{@agent-kind}\037#{pane_current_command}' 2>/dev/null || true)
  IFS="$SEP" read -r loc kind cmd <<< "$where"
  clean_text "$loc · ${kind:-$cmd}"; where="$CLEAN"
  cols=${FZF_PREVIEW_COLUMNS:-60}
  printf -v rule '%*s' "$cols" ''
  printf '\033[1;38;2;150;166;200mlive output\033[0m\033[2m  %s\033[0m\n\033[38;2;72;72;72m%s\033[0m\n' \
    "$where" "${rule// /─}"
  body_lines=$(( ${FZF_PREVIEW_LINES:-40} - 2 ))
  [ "$body_lines" -gt 0 ] || return 0
  printf '%s\n' "$screen" | awk '
    { line[NR] = $0; plain = $0; gsub(/\033\[[0-9;:]*[A-Za-z]/, "", plain); gsub(/\033\][^\033]*\033\\/, "", plain)
      if (plain ~ /[^[:space:]]/) last = NR }
    END { for (i = 1; i <= last; i++) print line[i] }' \
    | tail -n "$body_lines"
}

# prune_descriptions: drop week-old descriptions/markers left by earlier tmux
# servers. Entries of the running server are kept, as are those of other live
# servers (-L) unless untouched for a week; legacy bare-id files and other
# names are never matched.
prune_descriptions() {
  local f name
  [ -d "$DESC_DIR" ] || return 0
  find "$DESC_DIR" -maxdepth 1 -type f \( -name '[0-9]*-[0-9]*' -o -name '.generating-[0-9]*-[0-9]*' \) -mtime +7 2>/dev/null \
    | while IFS= read -r f; do
        name=${f##*/}; name=${name#.generating-}
        [[ "$name" =~ ^[0-9]+-[0-9]+$ ]] || continue
        [ "${name%%-*}" = "$SERVER_START" ] || rm -f "$f"
      done || true
}

refresh_key() {
  local revision now
  revision=$(tmux show-option -gqv @agent-revision 2>/dev/null || true)
  now=$(date +%s)
  REFRESH_KEY="$revision:$((now / 60))"
}

# refresh_action [PANE]: the every(1) tick. Reloads the list when the revision
# or minute changed, and redraws the preview only when PANE's screen changed:
# an unconditional refresh-preview resent the whole preview every second.
refresh_action() {
  local file="${AGENT_NAV_REFRESH_FILE:-}" pane="${1:-}" previous="" shot seen="" actions=""
  [ -f "$file" ] || return 0
  refresh_key
  read -r previous < "$file" || true
  if [ "$REFRESH_KEY" != "$previous" ]; then
    printf '%s\n' "$REFRESH_KEY" > "$file"
    printf -v self_q '%q' "$0"
    # reload, not reload-sync: with --track, reload-sync blocks typing until the
    # whole list has streamed, so automatic refreshes would drop keystrokes.
    actions="reload($self_q --list)+transform-border-label($self_q --label)+refresh-preview"
  fi
  if [[ "$pane" =~ ^%[0-9]+$ ]]; then
    shot="$pane $(tmux capture-pane -e -p -t "$pane" 2>/dev/null | cksum)"
    [ ! -f "$file.preview" ] || read -r seen < "$file.preview" || true
    if [ "$shot" != "$seen" ]; then
      printf '%s\n' "$shot" > "$file.preview"
      [ -n "$actions" ] || actions=refresh-preview
    fi
  fi
  [ -z "$actions" ] || printf '%s\n' "$actions"
}

printf -v self_q '%q' "$0"
case "${1:-}" in
  --list) build_cards; exit 0 ;;
  --edit) edit_description "${2:-}"; exit 0 ;;
  --refresh) refresh_action "${2:-}"; exit 0 ;;
  --label) summary_label; exit 0 ;;
  --preview) preview_pane "${2:-}"; exit 0 ;;
  --dialog) describe_dialog "${2:-}"; exit 0 ;;
  --generate) generate_start "${2:-}"; exit 0 ;;
  --generate-run) generate_run "${2:-}" "${3:-}"; exit 0 ;;
  --context) transcript_context "${2:-}"; exit 0 ;;  # debug: what ctrl-g reads
esac

prune_descriptions
refresh_file=$(mktemp -t agent-status-refresh.XXXXXX)
trap 'rm -f "$refresh_file" "$refresh_file.preview"' EXIT
export AGENT_NAV_REFRESH_FILE="$refresh_file"
refresh_key; printf '%s\n' "$REFRESH_KEY" > "$refresh_file"
# gruber-darker palette, matching the Neovim floats: bg #181818, panel line
# #282828, rule #484848, text #e4e4e4, yellow #e1d89e, green #c0d090,
# niagara #96a6c8.
sel=$(build_cards | fzf \
  --with-shell='/bin/sh -c' --sync --read0 --ansi --reverse --no-sort --cycle --track --id-nth=2 \
  --delimiter="$TAB" --with-nth=4.. \
  --border=rounded --border-label="$(summary_label)" --border-label-pos=3 --padding=0,1 \
  --input-border=line --footer-border=line --footer="$(nav_footer)" \
  --info=inline-right --info-command='printf %s "${FZF_INFO%% +*}"' --prompt='› ' --ghost="$NAV_GHOST" \
  --pointer='▌' --highlight-line --gap --gap-line=' ' \
  --preview="$self_q --preview {2}" \
  --preview-window='right,50%,border-left,<70(up,50%,border-bottom,hidden)' \
  --color='bg:#181818,fg:#e4e4e4,bg+:#282828,fg+:#f5f5f5:regular,gutter:#181818' \
  --color='hl:#c0d090:bold,hl+:#c0d090:bold,pointer:#e1d89e,marker:#96a6c8,spinner:#e1d89e' \
  --color='prompt:#e1d89e,query:#f5f5f5,ghost:#a0a0a0,info:#565f73,label:#e4e4e4' \
  --color='border:#484848,separator:#282828,input-border:#282828,footer-border:#282828' \
  --color='preview-border:#282828,scrollbar:#484848,preview-scrollbar:#484848' \
  --bind 'ctrl-n,ctrl-j:down' --bind 'ctrl-p,ctrl-k:up' --bind 'ctrl-/:toggle-preview' \
  --bind "ctrl-e:execute($self_q --dialog {2})+reload-sync($self_q --list)+transform-border-label($self_q --label)" \
  --bind "ctrl-g:execute-silent($self_q --generate {2})+reload-sync($self_q --list)" \
  --bind "ctrl-r:reload-sync($self_q --list)+transform-border-label($self_q --label)" \
  --bind "every(1):transform($self_q --refresh {2})") || {
  # 1 = no match, 130 = cancelled; anything else is an fzf error worth seeing.
  rc=$?; [ "$rc" -eq 1 ] || [ "$rc" -eq 130 ] || tmux display-message "agent navigator: fzf exited $rc"
  exit 0
}

[ -n "$sel" ] || exit 0
pane=$(printf '%s' "$sel" | awk -F"$TAB" '{print $2}')
"$SCRIPT_DIR/agent/focus-pane.sh" "$pane"
