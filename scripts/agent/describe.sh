#!/usr/bin/env bash
# Agent descriptions: the title a UI (corral) shows for an agent pane.
#   describe.sh set PANE [TEXT]   store an override (no TEXT: back to the
#                                 automatic first-prompt description)
#   describe.sh generate PANE     ask pi for a title in the background
#   describe.sh run PANE [TOKEN]  the generation itself (generate starts it)
#   describe.sh context FILE      what generation reads from a transcript
#   describe.sh prune             drop week-old files of earlier servers
# Overrides live in @agent-descriptions-dir as <server start>-<pane number>,
# with a .generating-<server start>-<pane number> marker while pi runs; each
# change bumps @agent-revision so open UIs refresh. clear-pane.sh removes
# both files when the pane exits.
set -eu

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
SEP=$'\037'

info=$(tmux display-message -p $'#{@agent-descriptions-dir}\037#{start_time}' 2>/dev/null || true)
IFS="$SEP" read -r DESC_DIR SERVER_START <<< "$info"
: "${DESC_DIR:=${XDG_DATA_HOME:-$HOME/.local/share}/tmux/agent-status/descriptions}"
# Keyed by server start time and pane number: pane ids restart at %0 with
# the server, so a bare id would hand an old title to a new pane.
case "${SERVER_START:-}" in ''|*[!0-9]*) SERVER_START=0 ;; esac

# desc_paths PANE: DESC_FILE (the override) and GEN_FILE (the marker).
desc_paths() {
  DESC_FILE="$DESC_DIR/$SERVER_START-${1#%}"
  GEN_FILE="$DESC_DIR/.generating-$SERVER_START-${1#%}"
}

bump_revision() {
  tmux set-option -g @agent-revision "$(date +%s).$$.$RANDOM" 2>/dev/null || true
}

# pane_alive PANE: display -p succeeds even for a vanished pane, so compare ids.
pane_alive() {
  [ "$(tmux display -p -t "$1" '#{pane_id}' 2>/dev/null)" = "$1" ]
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

# clean_text TEXT: one line without control characters, at most 240 chars.
clean_text() {
  local text="$1" controls char
  text=${text//$'\n'/ }; text=${text//$'\r'/ }; text=${text//$'\t'/ }
  controls=$'\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177'
  while [ -n "$controls" ]; do
    char=${controls%"${controls#?}"}; controls=${controls#?}; text=${text//"$char"/}
  done
  utf8_cut 240 "$text"; CLEAN="$CUT"
}

# save_description PANE TEXT: store an override (empty TEXT clears it,
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
  bump_revision
}

# ----- AI description ------------------------------------------------------
# Ask pi for a short task title from the pane's context. It takes seconds, so
# the work runs under the tmux server (survives the UI closing); the marker
# file says "generating" until the result is saved.
generate_start() {
  local target="$1" path_q self_arg token cmd
  [[ "$target" =~ ^%[0-9]+$ ]] || return 0
  pane_alive "$target" || return 0
  # fnm's per-shell bin dirs can go stale; its default alias is a stable fallback.
  PATH="$PATH:$HOME/.local/share/fnm/aliases/default/bin"
  command -v pi >/dev/null 2>&1 || { tmux display-message "agent-status: pi not found to generate a description"; return 0; }
  desc_paths "$target"; mkdir -p "$DESC_DIR"
  # The marker holds the run's token: one run per pane at a time, and only its
  # owner removes it. A marker older than 3 minutes outlived its run (pi is
  # capped at 2), so it is reclaimed.
  token="$$.$RANDOM"
  if ! ( set -C; printf '%s\n' "$token" > "$GEN_FILE" ) 2>/dev/null; then
    if [ -n "$(find "$GEN_FILE" -mmin -3 2>/dev/null)" ]; then
      tmux display-message "agent-status: already generating a description for $target" 2>/dev/null || true
      return 0
    fi
    printf '%s\n' "$token" > "$GEN_FILE"
  fi
  bump_revision
  # The server's environment may lack this shell's PATH (pi lives under fnm).
  printf -v path_q '%q' "$PATH"; printf -v self_arg '%q' "$0"
  # run-shell format-expands its command; %q leaves '#' alone, so double it.
  cmd="PATH=$path_q $self_arg run $target $token"
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

# generate_cleanup: EXIT trap of `run`. Removes the marker only while this
# run still owns it, then refreshes open UIs.
generate_cleanup() {
  local owner=""
  [ ! -f "$GEN_FILE" ] || read -r owner < "$GEN_FILE" || true
  [ "$owner" != "$GEN_TOKEN" ] || rm -f "$GEN_FILE"
  bump_revision
}

generate_run() {
  local target="$1" owner="" info id auto kind path transcript current="" latest="" conversation="" context screen_lines=80 model title
  local limit="${AGENT_DESCRIBE_TIMEOUT:-120}" timeout_bin
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
    tmux display-message "agent-status: could not generate a description" 2>/dev/null || true
    return 0
  fi
  # Keep an edit made while pi was running, and drop the result if the marker
  # was cleared (pane exit) or reclaimed by a newer run.
  [ ! -f "$DESC_FILE" ] || read -r latest < "$DESC_FILE" || true
  owner=""; [ ! -f "$GEN_FILE" ] || read -r owner < "$GEN_FILE" || true
  [ "$latest" = "$current" ] && [ "$owner" = "$GEN_TOKEN" ] || return 0
  utf8_cut 80 "$title"
  save_description "$target" "$CUT"
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

case "${1:-}" in
  set) save_description "${2:-}" "${3:-}" ;;
  generate) generate_start "${2:-}" ;;
  run) generate_run "${2:-}" "${3:-}" ;;
  context) transcript_context "${2:-}" ;;
  prune) prune_descriptions ;;
  *) echo "usage: describe.sh set PANE [TEXT] | generate PANE | run PANE [TOKEN] | context FILE | prune" >&2; exit 2 ;;
esac
