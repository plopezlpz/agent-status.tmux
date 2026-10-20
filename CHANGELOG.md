# Changelog

Notable changes to agent-status.tmux, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.5.0] - 2026-10-20

### Added

- Codex support. `manage-provider.sh install codex` adds hooks to `${CODEX_HOME:-~/.codex}/hooks.json`. Codex runs a hook only after you trust it (`/hooks`), so the installer edits the file in place and other tools' hooks keep the place Codex trusts them by.
- Codex: a permission prompt, a question from the model, or a request for more permissions (`request_permissions`) shows as asking. A prompt stays asking while parallel shell calls keep running, until its own call returns. An Esc settles idle, and a subagent that outlives its parent's turn doesn't wake the settled pane. `codex exec`, `codex review` and Codex's other headless commands are ignored.
- The README explains why a session in Codex's shared background server can't report into its pane, so in tmux Codex runs as `codex --no-daemon`.

### Changed

- A Kilo TUI attached to a `kilo daemon`, or `kilo attach`, doesn't report. Run Kilo with `KILO_NO_DAEMON=1` while a daemon runs.
- Claude Code: a session title (`--name`, `/rename`) names the pane instead of the first prompt.
- Verified with Claude Code 2.1.304, pi 1.3.0, OMP 18.12.3, OpenCode 2.0.32, Kimi Code 2.2.0, MastraCode 0.47.1, Kilo Code 7.8.15 and Codex 0.163.0. The README says which of them were checked without running a turn.
- The README no longer says that Gemini CLI and Cursor's agent lack lifecycle hooks. They have hooks, but no adapter yet.

### Fixed

- OpenCode 2.x: the adapter loads and reports again. OpenCode 2 runs every session in a shared background service, so a new TUI plugin reports from the pane's own OpenCode, for the session of the active tab. The "1 plugin failed" notice is gone. Re-run the installer to add the plugin. OpenCode 1.x keeps working from the same install.
- OpenCode 1.x: a first prompt typed on the home screen shows working, and keeps its title, instead of reading idle until the turn ends.
- OpenCode 1.x: headless runs (`opencode run`, `serve`, `acp`, ...) no longer take over the pane they start in and leave it marked finished.
- OpenCode and Kilo: rejecting a permission, dismissing a question, or pressing Esc on a `!` shell command settles the pane idle instead of finished.
- OpenCode and Kilo: a subagent's permission prompt only shows while the pane shows its session.
- Kilo: the pane is cleared when Kilo quits. Kilo's `offline` state (a lost connection waiting for you) shows as asking.
- Kilo: `kilo remote`, `kilo attach` and `kilo --log-level <level> run` are recognised as headless, and `kilo run --interactive` as interactive.
- The installer finds OpenCode and Kilo under `$XDG_CONFIG_HOME` when `OPENCODE_CONFIG_DIR` or `KILO_CONFIG_DIR` is unset.
- Kimi Code: a `kimi -p` or `kimi acp` started by another agent's tool no longer takes over that agent's pane. Kimi hides its arguments, so a kimi now reports only as the foreground job of its terminal.
- Kimi Code: the pane's title is the first prompt's text, not raw JSON.
- Kimi Code: a subagent finishing no longer marks the main agent finished, or sends a notification, while its turn is still running.
- Kimi Code: turns kimi starts by itself, such as a background task's result arriving, show as working.
- Kimi Code: `manage-provider.sh uninstall kimi` (and a reinstall) also removes our hooks after kimi has rewritten `config.toml` and dropped the integration markers.
- MastraCode: a pane no longer stays stuck on working after the first prompt, `/new` or a thread switch. State, asks, the finished notification and the clear on exit all work again.
- MastraCode: the first prompt titles the pane.
- MastraCode: Esc or Ctrl+C settles idle instead of finished, and an `ask_user` question, plan approval or sandbox-access request shows as asking.
- MastraCode: headless runs (`--prompt`, a prompt argument, `--acp`) no longer report into the pane they run in.
- MastraCode: the pane is cleared on exit even when you have your own `SessionEnd` hook. MastraCode runs only the first one, so the installer puts ours first.
- pi: an Esc settles to idle instead of showing finished and sending a notification (pi 1.1.0 or later). A `/compact` shows working while it runs.
- OMP: an Esc, including one during a retry's wait, settles to idle instead of showing finished and sending a notification.
- OMP: after a `/btw` branch, or a branch made by an extension, the session keeps reporting. Before, the pane froze and stayed listed after omp quit.
- OMP: the plan review shows asking until you answer or dismiss it (omp 18.12 or later).
- OMP: a turn left waiting on a background job that was cancelled now settles instead of staying working.
- OMP: a turn that ends in a provider error always asks and shows the error, whatever its wording.
- `manage-provider.sh install omp` installs into the profile named by `OMP_PROFILE` (else `PI_PROFILE`). Before, it reported success and omp never loaded the adapter. For `omp --profile <name>`, install with `OMP_PROFILE=<name>`.
- pi and OMP use only the start of a long prompt for the pane's title, so a huge pasted prompt no longer leaves the pane without a title.
- Claude Code: a subagent's open permission prompt no longer ends when the main thread launches or gets back another Agent call. It ends when that subagent stops (new `SubagentStop` hook) or when the foreground Agent call that ran it returns.
- Claude Code: a read-only tool that starts beside one waiting for permission no longer drops the pane from "asking".
- Claude Code: an MCP server's form or browser-URL request shows as "asking" until you answer it (new `Elicitation` and `ElicitationResult` hooks). A request that comes between turns leaves the pane as it was once answered.
- Claude Code: a sandboxed command's network-request prompt shows as "asking" (new `permission_prompt` notification hook).
- Claude Code: text pasted into the first prompt is left out of the pane title.

### Removed

- `AGENT_STATUS_OMP_RETRY_GRACE_MS`. OMP retries before it ends a turn, so the plugin no longer waits to see whether it will.

### Upgrading

Press `prefix U` and reload tmux. Then run `bash ~/.tmux/plugins/agent-status.tmux/manage-provider.sh install` and restart your agents, including running MastraCode sessions. This adds the new Claude Code hooks, the OpenCode 2.x plugin, and the new Kimi Code and MastraCode hooks, and hooks up Codex if it is installed. Hooks from 0.4.0 keep working until you do. Without the new Claude hooks, a subagent's prompt still ends when its foreground Agent call returns, but MCP forms and network prompts don't show as asking. If you run `omp --profile <name>`, install OMP with `OMP_PROFILE=<name>`. For Codex, trust its hooks once and run it as `codex --no-daemon` (see the README).

## [0.4.0] - 2026-10-20

### Added

- Adapters for OMP (Oh My Pi), OpenCode, Kilo Code, Kimi Code and MastraCode. Kilo Code support is partial because Kilo has no exit event.
- `manage-provider.sh install` lists the supported agents it finds on this machine and asks before it hooks each one up (`--yes` skips the question). `install <name>` hooks up one agent, and `uninstall` undoes it.
- `@agent-icon-in-status on` puts the icon in front of each window name.
- Per-state colours: `@agent-color-working`, `@agent-color-asking`, `@agent-color-finished`, `@agent-color-idle`.
- Automatic per-pane titles from the first prompt (`@agent-auto-description`). A title you set (`@agent-description`) still wins.
- `@agent-suggest-command` lets a UI ask pi to suggest a title. `@agent-describe-model` picks the model pi uses.
- Clickable notifications through alerter on current macOS. terminal-notifier is still used when alerter is missing. `@agent-notify-timeout` sets how long an alerter notification stays open (default 300 seconds).
- When a Claude agent-team lead finishes, its notification waits `@agent-notify-team-delay` seconds (default 10) for teammates. If the lead starts working again, the notification is dropped.
- Claude Code: `StopFailure`, `PostToolUseFailure` and the `idle_prompt` notification are hooked, and `CLAUDE_CONFIG_DIR` is honoured.
- `docs/architecture.md` lists the pane options a UI reads and what a new provider adapter has to do.

### Changed

- tmux 3.8 or later is required, and the plugin says so on older servers. The pi adapter needs pi 0.84.4 or later.
- The fzf navigator is gone, and [paddock](https://github.com/plopezlpz/paddock) is the UI. fzf is no longer a dependency.
- Agent state lives in tmux pane options instead of state files, and titles live in the `@agent-description` pane option instead of description files.
- The default icons are `●` and `○`, coloured by state, so a Nerd Font is no longer needed. A reload replaces the old glyphs.
- A state change is one tmux read and one chained write instead of about nine tmux calls, so attached clients redraw once.
- tmux computes the window icon itself (`@agent-icon-format`), and keeps it current when panes exit, split or move without starting a process.
- Claude Code: the installer quotes hook paths, keeps at most three of its own settings backups, and no longer installs the `PermissionDenied` hook. A denied prompt ends the turn like an Esc.
- No notification is raised for a pane you are already looking at: the most recently active client shows it with terminal focus. A client left attached somewhere else, such as a phone over mosh, doesn't count.
- A Claude turn that ends on an API error is notified as "failed".
- `agent.log` times are local time with a UTC offset instead of UTC.

### Fixed

- A Claude permission prompt stays "asking" while parallel tools and subagents keep firing hooks (new pane option `@agent-asks`).
- A Claude turn that ends without a Stop no longer stays "working": an API error ends it at once, and an Esc or a denied prompt settles to idle on Claude's `idle_prompt` (about 60 seconds).
- A Claude turn that leaves background subagents running stays "working" until they finish. A compaction keeps the pane's state.
- Headless Claude runs (`claude -p`, the Agent SDK) are ignored and don't take over the pane. The new adapters ignore `kilo run`, `kimi -p` and `mastracode --prompt` the same way.
- The Claude installer replaces or removes hooks written under the old `claude-agent-status.tmux` name.
- A window drops the icon of an agent pane that exited or was killed, and a pane exit no longer clears the newly focused pane's state.
- Clicking a notification focuses a local client and never a remote one, such as a phone. A click for a pane that no longer exists is ignored.
- `@agent-scripts-dir` follows a moved checkout.
- Reloading from a checkout under any directory name never duplicates the plugin's tmux hooks.

### Removed

- The `prefix A` navigator popup and its options `@agent-navigator-key`, `@agent-popup-width` and `@agent-popup-height`.
- `@agent-state-dir` and `@agent-descriptions-dir`.
- `install-pi-extension.sh`, `uninstall-pi-extension.sh` and `uninstall-claude-hooks.sh`. Use `manage-provider.sh install|uninstall pi|claude` instead.

### Upgrading

Press `prefix U` and reload tmux. Then run `bash ~/.tmux/plugins/agent-status.tmux/manage-provider.sh install` and restart your agents. Hooks you already installed keep working until you do this. Remove any `@agent-navigator-key`, `@agent-popup-*`, `@agent-state-dir` and `@agent-descriptions-dir` settings, and install [paddock](https://github.com/plopezlpz/paddock) if you want a popup.

## [0.3.0] - 2026-06-01

### Added

- pi support: an extension shows working, finished and idle for pi panes. Install it with `install-pi-extension.sh` and remove it with `uninstall-pi-extension.sh`.
- `@agent-scripts-dir`, so agent adapters can find the state scripts.
- Claude Code: `PermissionDenied` is hooked, so a pane leaves "asking" when you deny a prompt.

### Changed

- The README and the `prefix A` key's description say "agent" instead of "Claude".

### Upgrading

Run `install-claude-hooks.sh` again to add the `PermissionDenied` hook.

## [0.2.3] - 2026-05-29

### Fixed

- A Claude pane leaves "asking" as soon as the approved tool finishes (new `PostToolUse` hook).
- `/clear` and `/resume` no longer remove the pane from the navigator. Only a real exit clears it.

### Upgrading

Run `install-claude-hooks.sh` again to add the `PostToolUse` hook.

## [0.2.2] - 2026-05-29

### Changed

- The README states the correct fzf requirement: only the `transform` action is needed.

## [0.2.1] - 2026-05-29

### Changed

- State files move to `${TMUX_TMPDIR:-/tmp}/agent-status-<uid>`. They are per user and cleared on reboot.
- Descriptions and `agent.log` move to `${XDG_DATA_HOME:-~/.local/share}/tmux/agent-status`.

### Upgrading

Descriptions under `~/.cache/agent-status` are not moved. Move them yourself, or set `@agent-descriptions-dir` to the old path.

## [0.2.0] - 2026-05-29

### Changed

- The plugin is renamed from claude-agent-status.tmux to agent-status.tmux (`plopezlpz/agent-status.tmux`).
- Options are renamed from `@claude-agent-*` to `@agent-*`, and the window icon from `@claude-agent-icon` to `@agent-icon`.
- Default paths: the state directory is `/tmp/agent-state`, and descriptions and the log live in `~/.cache/agent-status`.
- Notifications are titled "Agent • <state>".

### Upgrading

1. Change your TPM line to `set -g @plugin 'plopezlpz/agent-status.tmux'`.
2. Rename your `@claude-agent-*` settings to `@agent-*`, and use `@agent-icon` in your window status formats.
3. Run `uninstall-claude-hooks.sh` from the old checkout, then run `install-claude-hooks.sh` from the new one.

## [0.1.3] - 2026-05-29

### Fixed

- The navigator jumps to windows whose names contain dots.
- The navigator's describe and refresh keys work when the plugin path contains spaces.
- A state file without a trailing newline is no longer dropped from the window icon.

## [0.1.2] - 2026-05-28

### Fixed

- The Claude hooks installer no longer crashes on settings where a hook entry has no `hooks` list.
- Reloading tmux no longer duplicates the plugin's hooks, and it cleans up duplicates left by 0.1.0 and 0.1.1.
- A pane exit is written to `agent.log`.
- A pane exit outside an agent window no longer redraws every client.
- The navigator keeps panes whose state file has no trailing newline.

## [0.1.1] - 2026-05-28

### Fixed

- The installer no longer crashes when `"hooks"` is an array, and it keeps other tools' commands that share a hook entry.
- Descriptions stay with the right pane when window names contain `|` or spaces.
- The plugin turns on `focus-events`, so visiting a finished pane marks it idle.
- The plugin appends its tmux hooks instead of replacing yours.
- Notification clicks work for session names and plugin paths with spaces.

## [0.1.0] - 2026-05-28

### Added

- Per-pane working, asking, finished and idle state, driven by Claude Code hooks.
- A window icon in the status line that shows the worst state in the window.
- Clickable notifications on macOS (terminal-notifier) that switch to the pane, and `notify-send` on Linux.
- `prefix A` navigator popup: one card per Claude pane, grouped by session and folder, with editable descriptions.
- `install-claude-hooks.sh` and `uninstall-claude-hooks.sh`.

[Unreleased]: https://github.com/plopezlpz/agent-status.tmux/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/plopezlpz/agent-status.tmux/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/plopezlpz/agent-status.tmux/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/plopezlpz/agent-status.tmux/compare/v0.2.3...v0.3.0
[0.2.3]: https://github.com/plopezlpz/agent-status.tmux/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/plopezlpz/agent-status.tmux/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/plopezlpz/agent-status.tmux/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/plopezlpz/agent-status.tmux/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/plopezlpz/agent-status.tmux/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/plopezlpz/agent-status.tmux/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/plopezlpz/agent-status.tmux/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/plopezlpz/agent-status.tmux/releases/tag/v0.1.0
