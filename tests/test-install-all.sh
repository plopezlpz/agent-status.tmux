#!/usr/bin/env bash
# manage-provider.sh without a provider: installs the adapters of the agents
# found on this machine, skips the others, and never creates a config home
# (Claude's included) for an agent that isn't there.
set -euo pipefail
ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: install all (jq missing)"; exit 0; }
unset PI_EXTENSIONS_DIR PI_CODING_AGENT_DIR PI_CONFIG_DIR OMP_EXTENSIONS_DIR OPENCODE_CONFIG_DIR \
  KILO_CONFIG_DIR KIMI_CODE_HOME MASTRACODE_HOME CLAUDE_SETTINGS CLAUDE_CONFIG_DIR CODEX_HOME XDG_CONFIG_HOME

# Only Kilo, Claude and Codex are installed.
export HOME="$TMP/home"; mkdir -p "$HOME/.config/kilo" "$HOME/.claude" "$HOME/.codex"
bash "$ROOT/manage-provider.sh" install >/dev/null 2>&1 || fail "install all failed"
[ -L "$HOME/.config/kilo/plugin/agent-status.tmux.js" ] || fail "kilo adapter not installed"
grep -qF "$ROOT/" "$HOME/.claude/settings.json" || fail "claude hooks not installed"
grep -qF "$ROOT/" "$HOME/.codex/hooks.json" || fail "codex hooks not installed"
for d in .pi .omp .config/opencode .kimi-code .mastracode; do
  [ ! -e "$HOME/$d" ] || fail "created $d for an agent that isn't installed"
done
hooks() { cat "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json" | grep -oF "$ROOT/" | wc -l; }
before=$(hooks)
bash "$ROOT/manage-provider.sh" install >/dev/null 2>&1 || fail "a second install all failed"
[ "$(hooks)" -eq "$before" ] || fail "a second install all duplicated the claude or codex hooks"

bash "$ROOT/manage-provider.sh" uninstall >/dev/null 2>&1 || fail "uninstall all failed"
[ ! -e "$HOME/.config/kilo/plugin/agent-status.tmux.js" ] || fail "kilo adapter not removed"
! grep -qF "$ROOT/" "$HOME/.claude/settings.json" || fail "claude hooks not removed"
! grep -qF "$ROOT/" "$HOME/.codex/hooks.json" || fail "codex hooks not removed"

# Without ~/.claude, Claude is skipped and nothing is created for it.
export HOME="$TMP/home2"; mkdir -p "$HOME"
bash "$ROOT/manage-provider.sh" install >/dev/null 2>&1 || fail "install all with no agents failed"
[ ! -e "$HOME/.claude" ] || fail "created ~/.claude for a machine without Claude"
[ ! -e "$HOME/.codex" ] || fail "created ~/.codex for a machine without Codex"
# Claude with its config moved (CLAUDE_CONFIG_DIR) is found there.
mkdir "$TMP/claude-config"
CLAUDE_CONFIG_DIR="$TMP/claude-config" bash "$ROOT/manage-provider.sh" found claude || fail "Claude under CLAUDE_CONFIG_DIR not found"

# Nothing found: says so, and changes nothing.
out=$(bash "$ROOT/manage-provider.sh" install </dev/null 2>&1) || fail "install all with nothing found failed"
case "$out" in *"no supported agent found"*) ;; *) fail "nothing found, but it said: $out" ;; esac
bash "$ROOT/manage-provider.sh" found kilo && fail "found kilo on a machine without it"

# The wizard: in a terminal, it lists what it found and asks first.
if command -v tmux >/dev/null 2>&1; then
  SOCK="agent-status-wizard-$$"
  trap 'tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$TMP"' EXIT
  export HOME="$TMP/home3"; mkdir -p "$HOME/.config/kilo"
  wizard() { # wizard ANSWER: run install in a tmux pane and answer its question
    rm -f "$TMP/w.out"
    tmux -L "$SOCK" -f /dev/null new-session -d -x 120 -y 20 \
      "env HOME='$HOME' bash '$ROOT/manage-provider.sh' install; echo \$? > '$TMP/w.out'; sleep 30"
    for _ in $(seq 50); do
      tmux -L "$SOCK" capture-pane -p | grep -q 'Hook them up?' && break; sleep 0.1
    done
    tmux -L "$SOCK" capture-pane -p | grep -q 'found kilo\.' || fail "the wizard did not list kilo"
    tmux -L "$SOCK" send-keys "$1" Enter
    for _ in $(seq 50); do [ -s "$TMP/w.out" ] && break; sleep 0.1; done
    [ "$(cat "$TMP/w.out" 2>/dev/null)" = 0 ] || fail "the wizard exited with $(cat "$TMP/w.out" 2>/dev/null)"
    tmux -L "$SOCK" kill-server 2>/dev/null || true
  }
  wizard n
  [ ! -e "$HOME/.config/kilo/plugin/agent-status.tmux.js" ] || fail "answering n still installed"
  wizard y
  [ -L "$HOME/.config/kilo/plugin/agent-status.tmux.js" ] || fail "answering y did not install"
fi

# Still one provider at a time, and a bad action is refused.
rc=0; bash "$ROOT/manage-provider.sh" install nope >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "an unknown provider was not refused"
rc=0; bash "$ROOT/manage-provider.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "no action was not refused"
echo "PASS: install/uninstall every agent found"
