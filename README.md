# agent-status.tmux

Event-driven status indicators for AI coding-agent panes in tmux, and the
agent state a UI such as [paddock](https://github.com/plopezlpz/paddock) shows.

- **working / asking / idle** state per pane; a completion you haven't seen
  yet shows as **finished**
- worst-state window icon (asking > working > finished > idle)
- desktop notifications; a click focuses the pane (alerter or
  terminal-notifier)
- per-pane titles: the first prompt, or one you set or have pi suggest
- no daemon, no polling of pane output or processes

## Install

With [TPM]:

```tmux
set -g @plugin 'plopezlpz/agent-status.tmux'
set -g @agent-icon-in-status on   # the icon in front of each window name
run '~/.tmux/plugins/tpm/tpm'
```

Run `prefix I`, then hook up your agents and restart them:

```bash
bash ~/.tmux/plugins/agent-status.tmux/manage-provider.sh install
```

It lists the supported agents it finds on this machine and, in a terminal,
asks before hooking them up (`--yes` doesn't ask); the others are skipped.
`manage-provider.sh install claude` does just one, and `manage-provider.sh uninstall`
(with or without a name) undoes it. Installers only add or remove their own
entries and refuse to overwrite files they don't own. Codex needs more
setup: see [Codex](#codex).

TPM may keep plugins in `~/.config/tmux/plugins/` instead of
`~/.tmux/plugins/`; adjust the paths if so. Without TPM, clone the repo:

```bash
git clone https://github.com/plopezlpz/agent-status.tmux ~/.tmux/plugins/agent-status.tmux
```

and load it from your tmux config, with any options set before the
`run-shell` line:

```tmux
set -g @agent-icon-in-status on
run-shell 'bash ~/.tmux/plugins/agent-status.tmux/agent-status.tmux'
```

Then reload tmux (`tmux source-file ~/.tmux.conf`) and run the installer
above. To update a clone, run `git -C ~/.tmux/plugins/agent-status.tmux pull`,
reload tmux and run the installer again.

Rather place the icon yourself? Leave `@agent-icon-in-status` off and add
`#{?@agent-icon,#{@agent-icon} ,}` to your window status formats, e.g.:

```tmux
setw -g window-status-format         "#{?@agent-icon,#{@agent-icon} ,}#I:#W "
setw -g window-status-current-format "#{?@agent-icon,#{@agent-icon} ,}#I:#W "
```

## Update

Update with `prefix U`, reload tmux, then run the installer again so your
agents get the current hook commands, and restart them. It replaces the
entries it wrote before, and hooks from an earlier release keep working until
you do:

```bash
bash ~/.tmux/plugins/agent-status.tmux/manage-provider.sh install
```

What changed in each release: [CHANGELOG.md](CHANGELOG.md).

From 0.4.0: the installer adds the new Claude Code hooks (until then, MCP
forms and sandbox network prompts don't show as asking), the OpenCode 2.x
plugin, and the new Kimi Code and MastraCode hooks; restart running
MastraCode sessions afterwards. If you run `omp --profile <name>`, install
OMP with `OMP_PROFILE=<name>`. `AGENT_STATUS_OMP_RETRY_GRACE_MS`
(`HERDR_OMP_RETRY_GRACE_MS` before) is gone: OMP retries before it ends a
turn, so a turn that ends in an error asks at once. A Kilo TUI attached to a
`kilo daemon` doesn't report: run Kilo with `KILO_NO_DAEMON=1` while a daemon
runs. Codex is new: see [Codex](#codex).

From 0.3.0: tmux 3.8 or later is required, and fzf no longer is. The
`prefix A` navigator popup is gone ([paddock](https://github.com/plopezlpz/paddock)
is the UI now). Its options went with it: `@agent-navigator-key`,
`@agent-popup-width` and `@agent-popup-height`. `@agent-state-dir` and
`@agent-descriptions-dir` are gone too, because state and titles now live in
pane options. Descriptions you saved in the navigator are not carried over.
A running tmux server keeps the old binding until it restarts. `tmux unbind A`
drops it now; if you changed `@agent-navigator-key`, unbind that key instead.
If you never changed the icons, the old Nerd Font defaults become `●`/`○` on
reload.

Older releases' `install-pi-extension.sh`, `uninstall-pi-extension.sh` and
`uninstall-claude-hooks.sh` are gone: use `manage-provider.sh install pi`,
`manage-provider.sh uninstall pi` and `manage-provider.sh uninstall claude`.
OMP no longer reads `HERDR_OMP_IDLE_DEBOUNCE_MS`: set
`AGENT_STATUS_OMP_IDLE_DEBOUNCE_MS` instead. `@agent-log` lines now carry the
tmux server's local time with its UTC offset (`2026-10-20T11:09:03+0300`)
instead of UTC (`...Z`).

## Uninstall

First, while the plugin is still installed, remove its hooks and extensions
from every agent it finds:

```bash
bash ~/.tmux/plugins/agent-status.tmux/manage-provider.sh uninstall
```

Then remove the `@plugin 'plopezlpz/agent-status.tmux'` line (and any
`@agent-*` options) from your tmux config, and press `prefix alt-u` to have
TPM delete the plugin. Restart tmux to drop the plugin's hooks and
window-status format changes from the running server, and restart any running
agents.

## Providers

| Provider | Notes | Verified with |
|---|---|---|
| pi | before 1.1.0 an Esc shows as finished | 1.1.0, 1.3.0 (needs 0.84.4+; 1.3 turns not run live) |
| OMP (Oh My Pi) | with `omp --profile <name>`, install with `OMP_PROFILE=<name>`; a dialog from an extension or MCP server shows as working | 18.8.9, 18.12.3 (18.12 turns not run live) |
| OpenCode | 1.x: `tui.jsonc` must be plain JSON (comments make install refuse). 2.x: the pane shows the active tab's session; `opencode mini` doesn't report | 1.19.3, 2.0.32 (2.x turns not run live) |
| Kimi Code | shows from the first message (or `/title`, `/new`, a resumed session); a question the model asks in the background shows as working, or finished once the turn ends; a kimi killed by a signal stays listed until the pane's next agent starts | 2.2.0 (no turn run) |
| MastraCode | runs only the first `SessionEnd` hook, so the installer puts its own first | 0.47.1 (no turn run) |
| Kilo Code | a TUI attached to a `kilo daemon`, or `kilo attach`, doesn't report: run it with `KILO_NO_DAEMON=1` while a daemon runs; suggestion and network prompts don't show as asking | 7.8.15 (no turn run) |
| Claude Code | an Esc or a denied prompt shows idle only after Claude's `idle_prompt` (about 60s); an approved tool shows asking until it returns; a turn that ends while a cloud session runs for it shows finished | 2.1.296, 2.1.304 (2.1.304 turns not run live) |
| Codex | run it as `codex --no-daemon` and trust its hooks once (see below); shows from the first prompt; a turn that ends in an error stays working until the next prompt | 0.163.0 (no turn run) |

Other agents, such as Gemini CLI and Cursor's agent, have no adapter yet.
Agents without lifecycle hooks can't have one: their state can't be known
without polling the pane.

Headless runs (`claude -p` and the Agent SDK, pi and OMP outside their TUI,
`opencode run`, `serve` and OpenCode's other non-interactive commands, the
same for Kilo (`kilo run`, `serve`, `remote`, ...), `kimi -p` or `kimi acp`
run by another agent, `mastracode --prompt`, a prompt argument or `--acp`,
`codex exec`, `codex review` and Codex's other non-interactive commands) are
ignored. Kimi hides its arguments, so a kimi reports only as the foreground
job of its terminal: a `kimi -p` or `kimi acp` you start yourself in a shell
or an editor reports into that pane. Run any other nested headless agent
with `TMUX_PANE` cleared, or it takes over the pane it runs in. Claude keeps
the `CLAUDE_CODE_ENTRYPOINT` it inherits, so a `claude` started where that is
`sdk-*` (say, from a shell or tmux server that a headless run started)
doesn't report either.

### Codex

Codex runs a hook only once you have trusted it. After installing (and after
an update that changes a hook), Codex says "Hooks need review" when it starts:
choose "Review hooks", or run `/hooks`, and trust the `hook-event.sh` ones.

By default (since 0.157) every `codex` attaches to one shared background
server that runs its session, and so its hooks. A hook there has the
environment of whichever terminal started the server, and its payload names
no terminal, so it can't tell which pane is its own; it reports nothing.
Nothing else ties a session to its pane: its working directory may be that
of several panes; its id is in the pane title only if you add `thread-id` to
Codex's `tui.terminal_title`; and the server ends it only 30 minutes (by
default) after its `codex` quits, so the pane would go on showing Codex that long. Run Codex in
tmux without the server, e.g. with an alias:

```bash
alias codex='codex --no-daemon'
```

`codex agents` and `codex --remote` need that server and refuse
`--no-daemon`: with the alias, run them as `command codex agents`.

The installer edits `${CODEX_HOME:-~/.codex}/hooks.json` in place, so other
tools' hooks keep the place Codex trusts them by. Uninstalling moves up any
hook added after ours, and Codex asks to review those again. The file is
written in jq's layout (2-space indent), so a file formatted otherwise is
reformatted; the old file is kept as `hooks.json.bak-*`.

Codex hooks can't tell everything apart:

- With Auto-review (`approvals_reviewer = "auto_review"`), Codex announces
  each escalated command to the hooks before its reviewer decides, so the
  pane shows asking, and notifies, while nobody is asked.
- On macOS, a prompt given on the command line whose first word is a
  subcommand's name (`codex "review my change"`) reads as that headless
  subcommand, and the session doesn't report. Type the first prompt in
  Codex instead. Linux reads the real arguments from `/proc`.

## Configuration

Set options before TPM runs.

| Option | Default |
|---|---|
| `@agent-icon-working`, `@agent-color-working` | `●`, `yellow` |
| `@agent-icon-asking`, `@agent-color-asking` | `●`, `red` |
| `@agent-icon-finished`, `@agent-color-finished` | `●`, `cyan` |
| `@agent-icon-idle`, `@agent-color-idle` | `○`, `green` |
| `@agent-icon-in-status` | `off` (`on`: put the icon in front of both window status formats; set your own formats before the plugin loads) |
| `@agent-terminal-app` | empty (macOS app to raise on a notification click, e.g. `Ghostty`) |
| `@agent-notify-timeout` | `300` (seconds before an alerter notification closes; `0` = never) |
| `@agent-notify-team-delay` | `10` (seconds a Claude agent-team lead's notification waits for its teammates; `0` = off) |
| `@agent-describe-model` | `openai-codex/gpt-6-luna` (pi `--model` pattern for suggested titles; pick a model your pi has credentials for) |
| `@agent-log` | `${XDG_DATA_HOME:-$HOME/.local/share}/tmux/agent-status/agent.log` |

The plugin turns on tmux's `focus-events` every time it loads, overriding
`focus-events off`: focusing a pane is what clears its finished marker. An
empty `@agent-color-*` shows that state's icon uncoloured.

## Requirements

tmux 3.8, Bash 3.2, jq; optionally alerter, terminal-notifier or notify-send
for notifications (the first one found is used; notify-send's can't be
clicked), and pi for suggested titles.

## Internals

[docs/architecture.md](docs/architecture.md): the pipeline, the pane options a
UI reads, and the contract for new provider adapters.

## License

MIT, see [LICENSE](LICENSE).

[TPM]: https://github.com/tmux-plugins/tpm
