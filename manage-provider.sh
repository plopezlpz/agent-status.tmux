#!/usr/bin/env bash
# Install/uninstall lifecycle adapters without touching unrelated provider config.
# Usage: manage-provider.sh <install|uninstall> [-y|--yes | pi|omp|opencode|kilo|kimi|mastracode|claude|codex]
# Without a provider it finds the supported agents on this machine and, in a
# terminal, asks before hooking them up (--yes doesn't ask). The rest are skipped.
#   manage-provider.sh found <provider>   exit 0 if that agent is installed (its config home exists)
set -eu
ACTION="${1:-}" PROVIDER="${2:-}"
PROVIDERS="pi omp opencode kilo kimi mastracode claude codex"
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
  pi|omp|opencode|kilo|kimi|mastracode|claude|codex) ;;
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
json_update() {
  local file="$1" filter="$2" tmp
  shift 2
  require_jq "$file"
  require_regular_config "$file"
  tmp=$(mktemp "$file.agent-status.XXXXXX") || exit 1
  if [ -f "$file" ]; then
    if ! jq "$@" "$filter" "$file" > "$tmp"; then rm "$tmp"; echo "agent-status: refusing to edit $file: it must be plain JSON (no comments) with an object at the top level" >&2; exit 1; fi
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
    # shellcheck disable=SC2016 # jq variables, not shell variables
    strip='def ours: type == "object" and ((.command // "" | tostring) as $c
        | ($c | startswith("\($legacy) ")) or ($c | test("/scripts/agent/hook-event\\.sh'"'"' mastracode [a-z]+$")));
      if type != "object" then error("root must be object") else . end
      | with_entries(if (.value | type) == "array" and any(.value[]; ours)
          then .value |= map(select(ours | not)) | select(.value | length > 0) else . end)'
    # Hook event -> hook-event.sh action. MastraCode exits without waiting
    # for its SessionEnd hooks, which run one after another, so only the
    # first one runs: ours goes first.
    events='[{"event":"SessionStart","action":"session"},{"event":"SessionEnd","action":"end","first":true},{"event":"UserPromptSubmit","action":"working"},{"event":"AgentStart","action":"working"},{"event":"PreToolUse","action":"working"},{"event":"PermissionRequest","action":"blocked"},{"event":"PermissionResult","action":"working"},{"event":"Notification","action":"blocked"},{"event":"SubagentStart","action":"working"},{"event":"SubagentEnd","action":"working"},{"event":"Interrupt","action":"interrupt"},{"event":"AgentEnd","action":"idle"}]'
    ;;
  codex)
    base="${CODEX_HOME:-$HOME/.codex}"
    config="$base/hooks.json"
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

# Codex: one group per event in hooks.json, each running hook-event.sh with
# the event's action. Codex trusts a hook by its key (file, event, group and
# handler index) and a hash of its definition, and silently skips one that
# is new or changed until the user trusts it. So the groups are edited in
# place: an unchanged reinstall writes nothing, a changed command replaces our
# group where it is, a new one goes last, and other tools' groups keep their
# index whenever possible. Interrupt and SessionEnd allow at most 3 seconds.
codex_groups() {
  local hook
  hook="$(sh_word "$ROOT/scripts/agent/hook-event.sh") codex"
  jq -n --arg hook "$hook" '[["SessionStart", "session", 10], ["UserPromptSubmit", "working", 10],
      ["PreToolUse", "tool", 10], ["PermissionRequest", "blocked", 10], ["PostToolUse", "working", 10],
      ["SubagentStop", "working", 10], ["Stop", "idle", 10], ["Interrupt", "interrupt", 3], ["SessionEnd", "end", 3]]
    | map({key: .[0], value: {hooks: [{type: "command", command: "\($hook) \(.[1])", timeout: .[2]}]}})
    | from_entries'
}
# Our hooks: hook-event.sh for codex from any checkout, and the Claude hooks
# Codex copies from Claude's settings when it migrates them (they would
# report a Codex session as Claude).
# shellcheck disable=SC2016 # jq variables, not shell variables
CODEX_OURS='def ours: type == "object" and ((.command // "") | type == "string" and (test("/scripts/agent/hook-event\\.sh'"'"' codex [a-z]+$")
    or test("/(claude-)?agent-status\\.tmux/scripts/agent/(set-state|clear-state|auto-desc)\\.sh(['"'"' ]|$)")
    or ((contains($s + "/") or contains($r + "/")) and test("/(set-state|clear-state|auto-desc)\\.sh(['"'"' ]|$)"))));
  def owned: type == "object" and ((.hooks // null) | type == "array") and any(.hooks[]; ours);'
# shellcheck disable=SC2016
codex_filter="$CODEX_OURS"'
  def pure: owned and all(.hooks[]; ours);
  # Drop our handlers and the groups they leave empty; nothing else changes.
  def strip: map(if owned then .hooks |= map(select(ours | not)) | select(.hooks | length > 0) else . end);
  if type != "object" then error("root must be an object") else . end
  | if (.hooks // {} | type) != "object" then error("hooks must be an object") else . end
  | if any(.hooks // {} | .[]; type != "array") then error("each event must be an array") else . end
  | if $install then .hooks //= {} else . end
  | reduce (.hooks // {} | keys_unsorted[]) as $e (.;
      if $install and $groups[$e] != null then . else
        (.hooks[$e] | any(.[]; owned)) as $had
        | .hooks[$e] |= strip
        | if $had and (.hooks[$e] | length) == 0 then del(.hooks[$e]) else . end end)
  | if $install then
      reduce ($groups | to_entries[]) as $g (.;
        (.hooks[$g.key] // []) as $a
        | ([$a | to_entries[] | select(.value | pure) | .key] | first) as $i
        | .hooks[$g.key] = (if $i == null then ($a | strip) + [$g.value]
            else ($a[:$i] | strip) + [$g.value] + ($a[$i + 1:] | strip) end))
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
CODEX_NEW=""
codex_update() {
  local new backup="" moved=0 f stamp
  require_jq "$config"
  require_regular_config "$config"
  new=$(mktemp "$config.agent-status.XXXXXX") || exit 1
  CODEX_NEW="$new"
  trap 'rm -f "$CODEX_NEW"' EXIT
  # Exactly one JSON document, as Codex reads it; an empty file is {}.
  { if [ -f "$config" ]; then cat "$config"; else printf '{}\n'; fi; } \
    | jq -s --argjson install "$([ "$1" = install ] && echo true || echo false)" --argjson groups "$(codex_groups)" \
      --arg s "$ROOT/scripts/agent" --arg r "$(cd "$ROOT/scripts/agent" && pwd -P)" \
      'if length == 0 then {} elif length == 1 then .[0] else error("several JSON documents") end | '"$codex_filter" > "$new" \
    && [ "$(jq -s length "$new" 2>/dev/null)" = 1 ] \
    || { echo "agent-status: refusing to edit $config: not a Codex hooks file" >&2; exit 1; }
  if [ -f "$config" ]; then
    # Unchanged (formatting aside): leave the file alone.
    if [ "$(jq -s -cS 'if length == 0 then [{}] else . end' "$config")" = "$(jq -s -cS . "$new")" ]; then
      echo "agent-status: $config already $([ "$1" = install ] && echo has the current hooks || echo has no agent-status hooks)"
      return 0
    fi
    moved=$(codex_moved "$config" "$new")
    backup=$(mktemp "$config.bak-$(date +%s).XXXXXX") || exit 1
    cp -p "$config" "$backup"
    # jq writes the whole file in its own layout.
    if [ -s "$config" ] && ! jq . "$config" | cmp -s - "$config"; then
      echo "agent-status: $config is rewritten in jq's layout (2-space indent); its old text is in the backup"
    fi
  fi
  replace_from_file "$config" "$new"
  # Keep only our newest 3 backups (the exact mktemp name pattern above).
  for f in "$config".bak-*; do
    stamp="${f#"$config".bak-}"
    [[ "$stamp" =~ ^[0-9]+\.[A-Za-z0-9]{6}$ ]] && [ -f "$f" ] && [ ! -L "$f" ] || continue
    printf '%s\t%s\n' "${stamp%%.*}" "$f"
  done | sort -t $'\t' -k1,1nr | tail -n +4 | cut -f2- | while IFS= read -r f; do rm -f -- "$f"; done
  echo "agent-status: hooks $([ "$1" = install ] && echo written to || echo removed from) $config"
  [ -z "$backup" ] || echo "agent-status: backup saved to $backup"
  case "$moved" in 0) ;; *) echo "agent-status: $moved hook(s) of other tools moved in $config; Codex asks you to review them again" ;; esac
}

if [ "$ACTION" = install ]; then
  # Explicit test/user destination overrides preserve the old Pi behavior of
  # creating the extension directory; default provider homes must already exist.
  if [ "$PROVIDER" = pi ] && [ -n "${PI_EXTENSIONS_DIR:-}" ]; then :; else require_dir "$base"; fi
  case "$PROVIDER" in
    opencode)
      require_jq
      require_regular_config "$config"
      if [ -f "$config" ]; then
        jq -e 'type == "object" and ((.plugin // []) | type == "array")' "$config" >/dev/null 2>&1 || { echo "agent-status: refusing to edit $config: it must be plain JSON (no comments) with an object at the top level and \"plugin\" as a list" >&2; exit 1; }
      fi
      link_validate "$src" "$dest"; link_validate "$tui_src" "$tui_dest"; link_validate "$v2_src" "$v2_dest"
      # shellcheck disable=SC2016 # jq variables, not shell variables
      json_update "$config" '(.plugin // []) as $p | .plugin = (if any($p[]; . == "./agent-status-tui.js" or (type == "array" and .[0] == "./agent-status-tui.js")) then $p else $p + ["./agent-status-tui.js"] end)'
      link_install "$src" "$dest"; link_install "$tui_src" "$tui_dest"; link_install "$v2_src" "$v2_dest"
      ;;
    kimi)
      require_jq
      require_regular_config "$config"
      original=/dev/null; [ ! -f "$config" ] || original="$config"
      validate_marked_block "$original" "$begin" "$end"
      tmp=$(mktemp "$config.agent-status.XXXXXX") || exit 1
      strip_marked_block "$original" "$begin" "$end" | strip_kimi_hooks > "$tmp"
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
      } >> "$tmp"
      replace_from_file "$config" "$tmp"; rm -f "$tmp"
      ;;
    mastracode)
      # shellcheck disable=SC2016 # jq variables, not shell variables
      json_update "$config" "$strip"' | reduce $events[] as $e (.; {type:"command",command:"\($hook) \($e.action)",timeout:10000} as $h
        | .[$e.event] = if $e.first then [$h] + (.[$e.event] // []) else (.[$e.event] // []) + [$h] end)' --arg hook "$hook" --arg legacy "$(sh_word "$dest")" --argjson events "$events"
      ;;
    codex) codex_update install ;;
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
else
  case "$PROVIDER" in
    opencode)
      if [ -e "$config" ] || [ -L "$config" ]; then require_regular_config "$config"; json_update "$config" 'if type != "object" then error("root must be object") elif (.plugin | type) == "array" then .plugin |= map(select(. != "./agent-status-tui.js" and (type != "array" or .[0] != "./agent-status-tui.js"))) else . end'; fi
      link_remove "$src" "$dest"; link_remove "$tui_src" "$tui_dest"; link_remove "$v2_src" "$v2_dest"
      ;;
    kimi)
      if [ -e "$config" ] || [ -L "$config" ]; then
        require_regular_config "$config"
        validate_marked_block "$config" "$begin" "$end"
        tmp=$(mktemp "$config.agent-status.XXXXXX") || exit 1
        strip_marked_block "$config" "$begin" "$end" | strip_kimi_hooks > "$tmp"
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
    codex) if [ -e "$config" ] || [ -L "$config" ]; then codex_update uninstall; fi ;;
    *) link_remove "$src" "$dest" ;;
  esac
  echo "agent-status: uninstalled $PROVIDER adapter"
fi
