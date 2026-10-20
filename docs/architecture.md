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

A state change is one chained tmux write (pane options, the window icon), so
attached clients redraw once. It reads the pane once under the pane lock; a
working report, or an adapter's asking report, also reads it once before
taking the lock, and a report that repeats the pane's state (each Claude tool
call makes two) is settled there, before the payload is parsed or the lock
taken.

The window icon `@agent-icon` is a plain window option, but tmux computes it:
`set-option -wF @agent-icon '#{E:@agent-icon-format}'` evaluates the worst
pane state in the window, so updating it starts no process. State changes
run it after their pane write; the plugin's `pane-exited`,
`window-layout-changed` and `pane-moved` hooks run it for `#{hook_window}`
(kill, break, join, move and swap-pane), through `run-shell -C`, which expands
the id without a process, and only when the icon changes, since every option
write redraws every client. Every window is recomputed on load. The
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
fails with the reason on stderr; a signal stops pi.

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
   only in the single-argument hook form Claude and Codex hooks use.

## Providers in detail

| Provider | Integration |
|---|---|
| pi | extension; only the TUI (`ctx.mode`) owns the pane |
| OMP | extension; nested blockers, approvals/ask, settle debounce, retry grace (`AGENT_STATUS_OMP_IDLE_DEBOUNCE_MS`, `AGENT_STATUS_OMP_RETRY_GRACE_MS`) |
| OpenCode | 1.x: server + TUI plugins; the TUI binds the pane to the root session it shows (`set-state.sh` `bind`, which keeps a pane the server plugin bound first to that session) and clears it on exit; a child session reports only its blockers, as its root; an Esc, a rejected permission or question, and an Esc on a `!` shell command settle idle; headless commands are detected from the thread and argv. 2.x: one shared background service runs every session and belongs to no pane, so a TUI plugin (a plugin directory) reports alone, from the service's events, for the active tab's root session; the 1.x server plugin loads there as a no-op |
| Kilo Code | plugin; the pane is cleared from its `dispose` hook (the default TUI runs it in a worker, where exit handlers never run) or, in `--mini`, a process exit/signal handler; a prompt in another root session (`kilo -c`, picking a session) rebinds the pane; a child session reports only its blockers, as its root; `offline` asks; headless commands (including a `kilo daemon`, so the TUIs attached to one) are detected from the thread and argv |
| Kimi Code | native hooks incl. `SessionEnd`; headless runs (`-p`, `acp`, `web`, `rc`) are detected from the kimi process argv |
| MastraCode | native hooks incl. `SessionEnd`; headless `--prompt` runs are detected from argv |
| Codex | native hooks in `hooks.json` run `hook-event.sh codex`, which hands the payload to the hook form of `set-state.sh`/`clear-state.sh` (kind `codex`), so asks work as for Claude, with these differences: Codex runs an agent's shell calls in parallel, all named `Bash`, and its `PermissionRequest` has no call id, so an ask is keyed by a hash of the call's command and ends with that call's `PostToolUse` (a `write_stdin` ask with the `Bash` one) or a call that starts a few seconds after the ask (its siblings start with it; a denied call returns nothing); a subagent's ask also ends with its `SubagentStop`; a subagent's events never wake a settled pane, since a subagent may outlive its parent's turn, and only its asks show there, the pane settling again (`@agent-settled` keeps the unseen value) when they end; the model's `request_user_input` question asks, `Interrupt` settles idle and `SessionEnd` clears; `SessionStart` fires only at the first prompt, and a turn that ends in an error fires no event; headless runs (`exec`, `review`, `app-server`, including the shared background server whose hooks carry the environment of whichever terminal started it) are detected from the nearest codex process's argv; trust is keyed by each hook's place in the file, so the installer edits it in place |
| Claude Code | native hooks, one `set-state.sh` process per event (it also keeps the first prompt); no interrupt or permission-resolved event, so an Esc or a denied prompt settles on `idle_prompt`; a permission prompt stays asking through the tool hooks of parallel tools and subagents until the agent that asked proceeds (`@agent-asks`); API errors end the turn through `StopFailure`; a Stop while background subagents run stays working; headless runs (`claude -p`, the Agent SDK: `CLAUDE_CODE_ENTRYPOINT=sdk-*`) are ignored |

Adapters run the scripts of the checkout they come from: the extensions and
plugins are symlinks into it and find `scripts/agent` beside their real path,
and Kimi, MastraCode and Codex hooks run `scripts/agent/hook-event.sh` by
its path.
`hook-event.sh` cannot read an interactive flag from the payload, so it
inspects the provider process's argv once per hook, honoring only options
before the first non-option word; a headless run it cannot recognize may
still report into the pane it inherited. Where `/proc/<pid>/cmdline` exists
it reads the real argv; elsewhere `ps` drops quoting, so an interactive run
whose command-line prompt starts with a headless subcommand's name (`codex
"review my change"`) is taken as headless and does not report.

Installer path overrides follow each provider's conventions: pi
`PI_CODING_AGENT_DIR`, `PI_EXTENSIONS_DIR`; OMP `PI_CONFIG_DIR`,
`OMP_EXTENSIONS_DIR`; `OPENCODE_CONFIG_DIR`, `KILO_CONFIG_DIR` (else
`$XDG_CONFIG_HOME/opencode`, `$XDG_CONFIG_HOME/kilo`),
`KIMI_CODE_HOME`, `MASTRACODE_HOME`, `CODEX_HOME`, and Claude's `CLAUDE_CONFIG_DIR` (or
`CLAUDE_SETTINGS`, the settings file itself). Providers whose
config directory is missing are skipped (Claude's `settings.json` is created).
`install-claude-hooks.sh [install|uninstall]` is what `manage-provider.sh`
runs for Claude.
