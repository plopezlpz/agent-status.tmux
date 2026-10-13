# agent-status.tmux

Event-driven status indicators for AI coding-agent panes in tmux, and the
agent state a UI such as [paddock](https://github.com/plopezlpz/paddock) shows.

- **working / asking / idle** state per pane; a completion you haven't seen
  yet shows as **finished**
- worst-state window icon (asking > working > finished > idle)
- clickable desktop notifications
- per-pane titles: the first prompt, or one you set or have pi suggest
- no daemon, no polling of pane output or processes

## Install

With [TPM]:

```tmux
set -g @plugin 'plopezlpz/agent-status.tmux'
run '~/.tmux/plugins/tpm/tpm'
```

Run `prefix I`, then hook up each agent you use and restart it:

```bash
bash ~/.tmux/plugins/agent-status.tmux/manage-provider.sh install claude
# providers: pi omp opencode kilo kimi mastracode claude
```

Add the icon to both window status formats:

```tmux
setw -g window-status-format         "#{?@agent-icon,#{@agent-icon} ,}#I:#W "
setw -g window-status-current-format "#{?@agent-icon,#{@agent-icon} ,}#I:#W "
```

`manage-provider.sh uninstall <provider>` undoes an install. Installers only
add or remove their own entries and refuse to overwrite files they don't own.

## Providers

| Provider | Notes | Verified with |
|---|---|---|
| pi | | 1.1.0 (needs 0.84.4+) |
| OMP (Oh My Pi) | | 18.8.9 |
| OpenCode | `tui.jsonc` must be plain JSON (comments make install refuse) | 2.0.25 |
| Kimi Code | | 2.1.1 |
| MastraCode | | not verified locally |
| Kilo Code | partial: Kilo has no exit event | not verified locally |
| Claude Code | an Esc or a denied prompt shows idle only after Claude's `idle_prompt` (about 60s) | 2.1.296 |

Agents without lifecycle hooks (Codex, Gemini, Cursor and others) are not
supported: their state can't be known without polling the pane.

Run a nested headless agent with `TMUX_PANE` cleared, or it takes over the
pane it runs in: `TMUX_PANE= claude -p ...`.

## Configuration

Set options before TPM runs.

| Option | Default |
|---|---|
| `@agent-icon-working`, `@agent-color-working` | `●`, `yellow` |
| `@agent-icon-asking`, `@agent-color-asking` | `●`, `red` |
| `@agent-icon-finished`, `@agent-color-finished` | `●`, `cyan` |
| `@agent-icon-idle`, `@agent-color-idle` | `○`, `green` |
| `@agent-terminal-app` | empty (macOS app to raise on a notification click, e.g. `Ghostty`) |
| `@agent-notify-timeout` | `300` (seconds before an alerter notification closes; `0` = never) |
| `@agent-notify-team-delay` | `10` (seconds a Claude agent-team lead's notification waits for its teammates; `0` = off) |
| `@agent-describe-model` | `openai-codex/gpt-6-luna` (pi model for suggested titles) |
| `@agent-log` | `${XDG_DATA_HOME:-$HOME/.local/share}/tmux/agent-status/agent.log` |

## Requirements

tmux 3.3, Bash 3.2, jq; optionally alerter, terminal-notifier or notify-send
for notifications, and pi for suggested titles.

## Internals

[docs/architecture.md](docs/architecture.md): the pipeline, the pane options a
UI reads, and the contract for new provider adapters.

## License

MIT, see [LICENSE](LICENSE).

[TPM]: https://github.com/tmux-plugins/tpm
