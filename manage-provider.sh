#!/usr/bin/env bash
# Install/uninstall lifecycle adapters without touching unrelated provider config.
# Usage: manage-provider.sh <install|uninstall> [-y|--yes | pi|omp|opencode|kilo|kimi|mastracode|claude|codex|gemini|qwen|antigravity]
# Without a provider it finds the supported agents on this machine and, in a
# terminal, asks before hooking them up (--yes doesn't ask). The rest are skipped.
#   manage-provider.sh found <provider>   exit 0 if that agent is installed (its config home exists)
set -eu
ACTION="${1:-}" PROVIDER="${2:-}"
PROVIDERS="pi omp opencode kilo kimi mastracode claude codex gemini qwen antigravity"
USAGE="usage: $0 <install|uninstall> [-y|--yes | ${PROVIDERS// /|}]
       $0 found <${PROVIDERS// /|}>"
case "$ACTION" in install|uninstall|found) ;; *) echo "$USAGE" >&2; exit 2 ;; esac
ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ "$ACTION" != found ] && { [ -z "$PROVIDER" ] || [ "$PROVIDER" = --yes ] || [ "$PROVIDER" = -y ]; }; then
  [ $# -le 2 ] || { echo "$USAGE" >&2; exit 2; }
  found=""
  for p in $PROVIDERS; do
    if bash "$ROOT/manage-provider.sh" found "$p"; then found="$found $p"; fi
  done
  found=${found# }
  if [ -z "$found" ]; then
    echo "agent-status: no supported agent found (looked for ${PROVIDERS// /, })"
    exit 0
  fi
  list=${found// /, }
  if [ "$ACTION" = install ] && [ -z "$PROVIDER" ] && [ -t 0 ] && [ -t 1 ]; then
    printf 'agent-status: found %s.\nHook them up? [Y/n] ' "$list"
    read -r ans || ans=n
    case "$ans" in '' | y* | Y*) ;; *) echo "Nothing changed."; exit 0 ;; esac
  fi
  rc=0
  for p in $found; do bash "$ROOT/manage-provider.sh" "$ACTION" "$p" || rc=1; done
  if [ "$ACTION" = install ] && [ "$rc" -eq 0 ]; then
    echo "agent-status: hooked up $list; restart them to pick up their hooks."
  fi
  exit "$rc"
fi

case "$PROVIDER" in
  pi|omp|opencode|kilo|kimi|mastracode|claude|codex|gemini|qwen|antigravity) ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac

if [ "$PROVIDER" = claude ]; then
  # Claude's installer would create its settings.json, so "found" means the
  # directory for it exists (~/.claude, or $CLAUDE_CONFIG_DIR as Claude reads it).
  if [ "$ACTION" = found ]; then [ -d "$(dirname "${CLAUDE_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}")" ]; exit; fi
  exec bash "$ROOT/install-claude-hooks.sh" "$ACTION"
fi

canonical_path() {
  local dir base
  dir=$(dirname "$1"); base=$(basename "$1")
  (cd "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base")
}
link_points_to() {
  local src="$1" dest="$2" target
  [ -L "$dest" ] || return 1
  target=$(readlink "$dest")
  case "$target" in /*) ;; *) target="$(dirname "$dest")/$target" ;; esac
  [ "$(canonical_path "$target")" = "$(canonical_path "$src")" ]
}
link_validate() {
  local src="$1" dest="$2"
  if [ -L "$dest" ]; then
    link_points_to "$src" "$dest" || { echo "agent-status: refusing foreign symlink $dest" >&2; exit 1; }
  else
    [ ! -e "$dest" ] || { echo "agent-status: refusing existing user file $dest" >&2; exit 1; }
  fi
}
link_install() {
  local src="$1" dest="$2"
  link_validate "$src" "$dest"
  [ ! -L "$dest" ] || return 0
  mkdir -p "$(dirname "$dest")"
  ln -s "$src" "$dest"
}
link_remove() {
  local src="$1" dest="$2"
  if link_points_to "$src" "$dest"; then rm "$dest"; fi
}
# sh_word STRING: STRING as one single-quoted shell word.
sh_word() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
require_jq() {
  command -v jq >/dev/null 2>&1 || { echo "agent-status: jq is required${1:+ to edit $1}" >&2; exit 1; }
}
require_dir() {
  [ -d "$1" ] && return 0
  echo "agent-status: $PROVIDER config not found at $1; install $PROVIDER first (skipped)" >&2
  exit 0
}
require_regular_config() {
  [ ! -L "$1" ] || { echo "agent-status: refusing to edit config symlink $1" >&2; exit 1; }
  [ ! -e "$1" ] || [ -f "$1" ] || { echo "agent-status: refusing non-file config $1" >&2; exit 1; }
}
replace_from_file() {
  local target="$1" source="$2" out
  out=$(mktemp "$target.agent-status.XXXXXX") || exit 1
  { { [ ! -f "$target" ] || cp -p "$target" "$out"; } && cat "$source" > "$out" && mv "$out" "$target"; } \
    || { rm -f "$out"; return 1; }
}
# Also drops the one blank separator line install writes before the begin
# marker, so reinstall and uninstall are byte-stable.
strip_marked_block() {
  awk -v begin="$2" -v end="$3" '
    skip { if ($0 == end) skip = 0; next }
    $0 == begin { skip = 1; blank = 0; next }
    blank { print ""; blank = 0 }
    $0 == "" { blank = 1; next }
    { print }
    END { if (blank) print "" }' "$1"
}
# strip_kimi_hooks: stdin without our [[hooks]] tables. Kimi rewrites its
# whole config.toml when a line-wise edit won't do (adding a top-level key
# after our block), which drops every comment, so our markers; the tables
# stay, now unmarked.
strip_kimi_hooks() {
  awk -v q="'" '
    function flush(  i, last) {
      if (ours) {
        # Keep comments that follow the table: they may head the next one.
        for (i = 1; i <= n; i++) if (buf[i] !~ /^[[:space:]]*(#|$)/) last = i
        for (i = last + 1; i <= n; i++) if (buf[i] ~ /^[[:space:]]*#/) print buf[i]
      } else for (i = 1; i <= n; i++) print buf[i]
      n = 0; ours = 0; hooks = 0
    }
    /^[[:space:]]*\[/ { flush(); hooks = ($0 ~ /^[[:space:]]*\[\[[[:space:]]*hooks[[:space:]]*\]\][[:space:]]*(#.*)?$/) }
    !hooks { print; next }
    { buf[++n] = $0 }
    $0 ~ ("^[[:space:]]*command[[:space:]]*=[[:space:]]*\".*/scripts/agent/hook-event\\.sh" q " kimi [a-z]+\"[[:space:]]*$") { ours = 1 }
    END { flush() }'
}
# Markers must pair in order; anything else would make strip eat user lines.
validate_marked_block() {
  awk -v begin="$2" -v end="$3" '
    $0 == begin { if (open) bad = 1; open = 1 }
    $0 == end { if (!open) bad = 1; open = 0 }
    END { exit (bad || open) }' "$1" || { echo "agent-status: refusing unmatched integration markers in $1" >&2; exit 1; }
}
# prune_backups FILE: keep only our newest 3 backups of FILE (the exact
# mktemp name pattern of config_replace).
prune_backups() {
  local f stamp
  for f in "$1".bak-*; do
    stamp="${f#"$1".bak-}"
    [[ "$stamp" =~ ^[0-9]+\.[A-Za-z0-9]{6}$ ]] && [ -f "$f" ] && [ ! -L "$f" ] || continue
    printf '%s\t%s\n' "${stamp%%.*}" "$f"
  done | sort -t $'\t' -k1,1nr | tail -n +4 | cut -f2- | while IFS= read -r f; do rm -f -- "$f"; done
}
# config_replace FILE NEW: put NEW in FILE's place, first copying an
# existing FILE to a new FILE.bak-<time>.XXXXXX ($BACKUP).
BACKUP=""
config_replace() {
  BACKUP=""
  if [ -f "$1" ]; then
    BACKUP=$(mktemp "$1.bak-$(date +%s).XXXXXX") || exit 1
    cp -p "$1" "$BACKUP" || { rm -f "$BACKUP"; exit 1; }
  fi
  replace_from_file "$1" "$2" || { [ -z "$BACKUP" ] || rm -f "$BACKUP"; exit 1; }
  prune_backups "$1"
}
# The new file an edit is writing, removed on exit unless moved in place.
EDIT_NEW=""
trap 'rm -f "$EDIT_NEW"' EXIT
# json_edit FILE FILTER [JQ ARGS...]: FILTER's result for FILE in $EDIT_NEW,
# with EDIT_SAME=1 when that is FILE as it is (formatting aside), so there
# is nothing to write. FILE must hold one plain JSON document (comments, which
# some agents read, jq can't keep); an empty or missing FILE is {}. A FILE
# that isn't, or that FILTER refuses (error), is left alone and we stop.
EDIT_SAME=0
json_edit() {
  local file="$1" filter="$2" src err
  shift 2
  require_jq "$file"
  require_regular_config "$file"
  src=/dev/null; [ ! -f "$file" ] || src="$file"
  EDIT_NEW=$(mktemp "$file.agent-status.XXXXXX") || exit 1
  if ! err=$(jq -s "$@" 'if length == 0 then {} elif length == 1 then .[0] else error("it holds several JSON documents") end
      | ['"$filter"'] | if length == 1 then .[0] else error("the edit made \(length) documents") end' "$src" 2>&1 > "$EDIT_NEW"); then
    err=${err##*$'\n'}
    case "$err" in
      *"parse error: "*) err="it must be plain JSON (no comments): ${err#*parse error: }" ;;
      "jq: error (at "*"): "*) err=${err#jq: error (at *): } ;;
      "") err="jq failed" ;;
    esac
    echo "agent-status: refusing to edit $file: $err" >&2
    exit 1
  fi
  EDIT_SAME=0
  if [ -f "$file" ] && [ "$(jq -s -cS 'if length == 0 then [{}] else . end' "$file")" = "$(jq -s -cS . "$EDIT_NEW")" ]; then EDIT_SAME=1; fi
}
# json_commit FILE: put $EDIT_NEW in FILE's place (config_replace), which
# jq writes in its own layout.
json_commit() {
  local relaid=0
  if [ -s "$1" ] && ! jq . "$1" | cmp -s - "$1"; then relaid=1; fi
  config_replace "$1" "$EDIT_NEW"
  [ "$relaid" = 0 ] || echo "agent-status: $1 is rewritten in jq's layout (2-space indent); its old text is in the backup"
}
# json_update FILE FILTER [JQ ARGS...]: edit FILE with FILTER (json_edit),
# writing it, and backing up the old one, only when that changes it.
json_update() {
  json_edit "$@"
  [ "$EDIT_SAME" = 0 ] || return 0
  json_commit "$1"
  [ -z "$BACKUP" ] || echo "agent-status: backup saved to $BACKUP"
}

case "$PROVIDER" in
  pi)
    base="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
    src="$ROOT/scripts/pi/agent-status.ts"; dest="${PI_EXTENSIONS_DIR:-$base/extensions}/agent-status.ts"
    ;;
  omp)
    base="${PI_CONFIG_DIR:-.omp}"; case "$base" in /*) ;; *) base="$HOME/$base" ;; esac
    # A profile (OMP_PROFILE, else PI_PROFILE) has its own agent dir.
    profile="${OMP_PROFILE-${PI_PROFILE:-}}" agent="$base/agent"
    # Like OMP: surrounding blanks are trimmed and "default" means no profile.
    profile="${profile#"${profile%%[![:space:]]*}"}" profile="${profile%"${profile##*[![:space:]]}"}"
    [ "$profile" != default ] || profile=""
    if [ -n "$profile" ]; then
      [[ "$profile" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || { echo "agent-status: invalid OMP profile name '$profile'" >&2; exit 1; }
      agent="$base/profiles/$profile/agent"
    fi
    src="$ROOT/scripts/omp/agent-status.ts"; dest="${OMP_EXTENSIONS_DIR:-$agent/extensions}/agent-status.ts"
    ;;
  opencode)
    # OpenCode 1.x: a server plugin and a TUI plugin listed in tui.jsonc.
    # OpenCode 2: a plugin directory; it ignores tui.jsonc and loads the 1.x
    # server plugin as a no-op. Both are installed, so either version works.
    base="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
    src="$ROOT/scripts/opencode/agent-status.js"; dest="$base/plugins/agent-status.tmux.js"
    tui_src="$ROOT/scripts/opencode/agent-status-tui.js"; tui_dest="$base/agent-status-tui.js"; config="$base/tui.jsonc"
    v2_src="$ROOT/scripts/opencode/v2"; v2_dest="$base/plugins/agent-status.tmux"
    ;;
  kilo)
    base="${KILO_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/kilo}"
    src="$ROOT/scripts/kilo/agent-status.js"; dest="$base/plugin/agent-status.tmux.js"
    ;;
  kimi)
    base="${KIMI_CODE_HOME:-$HOME/.kimi-code}"
    config="$base/config.toml"
    begin='# >>> agent-status.tmux kimi integration' end='# <<< agent-status.tmux kimi integration'
    ;;
  mastracode)
    # MastraCode always reads ~/.mastracode: MASTRACODE_HOME is ours, for tests.
    base="${MASTRACODE_HOME:-$HOME/.mastracode}"
    config="$base/hooks.json"
    # Our entries: hook-event.sh from any checkout, or the old symlink.
    # strip($keep) drops them, with the events they leave empty, but those
    # in $keep, which install fills again where they are.
    # shellcheck disable=SC2016 # jq variables, not shell variables
    strip='def ours: type == "object" and ((.command // "" | tostring) as $c
        | ($c | startswith("\($legacy) ")) or ($c | test("/scripts/agent/hook-event\\.sh'"'"' mastracode [a-z]+$")));
      def strip($keep): if type != "object" then error("its top level must be an object") else . end
        | with_entries(.key as $e | if (.value | type) == "array" and any(.value[]; ours)
            then .value |= map(select(ours | not)) | select((.value | length > 0) or any($keep[]; . == $e)) else . end);'
    # Hook event -> hook-event.sh action. MastraCode exits without waiting
    # for its SessionEnd hooks, which run one after another, so only the
    # first one runs: ours goes first.
    events='[{"event":"SessionStart","action":"session"},{"event":"SessionEnd","action":"end","first":true},{"event":"UserPromptSubmit","action":"working"},{"event":"AgentStart","action":"working"},{"event":"PreToolUse","action":"working"},{"event":"PermissionRequest","action":"blocked"},{"event":"PermissionResult","action":"working"},{"event":"Notification","action":"blocked"},{"event":"SubagentStart","action":"working"},{"event":"SubagentEnd","action":"working"},{"event":"Interrupt","action":"interrupt"},{"event":"AgentEnd","action":"idle"}]'
    ;;
  codex)
    base="${CODEX_HOME:-$HOME/.codex}"
    config="$base/hooks.json"
    ;;
  gemini)
    # GEMINI_CLI_HOME stands in for the home directory, as in Gemini CLI.
    base="${GEMINI_CLI_HOME:-$HOME}/.gemini"
    config="$base/settings.json"
    ;;
  qwen)
    # QWEN_HOME as Qwen reads it: ~ and ~/... are the home directory, and a
    # relative path is taken from here.
    base="${QWEN_HOME:-$HOME/.qwen}"
    # shellcheck disable=SC2088 # a literal ~
    case "$base" in "~") base="$HOME" ;; "~/"*) base="$HOME/${base#"~/"}" ;; /*) ;; *) base="$PWD/$base" ;; esac
    config="$base/settings.json"
    ;;
  antigravity)
    # Antigravity CLI (agy) always reads ~/.gemini: its own files are in
    # antigravity-cli, its global hooks in config.
    base="$HOME/.gemini/antigravity-cli"
    config="$HOME/.gemini/config/hooks.json"
    ;;
esac
# Antigravity (agy) keeps its files in ~/.gemini too: Gemini CLI is there
# once it has its settings, or the id it writes when it first runs.
gemini_found() { [ -f "$config" ] || [ -f "$base/installation_id" ]; }
if [ "$ACTION" = found ]; then
  if [ "$PROVIDER" = gemini ]; then gemini_found; exit; fi
  # An explicit Pi extensions dir counts as installed, as it does for install.
  if [ "$PROVIDER" = pi ] && [ -n "${PI_EXTENSIONS_DIR:-}" ]; then exit 0; fi
  [ -d "$base" ]; exit
fi
if [ "$PROVIDER" = kimi ] || [ "$PROVIDER" = mastracode ]; then
  # Their hooks run hook-event.sh from this checkout. Older releases ran a
  # symlink to scripts/<provider>/agent-status.sh (now a shim for hooks not
  # yet reinstalled). Install leaves an existing one for agents still running
  # with the old hooks; uninstall removes it.
  hook="$(sh_word "$ROOT/scripts/agent/hook-event.sh") $PROVIDER"
  src="$ROOT/scripts/$PROVIDER/agent-status.sh" dest="$base/hooks/agent-status.tmux.sh"
fi

# Codex: one group per event in hooks.json, each running hook-event.sh with
# the event's action. Codex trusts a hook by its key (file, event, group and
# handler index) and a hash of its definition, and silently skips one that
# is new or changed until the user trusts it. So the groups are edited in
# place: an unchanged reinstall writes nothing, a changed command replaces our
# group where it is, a new one goes last, and other tools' groups keep their
# index whenever possible. A group of ours that other groups follow is left
# as an empty placeholder ({"hooks": []}, which Codex accepts) to hold their
# index; a new group of ours takes the first placeholder. Interrupt and
# SessionEnd allow at most 3 seconds.
codex_groups() {
  local hook
  hook="$(sh_word "$ROOT/scripts/agent/hook-event.sh") codex"
  jq -n --arg hook "$hook" '[["SessionStart", "session", 10], ["UserPromptSubmit", "working", 10],
      ["PreToolUse", "tool", 10], ["PermissionRequest", "blocked", 10], ["PostToolUse", "working", 10],
      ["SubagentStop", "working", 10], ["Stop", "idle", 10], ["Interrupt", "interrupt", 3], ["SessionEnd", "end", 3]]
    | map({key: .[0], value: {hooks: [{type: "command", command: "\($hook) \(.[1])", timeout: .[2]}]}})
    | from_entries'
}
# hook_ours KIND: jq's `ours`, our hooks: hook-event.sh for KIND from any
# checkout, and the Claude hooks Codex and Gemini copy from Claude's settings
# when they migrate them (they would report the session as Claude; Qwen's
# hooks take the same commands). `owned`:
# a group holding one ($s, $r: this checkout's scripts/agent).
hook_ours() {
  # shellcheck disable=SC2016 # jq variables, not shell variables
  printf '%s' 'def ours: type == "object" and ((.command // "") | type == "string" and (test("/scripts/agent/hook-event\\.sh'"'"' '"$1"' [a-z]+$")
    or test("/(claude-)?agent-status\\.tmux/scripts/agent/(set-state|clear-state|auto-desc)\\.sh(['"'"' ]|$)")
    or ((contains($s + "/") or contains($r + "/")) and test("/(set-state|clear-state|auto-desc)\\.sh(['"'"' ]|$)"))));
  def owned: type == "object" and ((.hooks // null) | type == "array") and any(.hooks[]; ours);'
}
CODEX_OURS=$(hook_ours codex)
# shellcheck disable=SC2016
codex_filter="$CODEX_OURS"'
  def pure: owned and all(.hooks[]; ours);
  def placeholder: . == {hooks: []};
  # Drop our handlers; a group they leave empty becomes a placeholder.
  def strip: map(if owned then .hooks |= map(select(ours | not)) | if .hooks == [] then {hooks: []} else . end else . end);
  # Placeholders hold no index once nothing follows them.
  def trim: until(length == 0 or (.[-1] | placeholder | not); .[:-1]);
  if type != "object" then error("its top level must be an object") else . end
  | if (.hooks // {} | type) != "object" then error("\"hooks\" must be an object") else . end
  | if any(.hooks // {} | .[]; type != "array") then error("each event in \"hooks\" must be a list") else . end
  | if $install then .hooks //= {} else . end
  | reduce (.hooks // {} | keys_unsorted[]) as $e (.;
      if $install and $groups[$e] != null then . else
        (.hooks[$e] | any(.[]; owned)) as $had
        | if $had then .hooks[$e] |= (strip | trim) else . end
        | if $had and (.hooks[$e] | length) == 0 then del(.hooks[$e]) else . end end)
  | if $install then
      reduce ($groups | to_entries[]) as $g (.;
        (.hooks[$g.key] // []) as $a
        | ([$a | to_entries[] | select(.value | pure) | .key] | first) as $i
        | .hooks[$g.key] = (if $i != null then ($a[:$i] | strip) + [$g.value] + ($a[$i + 1:] | strip)
            else ($a | strip) as $s | ([$s | to_entries[] | select(.value | placeholder) | .key] | first) as $p
              | if $p == null then $s + [$g.value] else $s[:$p] + [$g.value] + $s[$p + 1:] end end | trim))
    else . end'
# codex_moved OLD NEW: how many other tools' hooks NEW moves to another key.
codex_moved() {
  # shellcheck disable=SC2016
  jq -n --slurpfile a "$1" --slurpfile b "$2" --arg s "$ROOT/scripts/agent" --arg r "$(cd "$ROOT/scripts/agent" && pwd -P)" "$CODEX_OURS"'
    def keyed: [.hooks // {} | objects | to_entries[] | .key as $e | .value | arrays | to_entries[] | .key as $g
      | .value | objects | .hooks // [] | arrays | to_entries[] | select(.value | ours | not) | [$e, $g, .key, .value]];
    ($a[0] | keyed) - ($b[0] | keyed) | length'
}
# codex_hooks_off: config.toml turns hooks off ([features] hooks = false).
codex_hooks_off() {
  [ -f "$base/config.toml" ] || return 1
  awk '
    { line = $0; gsub(/[[:space:]]/, "", line) }
    line ~ /^\[/ { features = (line ~ /^\[features\](#.*)?$/); next }
    (features && line ~ /^(codex_)?hooks=false/) || line ~ /^features\.(codex_)?hooks=false/ { off = 1 }
    END { exit !off }' "$base/config.toml"
}
# codex_update install|uninstall: edit hooks.json, backing up the old one.
codex_update() {
  local moved=0
  # Exactly one JSON document, as Codex reads it; an empty file is {}.
  json_edit "$config" "$codex_filter" --argjson install "$([ "$1" = install ] && echo true || echo false)" \
    --argjson groups "$(codex_groups)" --arg s "$ROOT/scripts/agent" --arg r "$(cd "$ROOT/scripts/agent" && pwd -P)"
  # Unchanged (formatting aside): leave the file alone.
  if [ "$EDIT_SAME" = 1 ]; then
    echo "agent-status: $config already $([ "$1" = install ] && echo has the current hooks || echo has no agent-status hooks)"
    return 0
  fi
  [ ! -f "$config" ] || moved=$(codex_moved "$config" "$EDIT_NEW")
  json_commit "$config"
  echo "agent-status: hooks $([ "$1" = install ] && echo written to || echo removed from) $config"
  [ -z "$BACKUP" ] || echo "agent-status: backup saved to $BACKUP"
  case "$moved" in 0) ;; *) echo "agent-status: $moved hook(s) of other tools moved in $config; Codex asks you to review them again" ;; esac
}

# Gemini CLI and Qwen Code: one definition per event in settings.json's
# "hooks", after other tools' ones, each running hook-event.sh with the
# event's action. All are named agent-status: Gemini shows that name while
# one runs, and `/hooks disable agent-status` turns them all off there.
gemini_groups() {
  local hook
  hook="$(sh_word "$ROOT/scripts/agent/hook-event.sh") gemini"
  jq -n --arg hook "$hook" '[["SessionStart", "session"], ["SessionEnd", "end"], ["BeforeAgent", "working"],
      ["AfterAgent", "idle"], ["Notification", "blocked"], ["AfterTool", "tool"]]
    | map({key: .[0], value: {hooks: [{type: "command", name: "agent-status", command: "\($hook) \(.[1])", timeout: 10000}]}})
    | from_entries'
}
# Qwen's events and payloads are Claude Code's; its timeouts are in seconds.
# A Notification hook runs only for the idle prompt Qwen shows after a turn,
# an Esc or a denial: a permission prompt also has its PermissionRequest.
qwen_groups() {
  local hook
  hook="$(sh_word "$ROOT/scripts/agent/hook-event.sh") qwen"
  jq -n --arg hook "$hook" '[["SessionStart", "session"], ["SessionEnd", "end"], ["UserPromptSubmit", "working"],
      ["PreToolUse", "working"], ["PostToolUse", "working"], ["PostToolUseFailure", "working"],
      ["PermissionRequest", "blocked"], ["SubagentStop", "working"], ["Stop", "idle"], ["StopFailure", "idle"],
      ["Notification", "interrupt", "idle_prompt"]]
    | map({key: .[0], value: ((if .[2] then {matcher: .[2]} else {} end)
        + {hooks: [{type: "command", name: "agent-status", command: "\($hook) \(.[1])", timeout: 10}]})})
    | from_entries'
}
# Our handlers are dropped, with the definitions and events they leave
# empty; an event that already holds just our current definition keeps it
# where it is. Other keys (hooksConfig, and the enabled, disabled and
# notifications that older Gemini releases and Qwen keep in "hooks") are left
# alone.
# shellcheck disable=SC2016 # jq variables, not shell variables
settings_filter='
  def strip: map(if owned then .hooks |= map(select(ours | not)) | select(.hooks != []) else . end);
  if type != "object" then error("its top level must be an object") else . end
  | if (.hooks // {} | type) != "object" then error("\"hooks\" must be an object") else . end
  | if any(.hooks // {} | to_entries[]; $groups[.key] != null and (.value | type) != "array") then error("each event in \"hooks\" must be a list") else . end
  | . as $orig
  | reduce (.hooks // {} | keys_unsorted[]) as $e (.;
      if (.hooks[$e] | type) != "array" or ($install and $groups[$e] != null) or (any(.hooks[$e][]; owned) | not) then .
      else .hooks[$e] |= strip | if .hooks[$e] == [] then del(.hooks[$e]) else . end end)
  | if $install then
      reduce ($groups | to_entries[]) as $g (.hooks //= {};
        (.hooks[$g.key] // []) as $a
        | if [$a[] | select(owned)] == [$g.value] then . else .hooks[$g.key] = ($a | strip) + [$g.value] end)
    elif .hooks == {} and $orig.hooks != {} then del(.hooks)
    else . end'
# Antigravity CLI: hooks.json is an object of named hooks, each holding
# handlers per event (a tool event's in groups, by tool name). Ours is
# named agent-status, kept where it is, or added last; handlers of ours that
# other named hooks hold are dropped. agy's /hooks rewrites the file when it
# turns a hook off ("enabled": false, which a reinstall keeps): it sorts the
# names, writes null for each event left empty, and drops SessionStart,
# which ours doesn't use. PreInvocation runs before each model call; among
# tools only the model's ask_question is hooked. Timeouts are in seconds.
antigravity_groups() {
  local hook
  hook="$(sh_word "$ROOT/scripts/agent/hook-event.sh") antigravity"
  jq -n --arg hook "$hook" 'def run($action): {type: "command", command: "\($hook) \($action)", timeout: 10};
    {PreInvocation: [run("working")], PreToolUse: [{matcher: "ask_question", hooks: [run("blocked")]}],
      PostToolUse: [{matcher: "ask_question", hooks: [run("working")]}], Stop: [run("idle")]}'
}
# shellcheck disable=SC2016 # jq variables, not shell variables
antigravity_filter='
  def ours: type == "object" and ((.command // "") | type == "string" and test("/scripts/agent/hook-event\\.sh'"'"' antigravity [a-z]+$"));
  def strip: map(if type == "object" and (.hooks | type) == "array" and any(.hooks[]; ours)
      then .hooks |= map(select(ours | not)) | select(.hooks != []) elif ours then empty else . end);
  if type != "object" then error("its top level must be an object") else . end
  | with_entries(if .key == "agent-status" or (.value | type) != "object" then . else .value |= with_entries(
      if (.value | type) == "array" and (.value | strip) != .value then .value |= strip | select(.value != []) else . end) end)
  | if $install then .["agent-status"] as $o | .["agent-status"] = (if ($o | type) == "object" and $o.enabled == false then {enabled: false} else {} end) + $groups
    else del(.["agent-status"]) end'
# settings_update install|uninstall: edit $PROVIDER's settings.json (or
# Antigravity's hooks.json), backing up the old one.
settings_update() {
  local filter
  filter="$(hook_ours "$PROVIDER")$settings_filter"
  [ "$PROVIDER" != antigravity ] || filter=$antigravity_filter
  json_edit "$config" "$filter" --argjson install "$([ "$1" = install ] && echo true || echo false)" \
    --argjson groups "$("${PROVIDER}_groups")" --arg s "$ROOT/scripts/agent" --arg r "$(cd "$ROOT/scripts/agent" && pwd -P)"
  if [ "$EDIT_SAME" = 1 ]; then
    echo "agent-status: $config already $([ "$1" = install ] && echo has the current hooks || echo has no agent-status hooks)"
    return 0
  fi
  json_commit "$config"
  echo "agent-status: hooks $([ "$1" = install ] && echo written to || echo removed from) $config"
  [ -z "$BACKUP" ] || echo "agent-status: backup saved to $BACKUP"
}

# Kimi: put the edited config.toml ($EDIT_NEW) in place, backing up the old
# one, unless it is the same text.
kimi_write() {
  if [ -f "$config" ] && cmp -s "$EDIT_NEW" "$config"; then return 0; fi
  config_replace "$config" "$EDIT_NEW"
  [ -z "$BACKUP" ] || echo "agent-status: backup saved to $BACKUP"
}

if [ "$ACTION" = install ]; then
  # Explicit test/user destination overrides preserve the old Pi behavior of
  # creating the extension directory; default provider homes must already exist.
  if [ "$PROVIDER" = pi ] && [ -n "${PI_EXTENSIONS_DIR:-}" ]; then :; else require_dir "$base"; fi
  case "$PROVIDER" in
    opencode)
      link_validate "$src" "$dest"; link_validate "$tui_src" "$tui_dest"; link_validate "$v2_src" "$v2_dest"
      # shellcheck disable=SC2016 # jq variables, not shell variables
      json_update "$config" 'if type != "object" then error("its top level must be an object")
        elif (.plugin // [] | type) != "array" then error("\"plugin\" must be a list") else . end
        | (.plugin // []) as $p | .plugin = (if any($p[]; . == "./agent-status-tui.js" or (type == "array" and .[0] == "./agent-status-tui.js")) then $p else $p + ["./agent-status-tui.js"] end)'
      link_install "$src" "$dest"; link_install "$tui_src" "$tui_dest"; link_install "$v2_src" "$v2_dest"
      ;;
    kimi)
      require_jq
      require_regular_config "$config"
      original=/dev/null; [ ! -f "$config" ] || original="$config"
      validate_marked_block "$original" "$begin" "$end"
      EDIT_NEW=$(mktemp "$config.agent-status.XXXXXX") || exit 1
      strip_marked_block "$original" "$begin" "$end" | strip_kimi_hooks > "$EDIT_NEW"
      {
        printf '\n%s\n' "$begin"
        while IFS='|' read -r event matcher action; do
          printf '[[hooks]]\nevent = "%s"\n' "$event"
          [ -z "$matcher" ] || printf 'matcher = "%s"\n' "$matcher"
          command_value=$(jq -Rn --arg value "$hook $action" '$value')
          printf 'command = %s\ntimeout = 10\n\n' "$command_value"
        done <<'KIMI'
SessionStart||session
SessionEnd||end
UserPromptSubmit||working
TurnStarted|^(?!user$).*$|working
PreToolUse|^(?!AskUserQuestion$).*$|working
PreToolUse|^AskUserQuestion$|blocked
PostToolUse|^AskUserQuestion$|working
PostToolUseFailure|^AskUserQuestion$|working
SubagentStart||working
PreCompact||working
PermissionRequest||blocked
PermissionResult||working
Stop||idle
StopFailure||idle
Interrupt||interrupt
KIMI
        printf '%s\n' "$end"
      } >> "$EDIT_NEW"
      kimi_write
      ;;
    mastracode)
      # shellcheck disable=SC2016 # jq variables, not shell variables
      json_update "$config" "$strip"' strip([$events[].event])
        | if any($events[].event as $e | .[$e]; type != "array" and type != "null") then error("each event must be a list") else . end
        | reduce $events[] as $e (.; {type:"command",command:"\($hook) \($e.action)",timeout:10000} as $h
          | .[$e.event] = if $e.first then [$h] + (.[$e.event] // []) else (.[$e.event] // []) + [$h] end)' --arg hook "$hook" --arg legacy "$(sh_word "$dest")" --argjson events "$events"
      ;;
    codex) codex_update install ;;
    gemini)
      gemini_found || { echo "agent-status: gemini config not found at $base; install gemini first (skipped)" >&2; exit 0; }
      settings_update install
      ;;
    qwen) settings_update install ;;
    antigravity) mkdir -p "${config%/*}"; settings_update install ;;
    *) link_install "$src" "$dest" ;;
  esac
  echo "agent-status: installed $PROVIDER adapter"
  if [ "$PROVIDER" = codex ]; then
    ! codex_hooks_off || echo "agent-status: $base/config.toml turns Codex hooks off: set hooks = true under [features]" >&2
    cat <<'EOF'
agent-status: Codex runs a new or changed hook only once you trust it. If
  Codex says "Hooks need review" when it starts, choose "Review hooks" (or
  run /hooks) and trust the hook-event.sh ones.
agent-status: in tmux, run Codex as `codex --no-daemon`. Its shared
  background server runs the hooks of every session with the environment
  of the terminal that started it, so they can't tell which pane is theirs
  and report nothing. With an alias that adds --no-daemon, run
  `codex agents` and `codex --remote` (which need that server) as
  `command codex ...`.
EOF
  fi
  if [ "$PROVIDER" = qwen ]; then
    ! jq -e '.disableAllHooks == true' "$config" >/dev/null 2>&1 \
      || echo "agent-status: $config turns all hooks off (disableAllHooks): set it to false" >&2
    cat <<'EOF'
agent-status: restart running Qwen Code sessions. Qwen runs no hooks with
  --safe-mode or --bare.
EOF
  fi
  if [ "$PROVIDER" = gemini ]; then
    ! jq -e '.hooksConfig.enabled == false or any(.hooksConfig.disabled[]?; . == "agent-status")' "$config" >/dev/null 2>&1 \
      || echo "agent-status: $config turns these hooks off (hooksConfig): enable them, or run /hooks enable agent-status in Gemini" >&2
    cat <<'EOF'
agent-status: Gemini CLI runs hooks only in folders you trust.
agent-status: restart running Gemini sessions. A Gemini that was already
  running can drop these hooks the next time it saves a setting: if they
  are gone, run this again.
EOF
  fi
  if [ "$PROVIDER" = antigravity ]; then
    ! jq -e '.["agent-status"].enabled == false' "$config" >/dev/null 2>&1 \
      || echo "agent-status: $config turns these hooks off (\"enabled\": false): turn agent-status on in agy's /hooks" >&2
    echo "agent-status: restart running agy sessions."
  fi
else
  case "$PROVIDER" in
    opencode)
      if [ -e "$config" ] || [ -L "$config" ]; then require_regular_config "$config"; json_update "$config" 'if type != "object" then error("its top level must be an object") elif (.plugin | type) == "array" then .plugin |= map(select(. != "./agent-status-tui.js" and (type != "array" or .[0] != "./agent-status-tui.js"))) else . end'; fi
      link_remove "$src" "$dest"; link_remove "$tui_src" "$tui_dest"; link_remove "$v2_src" "$v2_dest"
      ;;
    kimi)
      if [ -e "$config" ] || [ -L "$config" ]; then
        require_regular_config "$config"
        validate_marked_block "$config" "$begin" "$end"
        EDIT_NEW=$(mktemp "$config.agent-status.XXXXXX") || exit 1
        strip_marked_block "$config" "$begin" "$end" | strip_kimi_hooks > "$EDIT_NEW"
        kimi_write
      fi
      link_remove "$src" "$dest"
      ;;
    mastracode)
      if [ -e "$config" ] || [ -L "$config" ]; then
        json_update "$config" "$strip"' strip([])' --arg legacy "$(sh_word "$dest")"
      fi
      link_remove "$src" "$dest"
      ;;
    codex) if [ -e "$config" ] || [ -L "$config" ]; then codex_update uninstall; fi ;;
    gemini|qwen|antigravity) if [ -e "$config" ] || [ -L "$config" ]; then settings_update uninstall; fi ;;
    *) link_remove "$src" "$dest" ;;
  esac
  echo "agent-status: uninstalled $PROVIDER adapter"
fi
