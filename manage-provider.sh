#!/usr/bin/env bash
# Install/uninstall lifecycle adapters without touching unrelated provider config.
# Usage: manage-provider.sh <install|uninstall> <pi|omp|opencode|kilo|kimi|mastracode|claude>
set -eu
ACTION="${1:-}" PROVIDER="${2:-}"
case "$ACTION:$PROVIDER" in
  install:pi|install:omp|install:opencode|install:kilo|install:kimi|install:mastracode|install:claude|uninstall:pi|uninstall:omp|uninstall:opencode|uninstall:kilo|uninstall:kimi|uninstall:mastracode|uninstall:claude) ;;
  *) echo "usage: $0 <install|uninstall> <pi|omp|opencode|kilo|kimi|mastracode|claude>" >&2; exit 2 ;;
esac
ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ "$PROVIDER" = claude ]; then
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
  command -v jq >/dev/null 2>&1 || { echo "agent-status: jq is required to edit $file" >&2; exit 1; }
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
    src="$ROOT/scripts/kimi/agent-status.sh"; dest="$base/hooks/agent-status.tmux.sh"; config="$base/config.toml"
    ;;
  mastracode)
    base="${MASTRACODE_HOME:-$HOME/.mastracode}"
    src="$ROOT/scripts/mastracode/agent-status.sh"; dest="$base/hooks/agent-status.tmux.sh"; config="$base/hooks.json"
    # Hook event -> adapter action (scripts/agent/hook-event.sh).
    events='[{"event":"SessionStart","action":"session"},{"event":"SessionEnd","action":"end"},{"event":"UserPromptSubmit","action":"working"},{"event":"AgentStart","action":"working"},{"event":"PreToolUse","action":"working"},{"event":"PermissionRequest","action":"blocked"},{"event":"PermissionResult","action":"working"},{"event":"SubagentStart","action":"working"},{"event":"SubagentEnd","action":"working"},{"event":"Interrupt","action":"interrupt"},{"event":"AgentEnd","action":"idle"},{"event":"Stop","action":"idle"}]'
    ;;
esac

if [ "$ACTION" = install ]; then
  # Explicit test/user destination overrides preserve the old Pi behavior of
  # creating the extension directory; default provider homes must already exist.
  if [ "$PROVIDER" = pi ] && [ -n "${PI_EXTENSIONS_DIR:-}" ]; then :; else require_dir "$base"; fi
  case "$PROVIDER" in
    opencode)
      command -v jq >/dev/null 2>&1 || { echo "agent-status: jq is required" >&2; exit 1; }
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
      command -v jq >/dev/null 2>&1 || { echo "agent-status: jq is required" >&2; exit 1; }
      require_regular_config "$config"
      original=/dev/null; [ ! -f "$config" ] || original="$config"
      validate_marked_block "$original" '# >>> agent-status.tmux kimi integration' '# <<< agent-status.tmux kimi integration'
      link_validate "$src" "$dest"
      tmp=$(mktemp "$config.agent-status.XXXXXX") || exit 1
      strip_marked_block "$original" '# >>> agent-status.tmux kimi integration' '# <<< agent-status.tmux kimi integration' > "$tmp"
      cmd_path=$(printf '%s' "$dest" | sed "s/'/'\\\\''/g")
      {
        printf '\n# >>> agent-status.tmux kimi integration\n'
        while IFS='|' read -r event matcher action; do
          printf '[[hooks]]\nevent = "%s"\n' "$event"
          [ -z "$matcher" ] || printf 'matcher = "%s"\n' "$matcher"
          command_value=$(jq -Rn --arg value "'$cmd_path' $action" '$value')
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
        printf '# <<< agent-status.tmux kimi integration\n'
      } >> "$tmp"
      replace_from_file "$config" "$tmp"; rm -f "$tmp"
      link_install "$src" "$dest"
      ;;
    mastracode)
      cmd_path=$(printf '%s' "$dest" | sed "s/'/'\\\\''/g")
      link_validate "$src" "$dest"
      # shellcheck disable=SC2016 # jq variables, not shell variables
      json_update "$config" 'if type != "object" then error("root must be object") else . end | reduce $events[] as $e (. ; .[$e.event] = (((.[$e.event] // []) | map(select((.command // "") | startswith($command + " ") | not))) + [{type:"command",command:($command + " " + $e.action),timeout:10000}]))' --arg command "'$cmd_path'" --argjson events "$events"
      link_install "$src" "$dest"
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
        validate_marked_block "$config" '# >>> agent-status.tmux kimi integration' '# <<< agent-status.tmux kimi integration'
        tmp=$(mktemp "$config.agent-status.XXXXXX") || exit 1
        strip_marked_block "$config" '# >>> agent-status.tmux kimi integration' '# <<< agent-status.tmux kimi integration' > "$tmp"
        replace_from_file "$config" "$tmp"; rm -f "$tmp"
      fi
      link_remove "$src" "$dest"
      ;;
    mastracode)
      if [ -e "$config" ] || [ -L "$config" ]; then
          cmd_path=$(printf '%s' "$dest" | sed "s/'/'\\\\''/g")
        # shellcheck disable=SC2016 # jq variables, not shell variables
        json_update "$config" 'if type != "object" then error("root must be object") else . end | reduce $events[] as $e (. ; ($command + " ") as $owned | if ((.[$e.event] // []) | type) == "array" and ((.[$e.event] // []) | any((.command // "") | startswith($owned))) then .[$e.event] |= map(select((.command // "") | startswith($owned) | not)) | if (.[$e.event] | length) == 0 then del(.[$e.event]) else . end else . end)' --arg command "'$cmd_path'" --argjson events "$events"
      fi
      link_remove "$src" "$dest"
      ;;
    *) link_remove "$src" "$dest" ;;
  esac
  echo "agent-status: uninstalled $PROVIDER adapter"
fi
