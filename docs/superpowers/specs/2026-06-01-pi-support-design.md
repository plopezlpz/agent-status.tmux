# Design: pi support for agent-status.tmux

**Date:** 2026-06-01
**Status:** Approved
**Topic:** Extend the plugin so it also drives status/notifications for `pi`
(the `@earendil-works/pi-coding-agent` terminal coding agent), not just Claude
Code.

## Problem

`agent-status.tmux` today shows per-pane agent state (working / asking /
finished / idle), an aggregated window icon, clickable notifications, and an
fzf navigator. All of this is driven by **Claude Code hooks** wired into
`~/.claude/settings.json` by `install-claude-hooks.sh`.

We want the same experience for `pi`. `pi` is a lean, extensible terminal
coding agent. Its extension model is **in-process TypeScript modules**
auto-discovered from `~/.pi/agent/extensions/*.ts` (no build step), not
external shell-command hooks.

## Key insight: the engine is already agent-agnostic

The plugin has two layers:

1. **tmux/state engine** (`scripts/agent/*.sh`, `scripts/agent-sessions.sh`,
   `agent-status.tmux`): reads/writes per-pane state files keyed by
   `$TMUX_PANE`, aggregates the worst-state window icon, sends notifications,
   renders the navigator. **Nothing here knows what Claude is.** It only cares
   about the four state strings.
2. **Claude adapter** (`install-claude-hooks.sh` / `uninstall-claude-hooks.sh`):
   the only Claude-coupled piece. It `jq`-edits `settings.json` to map Claude
   hook events to `set-state.sh <state>`.

Supporting `pi` therefore means adding a **second adapter**. The engine is
reused unchanged.

## Decisions (locked during brainstorming)

1. **Refactor scope — minimal adapter alongside.** Leave the engine and the
   Claude installer untouched. Add a parallel pi adapter. Generalize only docs
   and the one "Claude agent navigator" label. No provider-dir restructure
   (YAGNI; the "agent" naming is already neutral, and churning proven code adds
   regression risk for no functional gain).
2. **`asking` state — map only native states; document the escape hatch.** `pi`
   runs in "full YOLO mode" by default: no permission prompts, hence no event
   equivalent to Claude's `PermissionRequest`. pi panes show
   idle / working / finished. The README documents that a user's own
   permission-gate extension can emit `asking` by calling the state script. No
   fragile heuristics.
3. **Distribution — symlink installer.** `install-pi-extension.sh` symlinks the
   shipped `.ts` into `~/.pi/agent/extensions/`. Idempotent and re-runnable,
   mirroring `install-claude-hooks.sh`. Plugin updates (TPM) propagate through
   the symlink automatically. One command, no per-user file editing.

## pi lifecycle → state mapping

`pi`'s event model (verified against `@earendil-works/pi-coding-agent` v0.78.0
`docs/extensions.md`):

```
session_start    (reason: startup|reload|new|resume|fork)
agent_start / agent_end   (once per user prompt)
turn_start / turn_end     (per LLM response within a prompt)
tool_execution_start/end, tool_call, ...
session_shutdown (reason: quit|reload|new|resume|fork)
```

Adapter mapping:

| pi event | guard | engine call |
|---|---|---|
| `session_start` | `reason !== "reload"` | `set-state.sh idle` |
| `agent_start` | — | `set-state.sh working` |
| `agent_end` | — | `set-state.sh finished` |
| `session_shutdown` | `reason === "quit"` | `clear-state.sh` (else: keep) |

Rationale:

- `agent_start`/`agent_end` (once per user prompt) is the right altitude for
  working/finished. Per-turn events would flicker; YAGNI.
- The `session_shutdown` reason guard is the crux of correctness. `pi` fires
  `session_shutdown` not only on real quit but also on `/new`, `/resume`,
  `/fork` (session replacement, immediately followed by `session_start`) and
  `/reload` (extension hot-reload). Clearing on those reproduces the
  navigation-vanish bug already fixed for Claude in `clear-state.sh`. We clear
  **only** on `reason === "quit"`. A genuinely closed pane is still cleaned up
  by the existing tmux `pane-exited` hook.
- The `session_start` `reason !== "reload"` guard means a mid-session `/reload`
  doesn't reset a working/finished pane back to idle.

## Components

### New: `scripts/pi/agent-status.ts` (the adapter)

A single auto-discoverable extension. Shape:

```ts
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  // no-op outside tmux
  if (!process.env.TMUX_PANE) return;

  let scriptsDir: string | undefined;
  async function dir(): Promise<string> {
    if (scriptsDir === undefined) {
      const { stdout } = await pi.exec("tmux",
        ["show-option", "-gqv", "@agent-scripts-dir"]);
      scriptsDir = stdout.trim() ||
        `${process.env.HOME}/.tmux/plugins/agent-status.tmux/scripts/agent`;
    }
    return scriptsDir;
  }
  const set = async (state: string) =>
    pi.exec(`${await dir()}/set-state.sh`, [state]);

  pi.on("session_start", async (e) => {
    if (e.reason !== "reload") await set("idle");
  });
  pi.on("agent_start", async () => { await set("working"); });
  pi.on("agent_end",   async () => { await set("finished"); });
  pi.on("session_shutdown", async (e) => {
    if (e.reason === "quit") await pi.exec(`${await dir()}/clear-state.sh`, []);
  });
}
```

Notes:

- **Path discovery via tmux option**, not `import.meta`/symlink-realpath
  (fragile if pi bundles/transpiles) and not a baked path (would break the
  symlink + auto-update property). The tmux server is the single source of
  truth for where the scripts live — correct, since the whole system only works
  inside tmux anyway. Cached after first lookup. Falls back to the conventional
  TPM path if the option is unset (old plugin / not loaded).
- **`pi.exec`** is pi's documented external-command runner (returns
  `{ stdout, code }`). Spawned children inherit pi's env, including
  `TMUX_PANE`, so `set-state.sh`/`clear-state.sh` resolve the right pane with
  no extra plumbing.
- `import type` is erased at transpile time, so the import never affects
  runtime; it only powers editor type-checking when the user has pi installed.
- `clear-state.sh` run with no stdin treats it as a real clear (deletes the
  state file) — exactly what we want on `quit`.

### New: `install-pi-extension.sh` / `uninstall-pi-extension.sh`

- Install: resolve `PLUGIN_DIR` from the script location; ensure
  `~/.pi/agent/extensions/` exists; create/refresh a symlink
  `agent-status.ts -> $PLUGIN_DIR/scripts/pi/agent-status.ts`. Idempotent
  (`ln -sfn`). Print where it linked and remind to `/reload` or restart pi.
- Uninstall: remove the symlink only if it points at this plugin (don't clobber
  an unrelated file of the same name). Print result.
- Honors `PI_EXTENSIONS_DIR` override (defaults to `~/.pi/agent/extensions`),
  paralleling `CLAUDE_SETTINGS` in the Claude installer.

### Modified: `agent-status.tmux` (+1 line)

After computing `SCRIPTS`, advertise the scripts dir so adapters can find it:

```sh
tmux set-option -gqo @agent-scripts-dir "$SCRIPTS/agent"
```

### Modified: `README.md`

- Reframe the intro from "Claude Code panes" to "agent panes (Claude Code, pi,
  ...)".
- Add a "pi" install subsection (`install-pi-extension.sh`, `/reload`).
- Add a requirements row for pi.
- Document the `asking` escape hatch for pi gate extensions.

### Modified: `scripts/agent-sessions.sh`

- Relabel the binding description `"Claude agent navigator"` →
  `"agent navigator"`. Cosmetic only.

## Data flow

```
pi (in tmux pane)
  └─ agent-status.ts  (pi.on lifecycle event)
        └─ pi.exec set-state.sh <state>     [TMUX_PANE inherited]
              └─ writes <state-dir>/<pane_id>
              └─ notify (asking/finished) + log
              └─ update-window-icon.sh  →  @agent-icon  →  status line
```

Identical to the Claude path from `set-state.sh` onward — the adapter is the
only new link.

## Error handling / edge cases

| Case | Behavior |
|---|---|
| pi not running in tmux | adapter returns immediately (no `TMUX_PANE`) |
| `@agent-scripts-dir` unset (old/absent plugin) | fall back to conventional TPM path |
| `/new`, `/resume`, `/fork` | `session_shutdown` kept; following `session_start` sets idle |
| `/reload` | state preserved (both shutdown and start are no-ops) |
| real `quit` (pane stays alive) | state cleared → no stale icon |
| pane actually closed | existing `pane-exited` hook clears it |
| `asking` under pi | not emitted by default; documented escape hatch |

## Testing

This is a bash + tmux plugin with no JS test harness. Adding one for a ~40-line
type-erased extension is YAGNI. Verification plan:

1. **Static:** `bash -n` + `shellcheck` on the new shell scripts (same bar as
   the v0.2.3 verification).
2. **Installer behavior (concrete):** run `install-pi-extension.sh` against a
   temp `PI_EXTENSIONS_DIR`, assert the symlink exists and resolves to the
   shipped `.ts`; re-run to confirm idempotency; run `uninstall-pi-extension.sh`
   and assert removal; assert it leaves an unrelated same-named file untouched.
3. **Engine wiring:** assert `agent-status.tmux` sets `@agent-scripts-dir` to an
   existing directory containing `set-state.sh`.
4. **Live (manual recipe in README/PR):** run `pi` in a tmux pane, watch
   `agent.log` and the window icon cycle idle → working → finished, and confirm
   `/clear`-equivalent (`/new`) keeps the navigator card while `quit` clears it.

## Out of scope (YAGNI)

- Provider-directory restructure / renaming the engine scripts.
- A companion permission-gate extension.
- Per-turn (`turn_start`/`turn_end`) state granularity.
- Passing rich notification messages from pi (the `set-state.sh` `#S / #W`
  fallback is sufficient).
```
