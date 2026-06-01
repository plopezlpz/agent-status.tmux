# Auto-default Navigator Descriptions — Implementation Plan

> **For agentic workers:** execute task-by-task; steps use `- [ ]`.

**Goal:** Show a small auto-default description per navigator card, derived from the session's first prompt, only when there's no Ctrl-E override; regenerated per session.

**Architecture:** New agent-agnostic `auto-desc.sh` writes a transient per-pane `<pane_id>.desc` in the state dir (first prompt only). Navigator falls back to it when the override is empty. Claude hooks + the pi extension call `auto-desc.sh set` on the first prompt and `clear` on a new session. Reuses existing patterns (`$TMUX_PANE`, `@agent-state-dir`, stdin-JSON dual source, atomic write).

**Reference spec:** `docs/superpowers/specs/2026-06-01-auto-descriptions-design.md`

**Verified facts:** Claude `UserPromptSubmit.prompt`; `SessionStart.source ∈ {startup,resume,clear,compact}`; pi `before_agent_start.prompt`; pi `session_start.reason ∈ {startup,reload,new,resume,fork}`.

---

## Task 1: `auto-desc.sh` (TDD)

**Files:** Create `scripts/agent/auto-desc.sh`; Create `tests/test-auto-desc.sh`.

- [ ] **Step 1 — failing test.** Create `tests/test-auto-desc.sh`:

```bash
#!/usr/bin/env bash
# Unit-test auto-desc.sh: cleaning, first-prompt-only, trim, stdin source,
# clear, and the compact guard. Uses a sentinel pane in the resolved state dir.
set -euo pipefail
PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
SCRIPT="$PLUGIN_DIR/scripts/agent/auto-desc.sh"
state_dir="$(tmux show-option -gqv @agent-state-dir 2>/dev/null || true)"
: "${state_dir:=${TMUX_TMPDIR:-/tmp}/agent-status-$(id -u)}"
export TMUX_PANE="%autodesctest$$"
file="$state_dir/$TMUX_PANE.desc"
mkdir -p "$state_dir"
trap 'rm -f "$file"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
rm -f "$file"

bash "$SCRIPT" set "  fix   the login bug  "
[ -f "$file" ] || fail "set did not write"
[ "$(cat "$file")" = "fix the login bug" ] || fail "not cleaned: [$(cat "$file")]"

bash "$SCRIPT" set "a different prompt"
[ "$(cat "$file")" = "fix the login bug" ] || fail "second set overwrote (not first-prompt-only)"

rm -f "$file"
bash "$SCRIPT" set "this is a really long first prompt that should be truncated to about fifty chars ok"
out="$(cat "$file")"
case "$out" in *…) : ;; *) fail "no ellipsis on long input: $out" ;; esac
[ "${#out}" -le 60 ] || fail "too long: $out"

rm -f "$file"
bash "$SCRIPT" set "$(printf 'first line here\nsecond line')"
[ "$(cat "$file")" = "first line here" ] || fail "multi-line not first line: [$(cat "$file")]"

rm -f "$file"
bash "$SCRIPT" set "    "
[ -e "$file" ] && fail "empty input wrote a file"

rm -f "$file"
echo '{"prompt":"from stdin json"}' | bash "$SCRIPT" set
[ "$(cat "$file")" = "from stdin json" ] || fail "stdin .prompt unused: [$(cat "$file" 2>/dev/null)]"

bash "$SCRIPT" clear
[ -e "$file" ] && fail "clear did not remove"

echo "keep me" > "$file"
echo '{"source":"compact"}' | bash "$SCRIPT" clear
[ -f "$file" ] && [ "$(cat "$file")" = "keep me" ] || fail "compact clear should keep the file"

echo "PASS: auto-desc"
```
`chmod +x tests/test-auto-desc.sh`

- [ ] **Step 2 — run, expect fail:** `bash tests/test-auto-desc.sh` → fails (script missing).

- [ ] **Step 3 — implement.** Create `scripts/agent/auto-desc.sh`:

```bash
#!/usr/bin/env bash
# Transient, per-pane auto-default navigator description from the session's
# first prompt. Shown by the navigator only when there's no Ctrl-E override.
# Keyed by $TMUX_PANE (like the state file); no-op outside tmux.
#
#   auto-desc.sh set [text]   # text from arg, else stdin JSON .prompt
#   auto-desc.sh clear        # stdin .source=="compact" -> keep (Claude)
set -eu

[ -z "${TMUX_PANE:-}" ] && exit 0
cmd="${1:-}"

state_dir=$(tmux show-option -gqv @agent-state-dir 2>/dev/null || true)
: "${state_dir:=${TMUX_TMPDIR:-/tmp}/agent-status-$(id -u)}"
file="$state_dir/$TMUX_PANE.desc"

case "$cmd" in
  set)
    raw="${2:-}"
    if [ -z "$raw" ] && [ ! -t 0 ]; then
      raw=$(jq -r '.prompt // ""' 2>/dev/null || true)
    fi
    # First prompt only: never overwrite an existing auto-desc.
    [ -e "$file" ] && exit 0
    line=${raw%%$'\n'*}
    cleaned=$(printf '%s' "$line" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
    [ -z "$cleaned" ] && exit 0
    if [ "${#cleaned}" -gt 50 ]; then
      cleaned="$(printf '%s' "$cleaned" | cut -c1-49)…"
    fi
    mkdir -p "$state_dir"
    tmp="$file.$$"
    printf '%s\n' "$cleaned" > "$tmp" && mv -f "$tmp" "$file"
    ;;
  clear)
    src=""
    [ ! -t 0 ] && src=$(jq -r '.source // ""' 2>/dev/null || true)
    [ "$src" = "compact" ] && exit 0
    rm -f "$file"
    ;;
  *)
    echo "auto-desc: usage: auto-desc.sh set [text] | clear" >&2
    exit 2
    ;;
esac
```
`chmod +x scripts/agent/auto-desc.sh`

- [ ] **Step 4 — run, expect pass:** `bash tests/test-auto-desc.sh` → `PASS: auto-desc`.
- [ ] **Step 5 — commit:** `git add scripts/agent/auto-desc.sh tests/test-auto-desc.sh && git commit` (msg: "feat(desc): add auto-desc.sh for first-prompt navigator labels").

---

## Task 2: navigator fallback + pane cleanup

**Files:** Modify `scripts/agent-sessions.sh`; Modify `scripts/agent/clear-pane.sh`.

- [ ] **Step 1 — navigator fallback.** In `scripts/agent-sessions.sh`, the card loop currently does:

```sh
    descfile="$DESC_DIR/$sess/$win_key/$pane_idx"
    desc=""; [ -f "$descfile" ] && read -r desc < "$descfile" || true
```
Add the auto-default fallback right after:
```sh
    descfile="$DESC_DIR/$sess/$win_key/$pane_idx"
    desc=""; [ -f "$descfile" ] && read -r desc < "$descfile" || true
    if [ -z "$desc" ] && [ -f "$STATE_DIR/$pane_id.desc" ]; then
      read -r desc < "$STATE_DIR/$pane_id.desc" || true
    fi
```

- [ ] **Step 2 — pane cleanup.** In `scripts/agent/clear-pane.sh`, where it removes the state file:
```sh
  rm -f -- "$file"
```
also remove the auto-desc sibling:
```sh
  rm -f -- "$file" "$file.desc"
```

- [ ] **Step 3 — syntax check:** `bash -n scripts/agent-sessions.sh scripts/agent/clear-pane.sh`.
- [ ] **Step 4 — commit:** msg "feat(desc): navigator shows auto-default; clear it on pane exit".

---

## Task 3: Claude hooks (with test)

**Files:** Modify `install-claude-hooks.sh`; Create `tests/test-claude-hooks.sh`.

- [ ] **Step 1 — failing test.** Create `tests/test-claude-hooks.sh`:

```bash
#!/usr/bin/env bash
# Verify install wires auto-desc into SessionStart/UserPromptSubmit, is
# idempotent, and uninstall removes all plugin hooks. Uses a temp settings file.
set -euo pipefail
PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_SETTINGS="$TMP/settings.json"; echo '{}' > "$CLAUDE_SETTINGS"
fail(){ echo "FAIL: $1" >&2; exit 1; }

bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null
jq -e '.hooks.SessionStart[].hooks[].command | select(test("auto-desc.sh clear"))' "$CLAUDE_SETTINGS" >/dev/null || fail "SessionStart missing auto-desc clear"
jq -e '.hooks.UserPromptSubmit[].hooks[].command | select(test("auto-desc.sh set"))' "$CLAUDE_SETTINGS" >/dev/null || fail "UserPromptSubmit missing auto-desc set"
jq -e '.hooks.UserPromptSubmit[].hooks[].command | select(test("set-state.sh working"))' "$CLAUDE_SETTINGS" >/dev/null || fail "UserPromptSubmit lost set-state working"

bash "$PLUGIN_DIR/install-claude-hooks.sh" >/dev/null
n=$(jq '[.. | .command? // empty | select(test("auto-desc.sh set"))] | length' "$CLAUDE_SETTINGS")
[ "$n" -eq 1 ] || fail "auto-desc set duplicated on re-run (n=$n)"

bash "$PLUGIN_DIR/uninstall-claude-hooks.sh" >/dev/null
m=$(jq '[.. | .command? // empty | select(test("agent-status.tmux"))] | length' "$CLAUDE_SETTINGS")
[ "$m" -eq 0 ] || fail "uninstall left $m plugin hooks"

echo "PASS: claude hooks"
```
`chmod +x tests/test-claude-hooks.sh`; run → fails (auto-desc not wired yet).

- [ ] **Step 2 — implement.** In `install-claude-hooks.sh`, extend the SessionStart and UserPromptSubmit lines to include the auto-desc command in the same entry:

```jq
  .hooks.SessionStart      = ((.hooks.SessionStart      // []) | strip) + [{hooks:[{type:"command", command:"\($s)/set-state.sh idle"}, {type:"command", command:"\($s)/auto-desc.sh clear"}]}] |
```
```jq
  .hooks.UserPromptSubmit  = ((.hooks.UserPromptSubmit  // []) | strip) + [{hooks:[{type:"command", command:"\($s)/set-state.sh working"}, {type:"command", command:"\($s)/auto-desc.sh set"}]}] |
```
(Leave the other event lines unchanged. `uninstall-claude-hooks.sh` needs no change — it strips by scripts-dir match.)

- [ ] **Step 3 — run, expect pass:** `bash tests/test-claude-hooks.sh` → `PASS: claude hooks`.
- [ ] **Step 4 — commit:** msg "feat(desc): wire auto-desc into Claude SessionStart + UserPromptSubmit".

---

## Task 4: pi extension (with test)

**Files:** Modify `scripts/pi/agent-status.ts`; Modify `tests/test-extension.ts`.

- [ ] **Step 1 — extend the test.** In `tests/test-extension.ts`, in the in-tmux block, after the existing handler-registration checks add:

```ts
	check(typeof handlers.before_agent_start === "function", "registers before_agent_start");
```
and after `session_start({reason:"startup"})` is dispatched, assert the auto-desc clear fired:
```ts
	check(
		calls.some((c) => c.cmd.endsWith("auto-desc.sh") && c.args[0] === "clear"),
		"session_start (non-reload) -> auto-desc clear",
	);
```
and add a first-prompt check:
```ts
	await handlers.before_agent_start({ prompt: "hello world" });
	const adSet = calls.find((c) => c.cmd.endsWith("auto-desc.sh") && c.args[0] === "set");
	check(!!adSet && adSet.args[1] === "hello world", "before_agent_start -> auto-desc set <prompt>");
```

- [ ] **Step 2 — run, expect fail:** `bun tests/test-extension.ts` → fails (handler/calls missing).

- [ ] **Step 3 — implement.** In `scripts/pi/agent-status.ts`:

Change the `session_start` handler to also clear the auto-desc:
```ts
	pi.on("session_start", async (event) => {
		if (event.reason !== "reload") {
			await set("idle");
			await run("auto-desc.sh", ["clear"]);
		}
	});
```
Add a `before_agent_start` handler (near `agent_start`):
```ts
	pi.on("before_agent_start", async (event) => {
		if (event.prompt) await run("auto-desc.sh", ["set", event.prompt]);
	});
```

- [ ] **Step 4 — run, expect pass:** `bun tests/test-extension.ts` → `PASS: pi extension`.
- [ ] **Step 5 — commit:** msg "feat(desc): pi extension sets/clears auto-desc on prompt/session".

---

## Task 5: docs, runner, final verification

**Files:** Modify `README.md`, `tests/run.sh`.

- [ ] **Step 1 — runner.** In `tests/run.sh`, add the two new bash tests alongside the existing ones:
```bash
bash "$HERE/test-auto-desc.sh" || rc=1
bash "$HERE/test-claude-hooks.sh" || rc=1
```

- [ ] **Step 2 — README.** In the architecture/navigator prose, add a short note:
```markdown
Navigator cards show your Ctrl-E description if set, otherwise an auto-default
derived from the session's first prompt (trimmed to one short line), otherwise a
placeholder. The auto-default is captured on the first prompt and regenerated
each new session; it lives in `<state-dir>/<pane_id>.desc` (transient).
```

- [ ] **Step 3 — full verification:**
```bash
bash tests/run.sh
for f in scripts/agent/auto-desc.sh install-claude-hooks.sh scripts/agent-sessions.sh \
         scripts/agent/clear-pane.sh tests/test-auto-desc.sh tests/test-claude-hooks.sh; do bash -n "$f" && echo "ok: $f"; done
command -v shellcheck >/dev/null 2>&1 && shellcheck scripts/agent/auto-desc.sh tests/test-auto-desc.sh tests/test-claude-hooks.sh || echo "shellcheck skipped"
```
Expected: all `PASS:` lines, `ok:` per script.

- [ ] **Step 4 — live recipe (manual):** start a fresh agent in a pane, `prefix A` → placeholder; send first prompt → card shows the trimmed prompt; Ctrl-E a label → override wins; `/clear` (or new session) → placeholder again until next first prompt.
- [ ] **Step 5 — commit:** msg "docs+test(desc): document auto-default, add tests to runner".

---

## Self-review
- Spec coverage: source=first-prompt (T1), override>auto>none (T2 navigator), per-session regen (T3/T4 clear), first-prompt-only (T1 existence check), compact/reload guards (T1 + T4), pane cleanup (T2), docs (T5). ✓
- Placeholders: none. ✓
- Name consistency: `<pane_id>.desc` in state dir used identically by writer (T1), navigator (T2), cleanup (T2); `auto-desc.sh set|clear` identical across T1/T3/T4. ✓
