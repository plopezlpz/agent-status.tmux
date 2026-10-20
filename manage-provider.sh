#!/usr/bin/env bash
# Install/uninstall lifecycle adapters without touching unrelated provider config.
# Usage: manage-provider.sh <install|uninstall> [--yes | pi|omp|opencode|kilo|kimi|mastracode|claude]
# Without a provider it finds the supported agents on this machine and, in a
# terminal, asks before hooking them up (--yes doesn't ask). The rest are skipped.
#   manage-provider.sh found <provider>   exit 0 if that agent is installed (its config home exists)
set -eu
ACTION="${1:-}" PROVIDER="${2:-}"
PROVIDERS="pi omp opencode kilo kimi mastracode claude"
USAGE="usage: $0 <install|uninstall> [--yes | ${PROVIDERS// /|}]"
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
  pi|omp|opencode|kilo|kimi|mastracode|claude) ;;
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
  if [ -f "$target" ]; then cp -p "$target" "$out"; fi
  cat "$source" > "$out"
  mv "$out" "$target"
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
# Markers must pair in order; anything else would make strip eat user lines.
validate_marked_block() {
  awk -v begin="$2" -v end="$3" '
    $0 == begin { if (open) bad = 1; open = 1 }
    $0 == end { if (!open) bad = 1; open = 0 }
    END { exit (bad || open) }' "$1" || { echo "agent-status: refusing unmatched integration markers in $1" >&2; exit 1; }
}
json_update() {
  local file="$1" filter="$2" tmp
  shift 2
  require_jq "$file"
  require_regular_config "$file"
  tmp=$(mktemp "$file.agent-status.XXXXXX") || exit 1
  if [ -f "$file" ]; then
    if ! jq "$@" "$filter" "$file" > "$tmp"; then rm "$tmp"; echo "agent-status: refusing invalid JSON/JSONC config $file" >&2; exit 1; fi
  else
    if ! printf '{}\n' | jq "$@" "$filter" > "$tmp"; then rm "$tmp"; exit 1; fi
  fi
  replace_from_file "$file" "$tmp"
  rm -f "$tmp"
}

case "$PROVIDER" in
  pi)
    base="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
    src="$ROOT/scripts/pi/agent-status.ts"; dest="${PI_EXTENSIONS_DIR:-$base/extensions}/agent-status.ts"
    ;;
  omp)
    base="${PI_CONFIG_DIR:-.omp}"; case "$base" in /*) ;; *) base="$HOME/$base" ;; esac
    src="$ROOT/scripts/omp/agent-status.ts"; dest="${OMP_EXTENSIONS_DIR:-$base/agent/extensions}/agent-status.ts"
    ;;
  opencode)
    base="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
    src="$ROOT/scripts/opencode/agent-status.js"; dest="$base/plugins/agent-status.tmux.js"
    tui_src="$ROOT/scripts/opencode/agent-status-tui.js"; tui_dest="$base/agent-status-tui.js"; config="$base/tui.jsonc"
    ;;
  kilo)
    base="${KILO_CONFIG_DIR:-$HOME/.config/kilo}"
    src="$ROOT/scripts/kilo/agent-status.js"; dest="$base/plugin/agent-status.tmux.js"
    ;;
  kimi)
    base="${KIMI_CODE_HOME:-$HOME/.kimi-code}"
    config="$base/config.toml"
    begin='# >>> agent-status.tmux kimi integration' end='# <<< agent-status.tmux kimi integration'
    ;;
  mastracode)
    base="${MASTRACODE_HOME:-$HOME/.mastracode}"
    config="$base/hooks.json"
    # Our entries: hook-event.sh from any checkout, or the old symlink.
    # shellcheck disable=SC2016 # jq variables, not shell variables
    strip='def ours: type == "object" and ((.command // "" | tostring) as $c
        | ($c | startswith("\($legacy) ")) or ($c | test("/scripts/agent/hook-event\\.sh'"'"' mastracode [a-z]+$")));
      if type != "object" then error("root must be object") else . end
      | with_entries(if (.value | type) == "array" and any(.value[]; ours)
          then .value |= map(select(ours | not)) | select(.value | length > 0) else . end)'
    # Hook event -> hook-event.sh action.
    events='[{"event":"SessionStart","action":"session"},{"event":"SessionEnd","action":"end"},{"event":"UserPromptSubmit","action":"working"},{"event":"AgentStart","action":"working"},{"event":"PreToolUse","action":"working"},{"event":"PermissionRequest","action":"blocked"},{"event":"PermissionResult","action":"working"},{"event":"SubagentStart","action":"working"},{"event":"SubagentEnd","action":"working"},{"event":"Interrupt","action":"interrupt"},{"event":"AgentEnd","action":"idle"},{"event":"Stop","action":"idle"}]'
    ;;
esac
if [ "$ACTION" = found ]; then
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

if [ "$ACTION" = install ]; then
  # Explicit test/user destination overrides preserve the old Pi behavior of
  # creating the extension directory; default provider homes must already exist.
  if [ "$PROVIDER" = pi ] && [ -n "${PI_EXTENSIONS_DIR:-}" ]; then :; else require_dir "$base"; fi
  case "$PROVIDER" in
    opencode)
      require_jq
      require_regular_config "$config"
      if [ -f "$config" ]; then
        jq -e 'type == "object" and ((.plugin // []) | type == "array")' "$config" >/dev/null 2>&1 || { echo "agent-status: refusing invalid JSON/JSONC plugin config $config" >&2; exit 1; }
      fi
      link_validate "$src" "$dest"; link_validate "$tui_src" "$tui_dest"
      # shellcheck disable=SC2016 # jq variables, not shell variables
      json_update "$config" '(.plugin // []) as $p | .plugin = (if any($p[]; . == "./agent-status-tui.js" or (type == "array" and .[0] == "./agent-status-tui.js")) then $p else $p + ["./agent-status-tui.js"] end)'
      link_install "$src" "$dest"; link_install "$tui_src" "$tui_dest"
      ;;
    kimi)
      require_jq
      require_regular_config "$config"
      original=/dev/null; [ ! -f "$config" ] || original="$config"
      validate_marked_block "$original" "$begin" "$end"
      tmp=$(mktemp "$config.agent-status.XXXXXX") || exit 1
      strip_marked_block "$original" "$begin" "$end" > "$tmp"
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
      } >> "$tmp"
      replace_from_file "$config" "$tmp"; rm -f "$tmp"
      ;;
    mastracode)
      # shellcheck disable=SC2016 # jq variables, not shell variables
      json_update "$config" "$strip"' | reduce $events[] as $e (.; .[$e.event] = (.[$e.event] // []) + [{type:"command",command:"\($hook) \($e.action)",timeout:10000}])' --arg hook "$hook" --arg legacy "$(sh_word "$dest")" --argjson events "$events"
      ;;
    *) link_install "$src" "$dest" ;;
  esac
  echo "agent-status: installed $PROVIDER adapter"
else
  case "$PROVIDER" in
    opencode)
      if [ -e "$config" ] || [ -L "$config" ]; then require_regular_config "$config"; json_update "$config" 'if type != "object" then error("root must be object") elif (.plugin | type) == "array" then .plugin |= map(select(. != "./agent-status-tui.js" and (type != "array" or .[0] != "./agent-status-tui.js"))) else . end'; fi
      link_remove "$src" "$dest"; link_remove "$tui_src" "$tui_dest"
      ;;
    kimi)
      if [ -e "$config" ] || [ -L "$config" ]; then
        require_regular_config "$config"
        validate_marked_block "$config" "$begin" "$end"
        tmp=$(mktemp "$config.agent-status.XXXXXX") || exit 1
        strip_marked_block "$config" "$begin" "$end" > "$tmp"
        replace_from_file "$config" "$tmp"; rm -f "$tmp"
      fi
      link_remove "$src" "$dest"
      ;;
    mastracode)
      if [ -e "$config" ] || [ -L "$config" ]; then
        json_update "$config" "$strip" --arg legacy "$(sh_word "$dest")"
      fi
      link_remove "$src" "$dest"
      ;;
    *) link_remove "$src" "$dest" ;;
  esac
  echo "agent-status: uninstalled $PROVIDER adapter"
fi
