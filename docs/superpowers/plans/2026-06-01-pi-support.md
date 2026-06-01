# pi Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `agent-status.tmux` drive per-pane status, the window icon, notifications, and the navigator for `pi` (the `@earendil-works/pi-coding-agent` terminal agent), reusing the existing agent-agnostic tmux state engine.

**Architecture:** Add a second adapter alongside the Claude one. A single auto-discovered pi TypeScript extension maps pi lifecycle events to the existing `set-state.sh`/`clear-state.sh` scripts via `pi.exec`. The tmux entrypoint advertises its scripts directory as a tmux option (`@agent-scripts-dir`) so the extension finds the scripts with no baked paths. A symlink installer mirrors `install-claude-hooks.sh`. The engine, the Claude installer, and the state-file format are untouched.

**Tech Stack:** bash, tmux (3.3+), pi extensions API (TypeScript, `pi.exec`, `pi.on`), shellcheck.

**Reference spec:** `docs/superpowers/specs/2026-06-01-pi-support-design.md`

---

## File structure

| File | Responsibility | Action |
|---|---|---|
| `agent-status.tmux` | tmux entrypoint; advertise `@agent-scripts-dir` | Modify (+1 line); relabel binding |
| `scripts/pi/agent-status.ts` | pi adapter: events → state scripts | Create |
| `install-pi-extension.sh` | symlink adapter into `~/.pi/agent/extensions/` | Create |
| `uninstall-pi-extension.sh` | remove our symlink only | Create |
| `scripts/agent-sessions.sh` | navigator; drop "Claude" from label comment | Modify (cosmetic) |
| `README.md` | multi-agent framing + pi install + requirements + asking note | Modify |
| `tests/test-engine-option.sh` | assert `@agent-scripts-dir` is advertised | Create |
| `tests/test-installer.sh` | assert install/uninstall symlink behavior | Create |

---

## Task 1: Engine advertises the scripts directory

**Files:**
- Modify: `agent-status.tmux` (after `SCRIPTS` is defined / with the other `set-option -gqo` defaults)
- Test: `tests/test-engine-option.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test-engine-option.sh`:

```bash
#!/usr/bin/env bash
# Verify the tmux entrypoint advertises @agent-scripts-dir pointing at the
# directory that holds the state scripts. Runs against a throwaway tmux
# socket so the user's real server is never touched.
set -euo pipefail

PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
SOCK="agent-status-test-$$"

command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }

cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; }
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

tmux -L "$SOCK" new-session -d -s t -x 80 -y 24
# run-shell executes with $TMUX pointing at this test server, so the bare
# `tmux` calls inside the entrypoint target the test server, not the default.
tmux -L "$SOCK" run-shell "$PLUGIN_DIR/agent-status.tmux" 2>/dev/null || true

dir="$(tmux -L "$SOCK" show-option -gqv @agent-scripts-dir 2>/dev/null || true)"

[ -n "$dir" ] || fail "@agent-scripts-dir not set"
[ -x "$dir/set-state.sh" ] || fail "@agent-scripts-dir ($dir) has no executable set-state.sh"
echo "PASS: engine advertises @agent-scripts-dir ($dir)"
```

Make it executable: `chmod +x tests/test-engine-option.sh`

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-engine-option.sh`
Expected: `FAIL: @agent-scripts-dir not set` (the option does not exist yet).

- [ ] **Step 3: Add the advertisement line**

In `agent-status.tmux`, in the defaults block (alongside the other
`tmux set-option -gqo @agent-...` lines, after `SCRIPTS="$CURRENT_DIR/scripts"`
is in scope), add:

```sh
# Advertise where the per-pane state scripts live so agent adapters (e.g. the
# pi extension) can locate set-state.sh/clear-state.sh without a baked path.
tmux set-option -gqo @agent-scripts-dir "$SCRIPTS/agent"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-engine-option.sh`
Expected: `PASS: engine advertises @agent-scripts-dir (.../scripts/agent)`

- [ ] **Step 5: Relabel the binding (drop "Claude")**

In `agent-status.tmux`, change the navigator binding description:

```sh
tmux bind -N "agent navigator" "$nav_key" \
```

(was `-N "Claude agent navigator"`).

- [ ] **Step 6: Syntax check + commit**

```bash
bash -n agent-status.tmux
git add agent-status.tmux tests/test-engine-option.sh
git commit -m "feat(engine): advertise @agent-scripts-dir for agent adapters"
```

---

## Task 2: pi adapter extension

**Files:**
- Create: `scripts/pi/agent-status.ts`

> No unit test: the extension is a type-erased TypeScript module that only runs inside pi's runtime (no JS/TS harness exists in this bash plugin, and adding one for ~40 lines is YAGNI). It is exercised by `tests/test-installer.sh` (Task 3, symlink target) and the live recipe (Task 5). Keep it dead-simple and defensive so a status hiccup can never disrupt the agent.

- [ ] **Step 1: Create the extension**

Create `scripts/pi/agent-status.ts`:

```ts
/**
 * agent-status.tmux — pi adapter.
 *
 * Maps pi lifecycle events to the plugin's per-pane tmux state scripts so pi
 * panes get the same window icon, notifications, and navigator cards as Claude
 * Code panes. Reuses set-state.sh / clear-state.sh (single source of truth);
 * this file only translates events to state names. No-op outside tmux.
 *
 * Install via ../../install-pi-extension.sh (symlinks this into
 * ~/.pi/agent/extensions/).
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	// set-state.sh keys state by $TMUX_PANE; nothing to do outside tmux.
	if (!process.env.TMUX_PANE) return;

	// Resolve the state-scripts dir once. The tmux entrypoint advertises it as
	// @agent-scripts-dir, so we avoid baked paths and stay symlink/update-safe.
	// Fall back to the conventional TPM install path if the option is unset.
	let scriptsDir: string | undefined;
	const resolveDir = async (): Promise<string> => {
		if (scriptsDir === undefined) {
			let opt = "";
			try {
				const { stdout } = await pi.exec("tmux", ["show-option", "-gqv", "@agent-scripts-dir"]);
				opt = stdout.trim();
			} catch {
				// tmux missing/unreadable — fall through to the default.
			}
			scriptsDir = opt || `${process.env.HOME}/.tmux/plugins/agent-status.tmux/scripts/agent`;
		}
		return scriptsDir;
	};

	const run = async (script: string, args: string[]): Promise<void> => {
		try {
			await pi.exec(`${await resolveDir()}/${script}`, args);
		} catch {
			// A status update must never disrupt the agent.
		}
	};

	const set = (state: string) => run("set-state.sh", [state]);

	// session_start fires on startup/new/resume/fork (reset to idle) and on
	// reload (extension hot-reload — keep current state, don't reset mid-work).
	pi.on("session_start", async (event) => {
		if (event.reason !== "reload") await set("idle");
	});

	pi.on("agent_start", async () => {
		await set("working");
	});

	pi.on("agent_end", async () => {
		await set("finished");
	});

	// session_shutdown fires on real quit AND on session replacement
	// (new/resume/fork) and reload. Only a real quit should clear state — the
	// others keep the pane registered (session_start re-idles it). A truly
	// closed pane is cleaned up by the tmux pane-exited hook.
	pi.on("session_shutdown", async (event) => {
		if (event.reason === "quit") await run("clear-state.sh", []);
	});
}
```

- [ ] **Step 2: Sanity-check formatting**

Run: `test -f scripts/pi/agent-status.ts && grep -c 'pi.on(' scripts/pi/agent-status.ts`
Expected: `4` (four lifecycle handlers).

- [ ] **Step 3: Commit**

```bash
git add scripts/pi/agent-status.ts
git commit -m "feat(pi): add pi lifecycle adapter extension"
```

---

## Task 3: Install / uninstall scripts (TDD)

**Files:**
- Create: `install-pi-extension.sh`
- Create: `uninstall-pi-extension.sh`
- Test: `tests/test-installer.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test-installer.sh`:

```bash
#!/usr/bin/env bash
# Install/uninstall the pi extension into a throwaway extensions dir and assert
# symlink creation, idempotency, and that uninstall never clobbers a file that
# isn't our symlink.
set -euo pipefail

PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
EXT_SRC="$PLUGIN_DIR/scripts/pi/agent-status.ts"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export PI_EXTENSIONS_DIR="$TMP/extensions"
LINK="$PI_EXTENSIONS_DIR/agent-status.ts"

fail() { echo "FAIL: $1" >&2; exit 1; }

# install creates a symlink to the shipped extension
bash "$PLUGIN_DIR/install-pi-extension.sh" >/dev/null
[ -L "$LINK" ] || fail "symlink not created"
[ "$(readlink "$LINK")" = "$EXT_SRC" ] || fail "wrong target: $(readlink "$LINK")"

# install is idempotent
bash "$PLUGIN_DIR/install-pi-extension.sh" >/dev/null
[ -L "$LINK" ] || fail "symlink missing after re-install"
[ "$(readlink "$LINK")" = "$EXT_SRC" ] || fail "target changed after re-install"

# uninstall removes our symlink
bash "$PLUGIN_DIR/uninstall-pi-extension.sh" >/dev/null
[ -e "$LINK" ] && fail "symlink not removed by uninstall"

# uninstall must NOT touch an unrelated, same-named regular file
echo "not ours" > "$LINK"
bash "$PLUGIN_DIR/uninstall-pi-extension.sh" >/dev/null
[ -f "$LINK" ] || fail "uninstall removed an unrelated file"
[ "$(cat "$LINK")" = "not ours" ] || fail "uninstall modified an unrelated file"

echo "PASS: pi installer"
```

Make it executable: `chmod +x tests/test-installer.sh`

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-installer.sh`
Expected: failure — `install-pi-extension.sh` does not exist yet (bash: No such file).

- [ ] **Step 3: Write the installer**

Create `install-pi-extension.sh`:

```bash
#!/usr/bin/env bash
# Symlink the pi status extension into pi's extensions directory.
#
# Idempotent: re-running refreshes the symlink. Plugin updates (e.g. a TPM
# update pulling new commits) propagate automatically through the link.
set -eu

PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SRC="$PLUGIN_DIR/scripts/pi/agent-status.ts"
EXT_DIR="${PI_EXTENSIONS_DIR:-$HOME/.pi/agent/extensions}"
DEST="$EXT_DIR/agent-status.ts"

[ -f "$SRC" ] || { echo "agent-status: extension not found at $SRC" >&2; exit 1; }

mkdir -p "$EXT_DIR"
ln -sfn "$SRC" "$DEST"

echo "agent-status: pi extension linked: $DEST -> $SRC"
echo "agent-status: restart pi (or run /reload in a session) to activate."
```

Make it executable: `chmod +x install-pi-extension.sh`

- [ ] **Step 4: Write the uninstaller**

Create `uninstall-pi-extension.sh`:

```bash
#!/usr/bin/env bash
# Remove the pi status extension symlink -- but only if it is our symlink.
# Never touches an unrelated file that happens to share the name.
set -eu

PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SRC="$PLUGIN_DIR/scripts/pi/agent-status.ts"
EXT_DIR="${PI_EXTENSIONS_DIR:-$HOME/.pi/agent/extensions}"
DEST="$EXT_DIR/agent-status.ts"

if [ -L "$DEST" ] && [ "$(readlink "$DEST")" = "$SRC" ]; then
  rm -f "$DEST"
  echo "agent-status: pi extension unlinked: $DEST"
else
  echo "agent-status: no pi extension symlink of ours at $DEST; nothing removed."
fi
```

Make it executable: `chmod +x uninstall-pi-extension.sh`

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-installer.sh`
Expected: `PASS: pi installer`

- [ ] **Step 6: shellcheck + commit**

```bash
shellcheck install-pi-extension.sh uninstall-pi-extension.sh tests/test-installer.sh
git add install-pi-extension.sh uninstall-pi-extension.sh tests/test-installer.sh
git commit -m "feat(pi): add symlink install/uninstall scripts with tests"
```

(If `shellcheck` is not installed, skip it: `command -v shellcheck` first.)

---

## Task 4: Documentation

**Files:**
- Modify: `README.md`
- Modify: `scripts/agent-sessions.sh` (comment only)

- [ ] **Step 1: Generalize the intro**

In `README.md`, replace the opening line:

```markdown
Live status indicators and a navigator popup for AI coding agent panes
([Claude Code] and [pi]) in tmux.
```

(was `for [Claude Code] panes`).

- [ ] **Step 2: Add the pi install subsection**

In `README.md`, immediately after the Claude Code hook-wiring block (the
`bash ~/.tmux/plugins/agent-status.tmux/install-claude-hooks.sh` step) and
before the `window-status-format` step, add:

````markdown
### pi (optional)

For [pi] panes, symlink the extension into pi's extensions directory (one time,
idempotent):

```bash
bash ~/.tmux/plugins/agent-status.tmux/install-pi-extension.sh
```

Restart `pi` (or run `/reload` in a running session) to activate it. pi panes
show **working / finished / idle**. pi runs without permission prompts by
default, so there is no **asking** state out of the box. If you run a
permission-gate extension, emit it yourself around the prompt:

```ts
const dir = (await pi.exec("tmux", ["show-option", "-gqv", "@agent-scripts-dir"])).stdout.trim();
await pi.exec(`${dir}/set-state.sh`, ["asking"]);   // before ctx.ui.confirm(...)
await pi.exec(`${dir}/set-state.sh`, ["working"]);  // after it returns
```
````

- [ ] **Step 3: Add the pi requirements row**

In `README.md`, in the Requirements table, add a row after the Claude Code row:

```markdown
| pi | 0.78 | optional; uses `session_start` / `agent_start` / `agent_end` / `session_shutdown` |
```

- [ ] **Step 4: Document `@agent-scripts-dir` in the Paths table**

In `README.md`, in the Paths table, add:

```markdown
| `@agent-scripts-dir` | `<plugin>/scripts/agent` | where adapters find the state scripts; set by the plugin, read by the pi extension |
```

- [ ] **Step 5: Note pi in the Architecture section**

In `README.md`, after the architecture diagram / its surrounding prose, add:

```markdown
**pi** is driven instead by an auto-discovered TypeScript extension
(`scripts/pi/agent-status.ts`, symlinked by `install-pi-extension.sh`). It maps
pi's `session_start` / `agent_start` / `agent_end` / `session_shutdown` events
to the same `set-state.sh` / `clear-state.sh`, so everything downstream (icon,
notifications, navigator) is shared. It clears state only on a real `quit`
(reason guard), keeping the pane registered through `/new`, `/resume`, `/fork`,
and `/reload`.
```

- [ ] **Step 6: Add the pi link reference**

In `README.md`, near the existing `[Claude Code]:` and `[TPM]:` link
definitions at the bottom, add:

```markdown
[pi]: https://github.com/earendil-works/pi
```

- [ ] **Step 7: Drop "Claude" from the navigator comment**

In `scripts/agent-sessions.sh`, line 2, change the header comment:

```sh
# Agent-instance navigator. One card per pane that has registered
```

(was `# Claude agent-instance navigator.`).

- [ ] **Step 8: Commit**

```bash
git add README.md scripts/agent-sessions.sh
git commit -m "docs: document pi support and generalize wording"
```

---

## Task 5: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

```bash
bash tests/test-engine-option.sh
bash tests/test-installer.sh
```
Expected: two `PASS:` lines (or `SKIP: tmux not installed` for the first if run without tmux).

- [ ] **Step 2: Syntax-check every shell script touched/added**

```bash
for f in agent-status.tmux install-pi-extension.sh uninstall-pi-extension.sh \
         scripts/agent-sessions.sh tests/test-engine-option.sh tests/test-installer.sh; do
  bash -n "$f" && echo "ok: $f"
done
command -v shellcheck >/dev/null 2>&1 && shellcheck install-pi-extension.sh uninstall-pi-extension.sh tests/*.sh || echo "shellcheck: skipped"
```
Expected: an `ok:` line per script; shellcheck clean (or skipped).

- [ ] **Step 3: Live smoke test (manual, documented for the reviewer/user)**

In a tmux pane:
1. `bash install-pi-extension.sh` then start `pi`.
2. Confirm the window icon shows **idle** at the pi prompt.
3. Submit a prompt → icon flips to **working**; when pi finishes → **finished**;
   focus the pane → demotes to **idle**.
4. `prefix A` → the pi pane appears as a navigator card.
5. `/new` in pi → the card/icon persists (state kept). Quit pi (Ctrl+D) → state
   clears.
6. Tail `~/.local/share/tmux/agent-status/agent.log` to watch transitions.

(Cannot be automated here — pi requires interactive auth + a live LLM. This
step is the acceptance check.)

- [ ] **Step 4: Final commit if any fixups were needed**

```bash
git add -A && git commit -m "test: pi support verification fixups" || echo "nothing to fix up"
```

---

## Self-review

**Spec coverage:**
- Adapter + state mapping → Task 2. ✓
- `@agent-scripts-dir` advertisement → Task 1. ✓
- `session_shutdown` quit-only clear + `session_start` reload guard → Task 2 (handlers) + Task 1 (test of option). ✓
- Symlink install/uninstall, idempotent, `PI_EXTENSIONS_DIR` override, don't-clobber → Task 3. ✓
- README multi-agent framing, pi install, requirements row, asking escape hatch, `@agent-scripts-dir` doc → Task 4. ✓
- Cosmetic relabel ("Claude agent navigator" / navigator comment) → Task 1 Step 5 + Task 4 Step 7. ✓
- Testing plan (static, installer behavior, engine wiring, live recipe) → Tasks 1, 3, 5. ✓
- Out-of-scope items (provider restructure, gate extension, per-turn, rich messages) → not present. ✓

**Placeholder scan:** none — every code/step is concrete.

**Type/name consistency:** `@agent-scripts-dir` (Task 1) == read in Task 2 == documented in Task 4. `scripts/pi/agent-status.ts` consistent across Tasks 2/3/4. `PI_EXTENSIONS_DIR` + `DEST`/`SRC` consistent across installer, uninstaller, and test. `set-state.sh`/`clear-state.sh` names match the existing engine.
