#!/usr/bin/env bash
set -euo pipefail
ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: provider installers (jq missing)"; exit 0; }

export HOME="$TMP/home"; mkdir -p "$HOME"
export PI_EXTENSIONS_DIR="$TMP/pi/extensions"
export PI_CONFIG_DIR="$TMP/omp"; mkdir -p "$PI_CONFIG_DIR"
export OPENCODE_CONFIG_DIR="$TMP/opencode"; mkdir -p "$OPENCODE_CONFIG_DIR"; echo '{"theme":"safe","plugin":["keep"]}' > "$OPENCODE_CONFIG_DIR/tui.jsonc"; chmod 600 "$OPENCODE_CONFIG_DIR/tui.jsonc"
export KILO_CONFIG_DIR="$TMP/kilo"; mkdir -p "$KILO_CONFIG_DIR"
export KIMI_CODE_HOME="$TMP/kimi"; mkdir -p "$KIMI_CODE_HOME"; echo 'model = "keep"' > "$KIMI_CODE_HOME/config.toml"
export MASTRACODE_HOME="$TMP/mastra"; mkdir -p "$MASTRACODE_HOME"
# Includes an Interrupt entry from an older event map and a release that ran a
# symlinked adapter, and a Stop entry from a moved checkout: all are replaced.
jq -n --arg wrapped "wrapper $MASTRACODE_HOME/hooks/agent-status.tmux.sh extra" --arg old "'$MASTRACODE_HOME/hooks/agent-status.tmux.sh' idle" '{UserPromptSubmit:[{type:"command",command:"keep"},{type:"command",command:$wrapped}],Interrupt:[{type:"command",command:$old}],Stop:[{type:"command",command:"'"'/moved/agent-status.tmux/scripts/agent/hook-event.sh' mastracode idle"'"}]}' > "$MASTRACODE_HOME/hooks.json"
for home in "$KIMI_CODE_HOME" "$MASTRACODE_HOME"; do
  mkdir -p "$home/hooks"; ln -s "$ROOT/scripts/${home##*/}/agent-status.sh" "$home/hooks/agent-status.tmux.sh"
done

for provider in pi omp opencode kilo kimi mastracode; do
  bash "$ROOT/manage-provider.sh" install "$provider" >/dev/null
  bash "$ROOT/manage-provider.sh" install "$provider" >/dev/null
done
ln -s "$ROOT" "$TMP/plugin-alias"
bash "$TMP/plugin-alias/manage-provider.sh" install pi >/dev/null
[ -L "$PI_EXTENSIONS_DIR/agent-status.ts" ] || fail "pi link missing"
[ -L "$PI_CONFIG_DIR/agent/extensions/agent-status.ts" ] || fail "omp link missing"
[ -L "$OPENCODE_CONFIG_DIR/plugins/agent-status.tmux.js" ] || fail "opencode plugin missing"
[ "$(jq '[.plugin[] | select(. == "./agent-status-tui.js")] | length' "$OPENCODE_CONFIG_DIR/tui.jsonc")" -eq 1 ] || fail "opencode config duplicated"
[ "$(jq -r .theme "$OPENCODE_CONFIG_DIR/tui.jsonc")" = safe ] || fail "opencode changed unrelated config"
mode=$(stat -c %a "$OPENCODE_CONFIG_DIR/tui.jsonc" 2>/dev/null || stat -f %Lp "$OPENCODE_CONFIG_DIR/tui.jsonc")
[ "$mode" = 600 ] || fail "opencode changed config permissions"
[ "$(grep -c '^# >>> agent-status.tmux kimi integration$' "$KIMI_CODE_HOME/config.toml")" -eq 1 ] || fail "kimi block duplicated"
[ "$(grep -c '^\[\[hooks\]\]$' "$KIMI_CODE_HOME/config.toml")" -eq 14 ] || fail "kimi hook map is not exact"
grep -A1 '^event = "StopFailure"$' "$KIMI_CODE_HOME/config.toml" | grep -q "' kimi idle\"$" || fail "kimi StopFailure does not end the turn"
grep -F 'model = "keep"' "$KIMI_CODE_HOME/config.toml" >/dev/null || fail "kimi changed unrelated config"
[ "$(grep -cF "command = \"'$ROOT/scripts/agent/hook-event.sh' kimi " "$KIMI_CODE_HOME/config.toml")" -eq 14 ] || fail "kimi hooks do not run hook-event.sh"
[ ! -e "$KIMI_CODE_HOME/hooks/agent-status.tmux.sh" ] || fail "kimi kept the old adapter link"
[ ! -e "$MASTRACODE_HOME/hooks/agent-status.tmux.sh" ] || fail "mastra kept the old adapter link"
grep -A1 '^event = "Interrupt"$' "$KIMI_CODE_HOME/config.toml" | grep -q "' kimi interrupt\"$" || fail "kimi Interrupt claims a completion"
[ "$(jq -c '[.Interrupt[].command | split(" ") | last]' "$MASTRACODE_HOME/hooks.json")" = '["interrupt"]' ] || fail "mastra Interrupt not replaced by interrupt"
[ "$(jq '[.UserPromptSubmit[] | select(.command == "keep")] | length' "$MASTRACODE_HOME/hooks.json")" -eq 1 ] || fail "mastra removed unrelated hook"
[ "$(jq --arg wrapped "wrapper $MASTRACODE_HOME/hooks/agent-status.tmux.sh extra" '[.UserPromptSubmit[] | select(.command == $wrapped)] | length' "$MASTRACODE_HOME/hooks.json")" -eq 1 ] || fail "mastra removed a non-owned command containing its path"
[ "$(jq 'keys | length' "$MASTRACODE_HOME/hooks.json")" -eq 12 ] || fail "mastra hook map is not exact"
[ "$(jq --arg hook "'$ROOT/scripts/agent/hook-event.sh' mastracode " '[.[][] | select(.command | startswith($hook))] | length' "$MASTRACODE_HOME/hooks.json")" -eq 12 ] || fail "mastra hooks do not run hook-event.sh, once per event"

for provider in pi omp opencode kilo kimi mastracode; do bash "$ROOT/manage-provider.sh" uninstall "$provider" >/dev/null; done
[ ! -e "$PI_EXTENSIONS_DIR/agent-status.ts" ] || fail "pi link remained"
[ "$(jq -r .theme "$OPENCODE_CONFIG_DIR/tui.jsonc")" = safe ] || fail "opencode uninstall changed unrelated config"
[ "$(jq -r '.UserPromptSubmit[0].command' "$MASTRACODE_HOME/hooks.json")" = keep ] || fail "mastra uninstall removed user hook"
[ "$(jq -c 'keys' "$MASTRACODE_HOME/hooks.json")" = '["UserPromptSubmit"]' ] || fail "mastra uninstall left hooks behind"
[ "$(jq --arg wrapped "wrapper $MASTRACODE_HOME/hooks/agent-status.tmux.sh extra" '[.UserPromptSubmit[] | select(.command == $wrapped)] | length' "$MASTRACODE_HOME/hooks.json")" -eq 1 ] || fail "mastra uninstall removed non-owned command"
! grep -q 'agent-status.tmux kimi integration' "$KIMI_CODE_HOME/config.toml" || fail "kimi block remained"

# Invalid or ambiguously marked configs fail before any adapter link is made.
tuple_oc="$TMP/tuple-opencode"; mkdir -p "$tuple_oc"; printf '{"plugin":[["./agent-status-tui.js",{"enabled":true}],"keep"]}\n' > "$tuple_oc/tui.jsonc"
OPENCODE_CONFIG_DIR="$tuple_oc" bash "$ROOT/manage-provider.sh" install opencode >/dev/null
[ "$(jq '[.plugin[] | select(. == "./agent-status-tui.js" or (type == "array" and .[0] == "./agent-status-tui.js"))] | length' "$tuple_oc/tui.jsonc")" -eq 1 ] || fail "opencode duplicated tuple plugin entry"
OPENCODE_CONFIG_DIR="$tuple_oc" bash "$ROOT/manage-provider.sh" uninstall opencode >/dev/null
[ "$(jq -r '.plugin[0]' "$tuple_oc/tui.jsonc")" = keep ] || fail "opencode tuple uninstall changed unrelated plugin"

bad_oc="$TMP/bad-opencode"; mkdir -p "$bad_oc"; printf '{ // comment\n}\n' > "$bad_oc/tui.jsonc"
if OPENCODE_CONFIG_DIR="$bad_oc" bash "$ROOT/manage-provider.sh" install opencode >/dev/null 2>&1; then fail "opencode accepted unsupported JSONC"; fi
[ ! -e "$bad_oc/plugins/agent-status.tmux.js" ] && [ ! -e "$bad_oc/agent-status-tui.js" ] || fail "opencode left links after config refusal"
bad_kimi="$TMP/bad-kimi"; mkdir -p "$bad_kimi"; printf 'keep = true\n# >>> agent-status.tmux kimi integration\n' > "$bad_kimi/config.toml"
if KIMI_CODE_HOME="$bad_kimi" bash "$ROOT/manage-provider.sh" install kimi >/dev/null 2>&1; then fail "kimi accepted unmatched markers"; fi
grep -F 'keep = true' "$bad_kimi/config.toml" >/dev/null || fail "kimi damaged refused config"
# An end marker before the begin marker must not let strip delete user lines.
order_kimi="$TMP/order-kimi"; mkdir -p "$order_kimi"
printf 'keep = 1\n# <<< agent-status.tmux kimi integration\nuser = 2\n# >>> agent-status.tmux kimi integration\nmore = 3\n' > "$order_kimi/config.toml"
cp "$order_kimi/config.toml" "$TMP/order-kimi.orig"
for action in install uninstall; do
  if KIMI_CODE_HOME="$order_kimi" bash "$ROOT/manage-provider.sh" "$action" kimi >/dev/null 2>&1; then fail "kimi $action accepted misordered markers"; fi
  cmp -s "$order_kimi/config.toml" "$TMP/order-kimi.orig" || fail "kimi $action changed a misordered config"
done
# Reinstall is byte-stable and uninstall restores the original bytes.
stable_kimi="$TMP/stable-kimi"; mkdir -p "$stable_kimi"; printf 'model = "keep"\n\n[ui]\ntheme = 1\n' > "$stable_kimi/config.toml"
cp "$stable_kimi/config.toml" "$TMP/stable-kimi.orig"
KIMI_CODE_HOME="$stable_kimi" bash "$ROOT/manage-provider.sh" install kimi >/dev/null
cp "$stable_kimi/config.toml" "$TMP/stable-kimi.once"
KIMI_CODE_HOME="$stable_kimi" bash "$ROOT/manage-provider.sh" install kimi >/dev/null
KIMI_CODE_HOME="$stable_kimi" bash "$ROOT/manage-provider.sh" install kimi >/dev/null
cmp -s "$stable_kimi/config.toml" "$TMP/stable-kimi.once" || fail "kimi reinstall is not byte-stable"
KIMI_CODE_HOME="$stable_kimi" bash "$ROOT/manage-provider.sh" uninstall kimi >/dev/null
cmp -s "$stable_kimi/config.toml" "$TMP/stable-kimi.orig" || fail "kimi uninstall did not restore the original config"
bad_mastra="$TMP/bad-mastra"; mkdir -p "$bad_mastra"; printf '[]\n' > "$bad_mastra/hooks.json"
if MASTRACODE_HOME="$bad_mastra" bash "$ROOT/manage-provider.sh" install mastracode >/dev/null 2>&1; then fail "mastra accepted non-object config"; fi

echo user > "$PI_EXTENSIONS_DIR/agent-status.ts"
if bash "$ROOT/manage-provider.sh" install pi >/dev/null 2>&1; then fail "installer overwrote user file"; fi
[ "$(cat "$PI_EXTENSIONS_DIR/agent-status.ts")" = user ] || fail "user file changed"
rm "$PI_EXTENSIONS_DIR/agent-status.ts"
echo victim > "$TMP/victim"
ln -s "$TMP/victim" "$PI_EXTENSIONS_DIR/agent-status.ts"
if bash "$ROOT/manage-provider.sh" install pi >/dev/null 2>&1; then fail "installer followed foreign symlink"; fi
[ "$(cat "$TMP/victim")" = victim ] || fail "foreign symlink target changed"

echo "PASS: provider installers"
