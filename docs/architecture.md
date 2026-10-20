# Architecture

## Pipeline

```text
provider lifecycle event
  -> tiny provider adapter
  -> scripts/agent/set-state.sh (provider-neutral sink)
  -> pane options (@agent-state, @agent-unseen, @agent-instance,
                   @agent-seq, @agent-kind, @agent-state-at,
                   @agent-auto-description)
  -> window icon / notification
```

`finished` is stored as `idle + unseen`; focusing the pane acknowledges it.
A completion or permission prompt is not notified when the most recently
active client is showing its pane with terminal focus; other clients don't
count, since one left attached elsewhere (a phone over mosh) never reports
losing focus. A completion keeps the finished marker until focus or the next
prompt. A notification click switches a local client (one not running under
sshd or mosh-server), preferring the one captured at notify time; a remote
client such as a phone is never switched. The click also marks the pane
seen, which focus alone does not while another client already shows it.

A state change is one tmux read and one chained write (pane options, the
window icon), so attached clients redraw once. A report that repeats the
pane's state (each Claude tool call makes two) is settled from a single read,
before the payload is parsed or the pane lock taken.

The window icon `@agent-icon` is a plain window option, but tmux computes it:
`set-option -wF @agent-icon '#{E:@agent-icon-format}'` evaluates the worst
pane state in the window, so updating it starts no process. State changes
run it after their pane write; the plugin's `pane-exited`,
`window-layout-changed` and `pane-moved` hooks run it directly (kill, break,
join, move and swap-pane), and every window is recomputed on load. The
`pane-focus-in` hook checks for an unseen completion in tmux and runs a script
only to clear one; `pane-died` clears a remain-on-exit pane (`run-shell -b`).

Authoritative session IDs are provider-qualified, and adapters with an
in-process event stream submit monotonic sequences so stale reports are
rejected. Pane lock files beside the tmux socket serialize shared updates; a
lock whose holder died is broken at once and any lock held past ~3s is
treated as stale, so a killed hook cannot wedge a pane. Tmux pane options
disappear with panes; only the transition audit log lives on disk.

Titles: `@agent-auto-description` is the first prompt; `@agent-description`
is a title the user set, which UIs show instead. A UI may set it directly
(paddock does); scripts can use `describe.sh set PANE [TEXT]` (no TEXT: back
to automatic). Both are cleared with the other options when the agent exits.
The plugin sets `@agent-suggest-command` to `describe.sh suggest`: run with a
pane id appended, it waits for pi and prints a title without setting it, or
fails with the reason on stderr; a signal stops pi. `describe.sh generate
PANE` sets one in the background instead (`@agent-generating` marks the run).

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

## Providers in detail

| Provider | Integration |
|---|---|
| pi | extension; only the TUI (`ctx.mode`) owns the pane |
| OMP | extension; nested blockers, approvals/ask, settle debounce, retry grace (`AGENT_STATUS_OMP_IDLE_DEBOUNCE_MS`, `AGENT_STATUS_OMP_RETRY_GRACE_MS`; the older `HERDR_OMP_*` names still work) |
| OpenCode | server + TUI plugins; the TUI selects the pane's root session and clears it on exit; child sessions cannot take root identity; ESC aborts settle idle |
| Kilo Code | plugin; no exit event, so the pane is cleared from a process exit/signal handler; a prompt in another root session (`kilo -c`, picking a session) rebinds the pane; headless commands are detected from argv |
| Kimi Code | native hooks incl. `SessionEnd`; headless runs (`-p`, `acp`, `web`, `rc`) are detected from the kimi process argv |
| MastraCode | native hooks incl. `SessionEnd`; headless `--prompt` runs are detected from argv |
| Claude Code | native hooks; no interrupt or permission-resolved event, so an Esc or a denied prompt settles on `idle_prompt`; API errors end the turn through `StopFailure`; a Stop while background subagents run stays working; headless runs (`claude -p`, the Agent SDK: `CLAUDE_CODE_ENTRYPOINT=sdk-*`) are ignored |

Hook adapters that cannot read an interactive flag from their payload (Kimi,
MastraCode) inspect the provider process's argv once per hook, honoring only
options before the first non-option word (`ps` drops quoting); a headless run
they cannot recognize may still report into the pane it inherited.

Installer path overrides follow each provider's conventions: pi
`PI_CODING_AGENT_DIR`, `PI_EXTENSIONS_DIR`; OMP `PI_CONFIG_DIR`,
`OMP_EXTENSIONS_DIR`; `OPENCODE_CONFIG_DIR`, `KILO_CONFIG_DIR`,
`KIMI_CODE_HOME`, `MASTRACODE_HOME` and `CLAUDE_SETTINGS`. Providers whose
config directory is missing are skipped (Claude's `settings.json` is created).
`install-claude-hooks.sh [install|uninstall]` is what `manage-provider.sh`
runs for Claude; the older `install-pi-extension.sh` and
`uninstall-claude-hooks.sh` still work.
