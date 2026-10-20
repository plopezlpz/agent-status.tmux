#!/usr/bin/env bash
# Agent titles. A pane's @agent-description is the title the user gave its
# agent; UIs (paddock) show it over the automatic @agent-auto-description and
# may set it themselves. Both are unset with the agent's other options when
# it exits (lib.sh).
#   describe.sh set PANE [TEXT]   set the title (no TEXT: back to automatic)
#   describe.sh suggest PANE      print pi's title for PANE without setting it
#   describe.sh generate PANE     have pi set the title, in the background
#   describe.sh run PANE [TOKEN]  the generation itself (generate starts it)
#   describe.sh context FILE      what pi reads from a transcript
# While a generation runs, the pane's @agent-generating holds its token,
# "<start epoch>.<pid>.<random>".
set -eu

# shellcheck source=lib.sh
. "${BASH_SOURCE[0]%/*}/lib.sh"
SEP=$'\037'
# Where pi may live outside the tmux server's PATH: fnm's per-shell bin dirs
# go stale, its default alias does not. Empty: PATH only.
: "${AGENT_PI_FALLBACK_PATH=$HOME/.local/share/fnm/aliases/default/bin}"

# pane_alive PANE: display -p succeeds even for a vanished pane, so compare ids.
pane_alive() {
  [ "$(tmux display -p -t "$1" '#{pane_id}' 2>/dev/null)" = "$1" ]
}

# pane_option PANE NAME: the pane's option value ("" when unset or gone).
pane_option() {
  tmux show-option -pqv -t "$1" "$2" 2>/dev/null || true
}

# utf8_cut N TEXT: CUT, the first N characters of TEXT (not bytes, so a
# multibyte character is never split), even when the caller's locale is not
# UTF-8.
utf8_cut() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
    *) local LC_ALL=C.UTF-8 2>/dev/null ;;
  esac
  CUT=${2:0:$1}
}

# clean_text TEXT: CLEAN, one line without control characters, at most 240
# characters, without surrounding blanks.
clean_text() {
  local text="$1" controls char
  text=${text//$'\n'/ }; text=${text//$'\r'/ }; text=${text//$'\t'/ }
  controls=$'\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177'
  while [ -n "$controls" ]; do
    char=${controls%"${controls#?}"}; controls=${controls#?}; text=${text//"$char"/}
  done
  text="${text#"${text%%[![:space:]]*}"}"; text="${text%"${text##*[![:space:]]}"}"
  utf8_cut 240 "$text"; CLEAN="$CUT"
}

valid_pane() {
  [[ "$1" =~ ^%[0-9]+$ ]] || { echo "describe.sh: not a pane id: $1" >&2; return 2; }
}

# set_title PANE TEXT: set the title (empty TEXT: back to automatic).
set_title() {
  local target="$1"
  valid_pane "$target" || return
  pane_alive "$target" || { echo "describe.sh: pane $target is gone" >&2; return 1; }
  clean_text "$2"
  if [ -n "$CLEAN" ]; then
    tmux set-option -p -t "$target" @agent-description "$CLEAN"
  else
    tmux set-option -p -u -t "$target" @agent-description
  fi
}

# find_pi: pi on PATH, also trying AGENT_PI_FALLBACK_PATH.
find_pi() {
  [ -z "$AGENT_PI_FALLBACK_PATH" ] || PATH="$PATH:$AGENT_PI_FALLBACK_PATH"
  command -v pi >/dev/null 2>&1
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

# ----- asking pi -----------------------------------------------------------
# ask_title PANE: TITLE, pi's title for PANE from its conversation (else its
# screen). Returns 1 when PANE is gone, 3 with the reason in ASK_ERR when
# there is none (tmux unreachable, pi failed). pi runs as a background job (ASK_PID) so that a signal reaching
# this script can stop it: ask_abort.
ASK_PID="" ASK_TMP=""
ask_title() {
  local target="$1" info id auto kind path transcript current conversation="" context screen_lines=80 model rc=0 err
  local limit="${AGENT_DESCRIBE_TIMEOUT:-120}" timeout_bin
  local -a runner=()
  TITLE="" ASK_ERR=""
  # display -p fails only when tmux can't be run or reached; for a gone pane
  # it describes another one, hence the id check.
  info=$(tmux display -p -t "$target" $'#{pane_id}\037#{@agent-auto-description}\037#{@agent-kind}\037#{pane_current_path}\037#{@agent-transcript}\037#{@agent-description}' 2>/dev/null) \
    || { ASK_ERR="cannot reach tmux"; return 3; }
  IFS="$SEP" read -r id auto kind path transcript current <<< "$info"
  [ "$id" = "$target" ] || return 1  # display -p succeeds for a vanished pane
  # The conversation is the best signal; the screen is a fallback (TUIs on the
  # alternate screen have no scrollback, so it is mostly the visible UI).
  case "$transcript" in /*.jsonl) conversation=$(transcript_context "$transcript") ;; esac
  [ -z "$conversation" ] || screen_lines=30
  context=$(tmux capture-pane -p -J -S -300 -t "$target" 2>/dev/null \
    | awk 'NF' | tail -n "$screen_lines" | cut -c1-200)
  model=$(tmux show-option -gqv @agent-describe-model 2>/dev/null || true)
  # Cap pi's runtime: coreutils timeout, else a perl watchdog that, like
  # timeout, kills pi's whole process group (children would hold the pipe
  # open) on expiry or when it is itself signalled, else no cap.
  timeout_bin=$(command -v timeout || command -v gtimeout || true)
  if [ -n "$timeout_bin" ]; then runner=("$timeout_bin" "$limit")
  elif command -v perl >/dev/null 2>&1; then
    runner=(perl -e '$t = shift; defined($p = fork) or exit 127;
      if (!$p) { setpgrp(0, 0); exec @ARGV or exit 127 }
      setpgrp($p, $p);
      $SIG{ALRM} = sub { kill "TERM", -$p; exit 124 }; alarm $t;
      $SIG{TERM} = $SIG{HUP} = $SIG{INT} = sub { kill "TERM", -$p; exit 143 };
      waitpid($p, 0); exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$limit")
  fi
  ASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/agent-describe.XXXXXX")
  printf 'Agent: %s\nFolder: %s\nFirst prompt: %s\nCurrent title: %s\n%s\nVisible terminal (may be stale UI):\n%s\n' \
      "${kind:-unknown}" "$path" "$auto" "$current" "$conversation" "$context" \
    | ${runner[@]+"${runner[@]}"} pi --print --no-session --no-tools --model "${model:-openai-codex/gpt-6-luna}" --thinking minimal \
        --system-prompt 'You label coding-agent terminal sessions for a task switcher. Reply with ONE line only: what the agent is working on now, as a concise title of at most 60 characters, imperative mood, no quotes, no trailing period. Weigh the latest user prompts most; the first prompt may be outdated.' \
        'Write the title for this session.' > "$ASK_TMP/out" 2> "$ASK_TMP/err" &
  ASK_PID=$!
  wait "$ASK_PID" || rc=$?
  ASK_PID=""
  TITLE=$(awk 'NF { print; exit }' "$ASK_TMP/out")
  TITLE="${TITLE#\"}"; TITLE="${TITLE%\"}"
  err=$(awk 'NF { line = $0 } END { print line }' "$ASK_TMP/err" | cut -c1-160)
  ask_cleanup
  [ -z "$TITLE" ] || [ "$rc" -ne 0 ] || return 0
  TITLE=""
  case "$rc" in
    0) ASK_ERR="pi gave no title" ;;
    124) ASK_ERR="pi timed out after ${limit}s" ;;
    *) ASK_ERR="pi failed: ${err:-exit status $rc}" ;;
  esac
  return 3
}

ask_cleanup() {
  [ -z "$ASK_TMP" ] || rm -rf "$ASK_TMP"
  ASK_TMP=""
}

# ask_abort STATUS: signal handler; stops pi (through its runner, which
# forwards the signal to pi's process group) and exits.
ask_abort() {
  # $!: a signal can land after pi's job starts but before ASK_PID is set
  # (no other background job runs before it).
  local pid="${ASK_PID:-${!:-}}"
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  exit "$1"
}

# suggest_title PANE: print pi's title for PANE, cleaned, without setting it
# (a UI's editor offers it). Waits for pi; fails with the reason on stderr.
suggest_title() {
  local target="$1" rc=0
  valid_pane "$target" || return
  find_pi || { echo "pi is not installed" >&2; return 1; }
  trap ask_cleanup EXIT
  trap 'ask_abort 129' HUP; trap 'ask_abort 130' INT; trap 'ask_abort 143' TERM
  ask_title "$target" || rc=$?
  case "$rc" in
    0) ;;
    1) echo "pane $target is gone" >&2; return 1 ;;
    *) echo "$ASK_ERR" >&2; return 1 ;;
  esac
  clean_text "$TITLE"; utf8_cut 80 "$CLEAN"
  printf '%s\n' "$CUT"
}

# ----- background generation -------------------------------------------------
# generate PANE: run pi under the tmux server (it survives the UI closing),
# one run per pane: @agent-generating names the run's token, and only its
# owner clears it. A token older than 3 minutes outlived its run (pi is
# capped at 2), so it is reclaimed.
generate_start() {
  local target="$1" token current path_q self_arg cmd now
  valid_pane "$target" || return
  pane_alive "$target" || return 0
  find_pi || { tmux display-message "agent-status: pi is not installed"; return 0; }
  now=$(date +%s)
  token="$now.$$.$RANDOM"
  agent_lock "pane-${target#%}"
  current=$(pane_option "$target" @agent-generating)
  case "${current%%.*}" in ''|*[!0-9]*) current=0 ;; *) current=${current%%.*} ;; esac
  if [ $((now - current)) -lt 180 ]; then
    agent_unlock
    tmux display-message "agent-status: already generating a title for $target" 2>/dev/null || true
    return 0
  fi
  tmux set-option -p -t "$target" @agent-generating "$token"
  agent_unlock
  # The server's environment may lack this shell's PATH (pi lives under fnm).
  printf -v path_q '%q' "$PATH"; printf -v self_arg '%q' "$0"
  # run-shell format-expands its command; %q leaves '#' alone, so double it.
  cmd="PATH=$path_q $self_arg run $target $token"
  tmux run-shell -b "${cmd//#/##}" 2>/dev/null || tmux set-option -p -u -t "$target" @agent-generating 2>/dev/null || true
}

# generate_cleanup: EXIT trap of `run`. Clears the marker only while this
# run still owns it.
generate_cleanup() {
  ask_cleanup
  [ "$(pane_option "$GEN_PANE" @agent-generating)" != "$GEN_TOKEN" ] \
    || tmux set-option -p -u -t "$GEN_PANE" @agent-generating 2>/dev/null || true
}

generate_run() {
  local target="$1" current rc=0
  valid_pane "$target" || return
  GEN_PANE="$target" GEN_TOKEN="${2:-}"
  if [ -n "$GEN_TOKEN" ]; then
    # Superseded or cleared (the agent exited) meanwhile.
    [ "$(pane_option "$target" @agent-generating)" = "$GEN_TOKEN" ] || return 0
  else
    pane_alive "$target" || return 0
    GEN_TOKEN="$(date +%s).$$.$RANDOM"
    tmux set-option -p -t "$target" @agent-generating "$GEN_TOKEN"
  fi
  trap generate_cleanup EXIT
  trap 'ask_abort 129' HUP; trap 'ask_abort 130' INT; trap 'ask_abort 143' TERM
  current=$(pane_option "$target" @agent-description)
  ask_title "$target" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) tmux display-message "agent-status: could not generate a title: $ASK_ERR" 2>/dev/null || true; return 0 ;;
  esac
  # Keep a title set while pi ran, and drop the result if the marker was
  # cleared (the agent exited) or reclaimed by a newer run; under the pane's
  # lock, so the agent's exit can't clear its options in between.
  agent_lock "pane-${target#%}"
  if [ "$(pane_option "$target" @agent-description)" = "$current" ] && [ "$(pane_option "$target" @agent-generating)" = "$GEN_TOKEN" ]; then
    utf8_cut 80 "$TITLE"
    set_title "$target" "$CUT" 2>/dev/null || true  # the pane may have gone
  fi
  agent_unlock
  trap generate_cleanup EXIT
}

case "${1:-}" in
  set) set_title "${2:-}" "${3:-}" ;;
  suggest) suggest_title "${2:-}" ;;
  generate) generate_start "${2:-}" ;;
  run) generate_run "${2:-}" "${3:-}" ;;
  context) transcript_context "${2:-}" ;;
  *) echo "usage: describe.sh set PANE [TEXT] | suggest PANE | generate PANE | run PANE [TOKEN] | context FILE" >&2; exit 2 ;;
esac
