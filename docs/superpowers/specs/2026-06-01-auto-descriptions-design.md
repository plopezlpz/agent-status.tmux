# Design: auto-default navigator descriptions

**Date:** 2026-06-01
**Status:** Approved
**Topic:** Give each navigator card a sensible default description, derived from
the session's first prompt, used only when the user hasn't set one with Ctrl-E.

## Problem

The `prefix A` navigator shows one card per agent pane. Each card's description
is currently either a user-set string (Ctrl-E) or the placeholder
`(no description — Ctrl-E to add one)`. With several panes, unlabeled cards are
hard to tell apart. We want a small, automatic default label so cards are
meaningful without manual effort — while preserving any Ctrl-E override.

## Decisions (locked during brainstorming)

1. **Source = truncated first prompt.** Both agents expose the first prompt
   text cheaply and identically (Claude `UserPromptSubmit.prompt`; pi
   `before_agent_start` `event.prompt`). Neither offers a free auto-title
   (pi's `getSessionName()` is empty unless set; Claude's `/resume` summary
   isn't exposed to hooks at first-prompt time). AI-generated titles were
   rejected as asymmetric and costly. So: take the first prompt, clean to one
   line, trim to ~50 chars.
2. **Ctrl-E overrides persist per pane** (today's behavior). The auto-default
   only fills the gap when there is no override.
3. **Per-session, first-prompt-only.** A brand-new session shows the
   placeholder until the first prompt. The auto-default is captured on the
   first prompt and regenerated when a genuinely new conversation starts.

## Resolution precedence (at render time, in the navigator)

```
Ctrl-E override (non-empty)  →  auto-default (if any)  →  "(no description …)"
```

## Storage — two layers, two lifetimes

| Layer | Path | Keyed by | Lifetime |
|---|---|---|---|
| Override (Ctrl-E) | `$DESC_DIR/<sess>/<win_key>/<pane_idx>` | human-stable ids | persistent (unchanged) |
| Auto-default | `$STATE_DIR/<pane_id>.desc` | pane id | transient (dies with pane / session) |

Keying the auto-default by `pane_id` (like the state file) means the writer only
needs `$TMUX_PANE` — no window-key computation — and **the writer never checks
for an override**: it always records the auto-default; the navigator simply
ignores it when an override exists. (Nice side effect: clearing a Ctrl-E label
later reveals the captured auto-default.)

## Components

### New: `scripts/agent/auto-desc.sh`

Agent-agnostic, no-op outside tmux (keys off `$TMUX_PANE`), resolves
`$STATE_DIR` from `@agent-state-dir` with the same fallback as `set-state.sh`.

- `auto-desc.sh set [text]` — resolve text from `$2`, else stdin JSON `.prompt`
  (the dual-source trick `set-state.sh` already uses for `.message`). Take the
  first line, collapse whitespace, trim. Skip if empty. Trim to 50 chars,
  appending `…` when cut. **Write only if `$STATE_DIR/$TMUX_PANE.desc` does not
  already exist** (captures the *first* prompt of the session, not every
  prompt). Atomic write (`tmp` + `mv`), matching `set-state.sh`.
- `auto-desc.sh clear` — read `.source` from stdin if present; if it equals
  `compact`, exit without removing (don't reset the label on Claude
  compaction). Otherwise `rm -f` the `.desc` file.

### Modified: `scripts/agent-sessions.sh` (navigator)

In card building, after reading the override file, add one fallback: if the
override is empty and `$STATE_DIR/<pane_id>.desc` exists, read the auto-default
from it. `pane_id` and `STATE_DIR` are already in scope. The placeholder is
unchanged. `edit_description` (Ctrl-E) is unchanged — it still writes the
override file, which takes precedence.

### Modified: `scripts/agent/clear-pane.sh`

On pane death, also `rm -f` the `<pane_id>.desc` sibling (one line).

### Modified: `install-claude-hooks.sh`

Add a second command to two existing entries (both contain the scripts dir, so
the idempotent strip/re-add still converges):
- `SessionStart`: `set-state.sh idle` **and** `auto-desc.sh clear`.
- `UserPromptSubmit`: `set-state.sh working` **and** `auto-desc.sh set`
  (reads `.prompt`). `uninstall-claude-hooks.sh` needs no change (it strips by
  scripts-dir match).

### Modified: `scripts/pi/agent-status.ts`

- `session_start` (reason ≠ `reload`): in addition to `set idle`, call
  `auto-desc.sh clear`. pi has no `compact` session_start reason (compaction is
  `session_compact`), so no compact guard is needed on the pi side.
- New `before_agent_start` handler: `auto-desc.sh set <event.prompt>` (passed as
  an args-array element to `pi.exec`, so no shell quoting issues). The
  first-prompt-only behavior is enforced by the script's existence check.

### Modified: `README.md`

Document the auto-default behavior (first-prompt, override > auto > none,
per-session) in the navigator/architecture sections.

## Data flow

```
first prompt
  ├─ Claude UserPromptSubmit ─► auto-desc.sh set   (stdin .prompt)
  └─ pi before_agent_start   ─► auto-desc.sh set   (arg event.prompt)
        └─ if <pane_id>.desc absent: write cleaned+trimmed first line
new session start
  ├─ Claude SessionStart (source != compact) ─► auto-desc.sh clear
  └─ pi session_start (reason != reload)      ─► auto-desc.sh clear
navigator render
  └─ override (Ctrl-E) ?: auto-default (<pane_id>.desc) ?: placeholder
pane death
  └─ clear-pane.sh removes state + <pane_id>.desc
```

## Edge cases

| Case | Behavior |
|---|---|
| Brand-new session, no prompt yet | no `.desc` → placeholder shown |
| Ctrl-E override present | override shown; auto-default recorded but ignored |
| Clear Ctrl-E override later | captured auto-default becomes visible |
| Claude compaction mid-session | `clear` skips (`source == compact`) → label unchanged |
| pi `/reload` | extension skips clear (reason == reload) → label unchanged |
| `/clear`, `/new`, `/resume`, `/fork` | label cleared, regenerated on next first prompt |
| empty / whitespace-only prompt | skipped → placeholder remains |
| not in tmux | `auto-desc.sh` no-ops (no `$TMUX_PANE`) |

## Testing

`tests/test-auto-desc.sh` (bash, runnable; uses a unique sentinel `TMUX_PANE`
against the resolved state dir, cleaned up after):
- `set` writes a cleaned, trimmed one-line value on first call.
- second `set` does **not** overwrite (first-prompt-only).
- long input is trimmed to ≤ ~50 chars and ends with `…`.
- multi-line / extra-whitespace input collapses to a clean first line.
- empty / whitespace input writes nothing.
- text via arg and via stdin `.prompt` both work.
- `clear` removes the file; `clear` with stdin `{"source":"compact"}` does not.

Plus `bash -n` / shellcheck on changed scripts, and the existing suite still
passing.

## Out of scope (YAGNI)

- AI-generated titles.
- Tying the auto-default to the agent's session id (the per-pane `.desc` +
  session-start clear is sufficient).
- Making the trim length configurable (50 is a sensible fixed default).
- Persisting the auto-default across reboots (transient by design).
