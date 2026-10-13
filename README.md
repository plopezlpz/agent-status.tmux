# agent-status.tmux

Event-driven status indicators and a navigator for AI coding-agent panes in tmux.

- semantic **working / asking / idle** state, with unseen completions shown as **finished**
- worst-state window icon (asking > working > finished > idle)
- clickable notifications and a live-updating `prefix A` fzf navigator, with
  an agents tab and a sessions tab (session/window tree with agent states);
  `Tab` switches tabs and keeps the query
- first-prompt labels with persistent `Ctrl-E` overrides and idle age
- no daemon and no pane-output or process-tree polling

## Supported providers and fidelity

| Provider | Fidelity | Integration |
|---|---|---|
| pi | Full lifecycle | extension; only the TUI (`ctx.mode`) owns the pane |
| OMP (Oh My Pi) | Full lifecycle | extension; nested blockers, approvals/ask, settle debounce, retry grace |
| OpenCode | Full lifecycle | server + TUI plugins; the TUI selects the pane's root session and clears it on exit; child sessions cannot take root identity; ESC aborts settle idle |
| Kilo Code | Partial lifecycle | plugin; Kilo has no exit event, so the pane is cleared from a process exit/signal handler (untested against a real Kilo); a prompt in another root session (`kilo -c`, picking a session) rebinds the pane; headless commands are detected from argv |
| Kimi Code | Full lifecycle | native hooks incl. `SessionEnd`; headless runs (`-p`, `acp`, `web`, `rc`) are detected from the kimi process argv |
| MastraCode | Full lifecycle | native hooks incl. `SessionEnd`; headless `--prompt` runs are detected from argv |
| Claude Code | Best-effort compatibility | native hooks; Claude has no interrupt or permission-resolved event, so an Esc interrupt or a denied prompt settles to idle only when Claude's `idle_prompt` notification fires (default 60s); API errors end the turn through `StopFailure` |

Herdr also recognizes Codex, Copilot, Devin, Droid, Qoder, Qwen, Cursor,
Hermes, Antigravity, Grok, Amp, Kiro, Gemini, Cline, and Maki. They are **not
supported here**. Herdr derives some or all of their semantic state from
session/process/screen/OSC inference, which cannot be reproduced accurately
under this plugin's no-pane-polling constraint. In particular, **Codex is not a
full lifecycle hook authority**; this plugin does not pretend that it is.

## Install

With [TPM]:

```tmux
set -g @plugin 'plopezlpz/agent-status.tmux'
run '~/.tmux/plugins/tpm/tpm'
```

Run `prefix I`, then install each provider you use:

```bash
PLUGIN=~/.tmux/plugins/agent-status.tmux
bash "$PLUGIN/manage-provider.sh" install pi
bash "$PLUGIN/manage-provider.sh" install omp
bash "$PLUGIN/manage-provider.sh" install opencode
bash "$PLUGIN/manage-provider.sh" install kilo
bash "$PLUGIN/manage-provider.sh" install kimi
bash "$PLUGIN/manage-provider.sh" install mastracode
bash "$PLUGIN/manage-provider.sh" install claude
```

The old `install-pi-extension.sh` and `install-claude-hooks.sh` commands remain
compatible. Restart/reload the provider after installation. Missing provider
config homes are skipped safely. Install refuses existing foreign files,
foreign symlinks, config symlinks, and malformed edited configs.

Add the cached icon to both status formats:

```tmux
setw -g window-status-format         "#[fg=...] #{?@agent-icon,#{@agent-icon} ,}#I:#W "
setw -g window-status-current-format "#[fg=...] #{?@agent-icon,#{@agent-icon} ,}#I:#W "
```

## Uninstall

```bash
bash "$PLUGIN/manage-provider.sh" uninstall pi       # repeat for each provider
bash "$PLUGIN/manage-provider.sh" uninstall omp
bash "$PLUGIN/manage-provider.sh" uninstall opencode
bash "$PLUGIN/manage-provider.sh" uninstall kilo
bash "$PLUGIN/manage-provider.sh" uninstall kimi
bash "$PLUGIN/manage-provider.sh" uninstall mastracode
bash "$PLUGIN/manage-provider.sh" uninstall claude
```

Uninstall removes only plugin-owned hook entries and symlinks. It preserves
unrelated provider configuration and same-named user files.

## Requirements

| Dependency | Minimum / use |
|---|---|
| tmux | 3.3 (`display-popup -E`) |
| Bash | 3.2 (macOS default) |
| jq | hook payloads and safe JSON config edits |
| fzf | 0.74 (`every`, `reload-sync`, and `transform` actions), navigator only |
| alerter / terminal-notifier / notify-send | optional notifications |
| pi | 0.84.4 (`ui_prompt_start`/`ui_prompt_end`; `ctx.mode`, `agent_settled`, `ctx.isIdle()` are older); verified with 1.1.0 |
| OMP | verified with 18.8.9 |
| OpenCode | plugin discovery (`plugin/` and `plugins/`), event and error names verified with 2.0.25 |
| Kimi Code | hook events and payloads verified with 2.1.1 |
| Kilo Code, MastraCode | unverified locally (Kilo's `plugin/` directory and MastraCode's `SessionStart`/`SessionEnd` payload fields follow upstream docs) |

Provider versions and event names evolve; these adapters follow Herdr's current
lifecycle-authority integrations. Hook adapters that cannot read an interactive
flag from their payload (Kimi, MastraCode) inspect the provider process's argv
once per hook, honoring only options before the first non-option word (`ps`
drops quoting); a headless run they cannot recognize may still report into the
pane it inherited. OpenCode `tui.jsonc` editing currently
requires JSON-compatible content (comments cause a safe refusal rather than a
lossy rewrite).

## Configuration

Set options before TPM runs; defaults never replace user overrides.

| Option | Default |
|---|---|
| `@agent-icon-working`, `@agent-color-working` | `●`, `yellow` |
| `@agent-icon-asking`, `@agent-color-asking` | `●`, `red` |
| `@agent-icon-finished`, `@agent-color-finished` | `●`, `cyan` |
| `@agent-icon-idle`, `@agent-color-idle` | `○`, `green` |
| `@agent-navigator-key` | `A` (navigator on its agents tab) |
| `@agent-sessions-key` | empty (set e.g. `a` to open the navigator on its sessions tab) |
| `@agent-popup-width`, `@agent-popup-height` | `70%`, `70%` (formats, expanded per client) |
| `@agent-terminal-app` | empty |
| `@agent-notify-timeout` | `300` |
| `@agent-descriptions-dir` | `${XDG_DATA_HOME:-$HOME/.local/share}/tmux/agent-status/descriptions` |
| `@agent-log` | `${XDG_DATA_HOME:-$HOME/.local/share}/tmux/agent-status/agent.log` |

Installer path overrides mirror provider conventions where useful:
`PI_CODING_AGENT_DIR`, `PI_EXTENSIONS_DIR`, `PI_CONFIG_DIR`,
`OMP_EXTENSIONS_DIR`, `OPENCODE_CONFIG_DIR`, `KILO_CONFIG_DIR`,
`KIMI_CODE_HOME`, `MASTRACODE_HOME`, and `CLAUDE_SETTINGS`.
OMP debounce and retry grace honor `HERDR_OMP_IDLE_DEBOUNCE_MS` and
`HERDR_OMP_RETRY_GRACE_MS`.

## Architecture and adapter contract

```text
provider lifecycle event
  -> tiny provider adapter
  -> scripts/agent/set-state.sh (provider-neutral sink)
  -> pane options (@agent-state, @agent-unseen, @agent-instance,
                   @agent-seq, @agent-kind, @agent-state-at)
  -> push-only window aggregation / notification / navigator
```

`finished` is stored as `idle + unseen`; focusing the pane acknowledges it.
A completion in the pane a terminal-focused client is already showing is not
notified; it keeps the finished marker until focus or the next prompt. Plugin tmux hooks (`run-shell -b`) clear
panes on `pane-exited`/`pane-died` and reconcile window icons on
`window-layout-changed`/`pane-moved` (kill, break, join, move and swap-pane).
While open, the navigator checks a cheap revision token once per second and
reloads only after a state/description change or at a new idle-age minute,
without blocking typing; normal status handling remains push-only.
Authoritative session IDs are provider-qualified, and adapters with an
in-process event stream submit monotonic sequences so stale reports are
rejected. Pane and window lock files beside the tmux socket serialize shared
updates; a lock whose holder died is broken at once and any lock held past
~3s is treated as stale, so a killed hook cannot wedge a pane. Tmux pane
options disappear with panes; only sanitized manual descriptions and the
transition audit log live on disk. Descriptions are files named
`<server start_time>-<pane number>` in `@agent-descriptions-dir` (Ctrl-G's
in-progress marker is `.generating-<same key>`), so a restarted server's
reused pane IDs never inherit an old title. They are removed when the pane
exits; the navigator prunes week-old entries left by earlier servers.

A future provider adapter must:

1. have native full-lifecycle authority (do not infer semantic state);
2. map native events directly to `working`, `asking`, `finished`, or initial
   `idle` through `set-state.sh`;
3. pass `instance`, monotonic `seq` when events share a process, and a stable
   lowercase `kind`; use `reset` only at authoritative root-session selection;
4. send first native prompt text to `auto-desc.sh set`, and clear it for a new
   session;
5. avoid blocking or breaking the provider when status reporting fails.
   Always pass positional arguments: `set-state.sh` reads a stdin payload
   only in the single-argument Claude hook form.

Nested or headless agents (e.g. `claude -p` run from inside an agent pane)
inherit `TMUX_PANE` and would take over that pane's status. Run them with it
cleared: `TMUX_PANE= claude -p ...`.

[TPM]: https://github.com/tmux-plugins/tpm
