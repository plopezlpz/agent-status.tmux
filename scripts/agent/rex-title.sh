#!/usr/bin/env bash
# Agent titles in a Rex pane, outside tmux, with AGENT_AUTO_TITLE=on in the
# agent's environment. Rex keeps an agent's state itself (OSC 7501): only its
# title is this plugin's there. A session's first prompt gets pi's title
# (describe.sh title), set as the pane's label, which paddock and Rex show;
# the agent's exit, or a name the session is given, takes it back. A label
# you gave stays: the title goes only over Rex's default label, or over the
# one this script set last, as a file per pane keeps it (with the session it
# titled, so each session is titled once).
#   rex-title.sh hook                  a Claude Code hook's payload on stdin
#   rex-title.sh prompt SESSION TEXT   an adapter's prompt (pi)
#   rex-title.sh drop                  an adapter's agent quit (pi)
#   rex-title.sh name SESSION          (in the background) title the prompt
#                                      on stdin
set -eu

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

[ "${AGENT_AUTO_TITLE:-}" = on ] && [ -n "${REX_BLOCK:-}" ] && [ -n "${REX_SESSION:-}" ] || exit 0
case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk-*) exit 0 ;; esac
command -v rex >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0
DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-status/rex"
FILE="$DIR/${REX_BLOCK//[^A-Za-z0-9._-]/_}"

# read_record: TITLED, the session last titled in this pane, and MINE, the
# label set for it.
read_record() {
  TITLED="" MINE=""
  [ -f "$FILE" ] || return 0
  { IFS= read -r TITLED; IFS= read -r MINE; } < "$FILE" 2>/dev/null || true
}

# write_record SESSION LABEL: private, as the tmux options it stands for.
write_record() {
  ( umask 077; mkdir -p "$DIR" && printf '%s\n%s\n' "$1" "$2" > "$FILE.$$" && mv -f "$FILE.$$" "$FILE" ) 2>/dev/null
}

# The pane's label, as Rex left it or as this script set it (MINE), is
# replaced by TITLE (mode set) or by Rex's default (mode drop); any other
# label is someone's, and stays. It answers what it did.
LABEL_LUA='local a = rex.args
local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
rex.session.attach { session_id = a.session }
local d = rex.session.describe_block { session_id = a.session, block_id = a.block }
if not (d and d.block) then return "gone" end
local label, mine, title = trim(d.block.label), trim(a.mine), trim(a.title)
local ours = mine ~= "" and label == mine
local function set(to, said)
  return rex.session.set_block_label { session_id = a.session, block_id = a.block, label = to } and said or "failed"
end
if a.mode == "drop" then return ours and set("", "dropped") or "kept" end
local default = label == "" or label == "shell" or label:match("^Block %x%x%x%x%x%x%x%x$")
if not (default or ours) then return "kept" end
if label == title then return "set" end
return set(title, "set")'

# label MODE TITLE: SAID, what the Lua did with this pane's label.
label() {
  local args
  args=$(jq -n --arg mode "$1" --arg session "$REX_SESSION" --arg block "$REX_BLOCK" --arg title "$2" --arg mine "$MINE" \
    '{mode: $mode, session: $session, block: $block, title: $title, mine: $mine}')
  SAID=$(rex "do" -e "$LABEL_LUA" --args - <<< "$args" 2>/dev/null) || SAID=""
}

# start SESSION PROMPT: title SESSION from PROMPT, its first, in the
# background (the agent does not wait for a model).
start() {
  local session="$1" prompt="$2"
  [ -n "$session" ] && [ -n "$prompt" ] || return 0
  read_record
  [ "$TITLED" != "$session" ] || return 0
  # Unrecorded, every prompt would be the first.
  write_record "$session" "$MINE" || return 0
  utf8_cut 2000 "$prompt"
  nohup bash "${BASH_SOURCE[0]}" name "$session" <<< "$CUT" >/dev/null 2>&1 &
}

# name SESSION: pi's title for the prompt on stdin, as the pane's label,
# unless another session took the pane over meanwhile.
name() {
  local session="$1" title
  title=$(bash "$SCRIPT_DIR/describe.sh" title "$PWD" 2>/dev/null) && [ -n "$title" ] || return 0
  read_record
  [ "$TITLED" = "$session" ] || return 0
  label set "$title"
  [ "$SAID" = '"set"' ] || return 0
  # A session that started meanwhile keeps its turn: the label is ours.
  read_record
  write_record "${TITLED:-$session}" "$title" || true
  find "$DIR" -type f -mtime +30 -delete 2>/dev/null || true
}

# drop: the label set, if the pane still has it, goes back to Rex's default.
drop() {
  read_record
  [ -n "$MINE" ] || return 0
  label drop ""
  case "$SAID" in '"dropped"'|'"kept"'|'"gone"') write_record "$TITLED" "" || true ;; esac
}

# hook: a Claude Code hook's payload. A prompt to the main thread starts a
# session's title, unless the session has a name (--name, /rename), which
# takes the title back; the session's end (not a /clear or resume, which go
# on in the pane) takes it back too.
hook() {
  local fields event session agent title prompt reason
  fields=$(jq -r 'def line: tostring | .[:500] | gsub("[\n\r\t]"; " ") | gsub("[\u0000-\u001f\u007f]"; "");
    [(.hook_event_name // ""), (.session_id // ""), (.agent_id // ""), (.session_title // "" | line),
     (.prompt // "" | tostring
       | (gsub("<pasted_content[^>]*>[\\s\\S]*?</pasted_content[^>]*>"; " ") | select(test("\\S")))
         // gsub("</?pasted_content[^>]*>"; " ")
       | sub("^\\s+"; "") | line),
     (.reason // "")]
    | join("\u001f")' 2>/dev/null) || return 0
  IFS=$'\037' read -r event session agent title prompt reason <<< "$fields"
  case "$event" in
    UserPromptSubmit)
      [ -z "$agent" ] || return 0
      if [ -n "$title" ]; then drop; else start "$session" "$prompt"; fi ;;
    SessionEnd)
      case "$reason" in clear|resume) ;; *) drop ;; esac ;;
  esac
}

case "${1:-}" in
  hook) hook ;;
  prompt) start "${2:-}" "${3:-}" ;;
  drop) drop ;;
  name) name "${2:-}" ;;
  *) echo "usage: rex-title.sh hook | prompt SESSION TEXT | drop | name SESSION" >&2; exit 2 ;;
esac
