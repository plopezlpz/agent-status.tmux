# Architecture

## Pipeline

```text
provider lifecycle event
  -> tiny provider adapter
  -> scripts/agent/set-state.sh (provider-neutral sink)
  -> pane options (below)
  -> window icon / notification
```

| Pane option | Value |
|---|---|
| `@agent-state` | `working`, `asking` or `idle` |
| `@agent-unseen` | `1` while an idle completion is not seen yet (shown as finished), else `0` |
| `@agent-state-at` | when the state last changed, Unix seconds |
| `@agent-kind` | the provider: `pi`, `omp`, `opencode`, `kilo`, `kimi`, `mastracode`, `claude`, `codex`, `gemini`, `qwen` or `antigravity` |
| `@agent-instance` | the provider-qualified session id (`kind:id`) |
| `@agent-seq` | the last accepted sequence number from an in-process adapter |
| `@agent-auto-description` | the first prompt (or the session's own title), at most 50 characters |
| `@agent-description` | a title the user set (by a UI or `describe.sh set`) |
| `@agent-transcript` | the session's `.jsonl` (Claude, Codex, Qwen, pi); `describe.sh` reads Claude's and pi's for title suggestions |
| `@agent-asks` | internal: open Claude, Codex and Qwen permission prompts and dialogs, space-separated |
| `@agent-settled` | internal: the `@agent-unseen` value to restore when an ask on a settled pane ends (a Codex subagent's, a Claude dialog between turns); focusing the pane sets it to 0 |
| `@agent-subagents` | internal: Kimi subagents started in the current turn |
| `@agent-notify-token` | internal: cancels a delayed notification |

All of them are unset together when the agent exits. Window option:
`@agent-icon`. Global options, set on every load: `@agent-icon-format` (the
icon's tmux format), `@agent-suggest-command` (the title-suggestion command)
and `@agent-scripts-dir` (this checkout's `scripts/agent`, for adapters and
other tools' installers, such as paddock's).

`finished` is stored as `idle + unseen`; focusing the pane acknowledges it.
A completion or permission prompt is not notified when the most recently
active client is showing its pane with terminal focus; other clients don't
count, since one left attached elsewhere (a phone over mosh) never reports
losing focus. A completion keeps the finished marker until focus or the next
prompt. A notification click switches a local client (one not running under
sshd, mosh-server or etserver), preferring the one captured at notify time; a
remote client such as a phone is never switched. The click also marks the pane
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
`pane-focus-in` hook checks for an unseen completion in tmux, or one an ask
holds in `@agent-settled`, and runs a script only to clear one; `pane-died` clears a remain-on-exit pane (`run-shell -b`).

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
fails with the reason on stderr; a signal stops pi. pi runs for at most
`AGENT_DESCRIBE_TIMEOUT` seconds (default 120; enforced with coreutils
`timeout` or perl when either is installed); paddock gives up after 30. If pi
is not on the `PATH` that `describe.sh` runs with, the directory in
`AGENT_PI_FALLBACK_PATH` is tried too (default: fnm's default alias,
`~/.local/share/fnm/aliases/default/bin`; empty: `PATH` only).

A future provider adapter must:

1. have native full-lifecycle authority (do not infer semantic state);
2. map native events directly to `working`, `asking`, `finished`, or `idle`
   through `set-state.sh`; `idle` means waiting with nothing new to show (a
   new session, or a turn the user interrupted or aborted), so it never
   claims an unseen completion;
3. pass `instance`, monotonic `seq` when events share a process, and a stable
   lowercase `kind`; use `reset` only at authoritative root-session selection;
4. send first native prompt text to `auto-desc.sh set`, and clear it for a new
   session;
5. avoid blocking or breaking the provider when status reporting fails.
   Always pass positional arguments: `set-state.sh` reads a stdin payload
   only in the single-argument hook form Claude, Codex and Qwen hooks use;
6. on a real exit, run `clear-state.sh <reason> <instance> <kind>`; the
   reasons `clear` and `resume` keep the pane registered.

Antigravity CLI meets 1 only in part and can't meet 6: agy runs no hook as it
starts or quits, or for a permission prompt. Its support is partial, and the README
says what it can't show.

## Providers in detail

| Provider | Integration |
|---|---|
| pi | extension; only the TUI (`ctx.mode`) owns the pane; an Esc settles idle (`agent_settled.aborted`, pi 1.1.0+); a `/compact` outside a run shows working |
| OMP | extension; nested blockers: tool approvals, the `ask` tool and the plan review (omp 18.12+); dialogs that go through omp's `waitForUser` (extension and MCP dialogs) emit no event, so they show as working; a settle debounce (`AGENT_STATUS_OMP_IDLE_DEBOUNCE_MS`); an Esc settles idle, as does one during a retry's backoff; omp retries before a turn ends, so a turn that ends in an error asks with its message; a turn left waiting on a continuation that never comes (a cancelled background job) settles once omp is idle with no job running or queued; `session_branch` (a `/btw` branch, an entry fork) rebinds the pane as `session_switch` does |
| OpenCode | 1.x: server + TUI plugins; the TUI binds the pane to the root session it shows, and the server plugin to the root session of each prompt (`set-state.sh` `bind`, which keeps a pane already bound to that session as it is), and the TUI clears it on exit; a child session reports only its blockers, as its root; an Esc, a rejected permission or question, and an Esc on a `!` shell command settle idle; headless commands are detected from the thread and argv. 2.x: one shared background service runs every session and belongs to no pane, so a TUI plugin (a plugin directory) reports alone, from the service's events, for the active tab's root session; the 1.x server plugin loads there as a no-op |
| Kilo Code | plugin; the pane is cleared from its `dispose` hook (the default TUI runs it in a worker, where exit handlers never run) or, in `--mini`, a process exit/signal handler; a prompt in another root session (`kilo -c`, picking a session) rebinds the pane; a child session reports only its blockers, as its root; `offline` asks; headless commands (including a `kilo daemon`, so the TUIs attached to one) are detected from the thread and argv |
| Kimi Code | native hooks incl. `SessionEnd`; kimi retitles its process `kimi-code` (cut to its command line's length), so its argv is gone: a run reports only while the kimi process is its terminal's foreground job, which a headless one started by another agent's tool (`-p`, `acp`) is not (one started in a shell or an editor is); the prompt arrives as content parts, whose text names the pane; `TurnStarted` shows turns kimi starts itself (a background task's result) working; a subagent's turn ends with its own `Stop`, `StopFailure` or `Interrupt` under the session's id, so `@agent-subagents` counts the subagents started (`SubagentStart`) and each end while one runs is taken as a subagent's, the last as the turn's (a prompt or a new session starts the count over); the session starts at the first message, so a kimi shows from then; the installer also finds its hook tables when kimi has rewritten `config.toml` without our markers |
| MastraCode | native hooks incl. `SessionEnd`; the session id follows the thread (`session-init` until the first prompt creates one, then each `/new` or switch, with no new `SessionStart`), so the MastraCode process (its pid) is the identity; only the TUI fires `SessionStart`, so an event reports only into the pane its process registered (a tool hook passes `set-state.sh` `only`, which checks that in the pane read it makes anyway), which leaves headless runs (`--prompt`, a prompt argument, `--acp`), whose tool hooks still fire, out; `AgentEnd` ends a run (`aborted` settles idle, `suspended` waits on the user, whose question or approval asks through `Notification` or `PermissionRequest`); MastraCode runs only the first `SessionEnd` hook and may exit before it does, so ours goes first and also clears a registration whose process is gone |
| Codex | native hooks in `hooks.json` run `hook-event.sh codex`, which hands the payload to the hook form of `set-state.sh`/`clear-state.sh` (kind `codex`), so asks work as for Claude, with these differences: Codex runs an agent's shell calls in parallel, all named `Bash`, and its `PermissionRequest` has no call id, so an ask is keyed by a hash of the call's command and ends with that call's `PostToolUse` (a `write_stdin` ask with the `Bash` one) or a call that starts a few seconds after the ask (its siblings start with it; a denied call returns nothing); a subagent's ask also ends with its `SubagentStop`; a subagent's events never wake a settled pane, since a subagent may outlive its parent's turn, and only its asks show there, the pane settling again (`@agent-settled` keeps the unseen value) when they end; the model's `request_user_input` question and `request_permissions` request ask (neither fires `PermissionRequest`), `Interrupt` settles idle and `SessionEnd` clears; `SessionStart` fires only at the first prompt, and a turn that ends in an error fires no event; headless runs (`exec`, `review`, `app-server`, including the shared background server whose hooks carry the environment of whichever terminal started it) are detected from the nearest codex process's argv; trust is keyed by each hook's place in the file, so the installer edits it in place, and leaves an empty group where it removes one of ours that other groups follow |
| Gemini CLI | native hooks in `settings.json` (one definition per event, named `agent-status`) run `hook-event.sh gemini`, which prints nothing and always exits 0 (Gemini shows a hook's output, and exit 2 blocks a prompt or forces a retry turn); `SessionStart` registers the session (`/clear` ends it with reason `clear`, which keeps the pane, and starts the next), `BeforeAgent` works and titles the pane, `Notification` (a confirmation about to show) asks, `AfterTool` works (it ends an approved tool's ask; the hot path, it reads the session id from `GEMINI_SESSION_ID` and never the payload), `AfterAgent` finishes and `SessionEnd` clears; a denied or cancelled confirmation, and an Esc while a tool runs, fire nothing, so the pane stays asking or working until the next prompt, and an Esc while the model streams fires `AfterAgent`; the in-app `/resume` switches sessions without an event, so `BeforeAgent` rebinds the pane (`set-state.sh` `bind`); a prompt argument is interactive in a terminal, while `-p`, `--acp` and a run that isn't the foreground job of its pane's own terminal (one run by another agent's tool, which Gemini's and Qwen's shell tools run in a pty of their own) are headless; Gemini runs hooks only in trusted folders; Antigravity shares `~/.gemini`, so `found` looks for Gemini CLI's own files |
| Qwen Code | native hooks in `settings.json` (one definition per event, named `agent-status`, edited as for Gemini CLI) run `hook-event.sh qwen`, which prints nothing, always exits 0 and hands the payload, Claude Code's events and fields, to the hook form of `set-state.sh`/`clear-state.sh` (kind `qwen`), as for Codex; Qwen runs none of an agent's tools while one waits on an answer, so the agent's next `PreToolUse` ends all its asks (`PermissionRequest`, which also covers the model's question and plan approval); the `idle_prompt` notification, sent each time the TUI waits for input again, settles an Esc or a denial idle; `StopFailure` (API errors) finishes; a `Stop` while background agents run (`background_tasks`, which carry no type) doesn't finish, as for Claude, but the `idle_prompt` that follows at once (the TUI waits for input while they run) settles it idle, until the turn Qwen starts with their results finishes; `SessionEnd` clears (`clear` keeps the pane for the next `SessionStart`); headless runs (a prompt argument without `-i`, a subcommand, `-p`, `--acp`, a run that isn't the foreground job of its pane's own terminal) are found from the nearest qwen process's argv (`node .../bin/qwen`, the standalone install's `node .../lib/cli-entry.js`, or under Bun the `bun .../cli-entry.js` parent of the CLI's child), but one in the foreground whose input is redirected reports, and fires no `SessionEnd`; turns Qwen starts itself fire no prompt event; the opt-in OpenTUI renderer sends no `idle_prompt` or `StopFailure` |
| Antigravity CLI | partial; one named hook (`agent-status`) in `~/.gemini/config/hooks.json` runs `hook-event.sh antigravity`, which prints `{}` (agy reads a hook's output as a JSON object, whose fields would allow a tool or keep a turn going) and always exits 0; `PreInvocation` (before each model call) works, `PreToolUse`/`PostToolUse` matching `ask_question` (the model's question) ask and work again, and `Stop` finishes, except that a cancel (`USER_CANCELED`: an Esc) settles idle and a stop on the question (`TERMINAL_STEP_TYPE`) keeps it asking; agy runs no hook at start (its `SessionStart` fires at a conversation's first turn at best, and its `/hooks` drops it when it saves the file), at exit, for `/clear` or `/resume` (which change the `conversationId`), or for a permission prompt (`PreToolUse` runs before the permission check, so a prompt shows working), so the contract's exit rule can't be met: the instance is the agy process and its conversation (`antigravity:<pid>:<conversationId>`), bound by a model call (`set-state.sh` `bind`): a new process takes the pane over, and another conversation of the same process does so while the pane isn't working (while it is, that conversation is a subagent's); the first prompt comes from the transcript (`transcriptPath`, the first `USER_INPUT` from `USER_EXPLICIT`, its `<USER_REQUEST>`); headless runs (`-p`, `--print`, `--prompt`, the subcommands, a run that isn't the foreground job of its pane's own terminal) are found from the agy process's argv |
| Claude Code | native hooks, one `set-state.sh` process per event (it also keeps the first prompt); no interrupt or permission-resolved event, so an Esc or a denied prompt settles on `idle_prompt`; a permission prompt stays asking through the tool hooks of parallel tools and subagents until the agent that asked proceeds (`@agent-asks`): its tool returns, it calls a tool a few seconds after the ask (read-only tools run in parallel, so siblings start with it), it stops (`SubagentStop`), or the main thread's foreground `Agent` call that ran it returns; an MCP server's form or URL asks from `Elicitation` to `ElicitationResult`, and a sandboxed command's network request from its `permission_prompt` notification to the main thread's next tool hook (neither fires `PermissionRequest`), settling the pane again when asked between turns; a session's own title (`session_title`: `--name`, `/rename`) describes the pane in place of the first prompt, and text pasted into the prompt is left out; API errors end the turn through `StopFailure`; a Stop while background subagents run stays working; headless runs (`claude -p`, the Agent SDK: `CLAUDE_CODE_ENTRYPOINT=sdk-*`) are ignored |

Adapters run the scripts of the checkout they come from: the extensions and
plugins are symlinks into it and find `scripts/agent` beside their real path,
and Kimi, MastraCode, Codex, Gemini CLI, Qwen Code and Antigravity CLI hooks
run `scripts/agent/hook-event.sh` by its path.
`hook-event.sh` cannot read an interactive flag from the payload, so it
inspects the provider process's argv (Kimi, Gemini, Qwen and Antigravity:
also whether it is its terminal's foreground job; Gemini, Qwen and
Antigravity: also whether that terminal is the pane's own, `#{pane_tty}`) once per hook, honoring only options before the first non-option word; a headless
run it cannot recognize may still report into the pane it inherited. Where
`/proc/<pid>/cmdline` exists it reads the real argv; elsewhere `ps` drops
quoting, so an interactive run whose command-line prompt starts with a
headless subcommand's name (`codex "review my change"`) is taken as
headless and does not report.

Codex's shared background server (`codex app-server --listen unix://`, which
every `codex` attaches to by default since 0.157) runs the hooks of all its
sessions in its own process, with the environment of the terminal that
started it, so their `TMUX_PANE` is that terminal's. They are skipped like
headless runs, as no other route to the session's pane holds: the payload
names no client; the server tells hooks nothing of which connection drives a
thread; panes in one directory share the payload's `cwd`; the pane title
carries the thread id only with `thread-id` in `tui.terminal_title` (cut to
29 characters, and the viewed subagent's while one is viewed); and a thread
outlives its TUI, which only unsubscribes when it quits, until the server
unloads it (`thread_unload_delay_secs`, 1800) or stops, which is when its
`SessionEnd` fires. Hence `codex --no-daemon`, whose TUI runs its sessions
in its own process.

Installer path overrides follow each provider's conventions: pi
`PI_CODING_AGENT_DIR`, `PI_EXTENSIONS_DIR`; OMP `PI_CONFIG_DIR`,
`OMP_PROFILE` (else `PI_PROFILE`), `OMP_EXTENSIONS_DIR`;
`OPENCODE_CONFIG_DIR`, `KILO_CONFIG_DIR` (else
`$XDG_CONFIG_HOME/opencode`, `$XDG_CONFIG_HOME/kilo`),
`KIMI_CODE_HOME`, `CODEX_HOME`, `GEMINI_CLI_HOME` (Gemini CLI's home: its
settings are in `$GEMINI_CLI_HOME/.gemini`), `QWEN_HOME` (read as Qwen
does: `~` is the home directory), and Claude's `CLAUDE_CONFIG_DIR` (or
`CLAUDE_SETTINGS`, the settings file itself). `MASTRACODE_HOME` is the
installer's own, for tests: MastraCode always reads `~/.mastracode`, and
Antigravity CLI `~/.gemini` (only `HOME` moves it).
Providers whose config directory is missing are skipped (Claude's
`settings.json` is created).
`install-claude-hooks.sh [install|uninstall]` runs `manage-provider.sh
install|uninstall claude`.

`manage-provider.sh found <provider>` exits 0 when that agent is installed,
meaning its config directory exists (for Claude, the directory holding its
`settings.json`; for pi, a set `PI_EXTENSIONS_DIR` also counts; for Gemini
CLI, which shares `~/.gemini` with Antigravity, its `settings.json` or the
`installation_id` it writes when it first runs; for Antigravity CLI,
`~/.gemini/antigravity-cli`). It exits 1
when the agent is not installed, and 2 on a usage error (an unknown action or
provider). A bare `manage-provider.sh install|uninstall` uses it to pick the
agents to hook up. paddock's installer depends on it too. On a first install
in a terminal, it reads `@agent-scripts-dir`, finds `manage-provider.sh`
beside it and runs `found claude`. Exit 2 means this agent-status.tmux can't
list agents. Otherwise it runs `manage-provider.sh install`, which finds the
agents and asks before hooking them up. So keep `found` and its exit
statuses stable.
