# agent-status.tmux

Live status indicators and a navigator popup for [Claude Code] panes in tmux.

- Per-pane state: **working / asking / finished / idle** driven by Claude
  Code hooks
- Per-window aggregated icon in your tmux status line (worst state wins)
- Clickable macOS notifications (via `terminal-notifier`) that switch
  tmux to the pane that asked for input or finished a task — `notify-send`
  fallback on Linux
- `prefix A` popup: one card per live Claude pane, grouped by
  `session · folder`, with editable per-pane descriptions

## Install

With [TPM]:

```tmux
set -g @plugin 'plopezlpz/agent-status.tmux'
run '~/.tmux/plugins/tpm/tpm'
```

`prefix + I` to install.

Then wire the plugin into Claude Code's hooks (one time, idempotent):

```bash
bash ~/.tmux/plugins/agent-status.tmux/install-claude-hooks.sh
```

Finally, add the icon to your `window-status-format` (and current-format):

```tmux
setw -g window-status-format         "#[fg=...] #{?@agent-icon,#{@agent-icon} ,}#I:#W "
setw -g window-status-current-format "#[fg=...] #{?@agent-icon,#{@agent-icon} ,}#I:#W "
```

Reload tmux (`prefix r` if your config has the binding, else
`tmux source ~/.tmux.conf`) and start a Claude session — the icon
should appear next to the window name when Claude is running.

## Uninstall

```bash
bash ~/.tmux/plugins/agent-status.tmux/uninstall-claude-hooks.sh
```

Then remove the TPM plugin line and uninstall via TPM (`prefix + alt + u`).

## Requirements

| Dep | Minimum | Notes |
|---|---|---|
| tmux | 3.3 | needs `display-popup -E` |
| fzf | 0.45 | needs the `transform` action |
| Bash | 3.2 | macOS default, fine |
| jq | any | required by the install script only |
| Claude Code | 2.1.x | needs `PermissionRequest` and `SessionEnd` hooks |
| Nerd Font | any | for the default glyphs — override via options if you don't have one |
| terminal-notifier | macOS | optional, for clickable notifications |
| notify-send | Linux | optional Linux fallback |

## Configuration

All options set before `run ~/.tmux/plugins/tpm/tpm` will override the
defaults below. Set with `set -g @agent-...`.

### Icons (per state)

| Option | Default | Description |
|---|---|---|
| `@agent-icon-working`  | `󱐋` | Tool call in flight |
| `@agent-icon-asking`   | `󰘥` | Permission request waiting |
| `@agent-icon-finished` | `󰗠` | Stop hook fired, awaiting your focus |
| `@agent-icon-idle`     | `󱚣` | Session started, no activity |

The aggregated worst-state icon is exposed as the **window-scoped**
option `@agent-icon`. Reference it in your status format like:

```tmux
#{?@agent-icon,#{@agent-icon} ,}
```

### Behavior

| Option | Default | Description |
|---|---|---|
| `@agent-navigator-key` | `A` | Suffix key after `prefix` to open the popup |
| `@agent-popup-width`   | `70%` | `display-popup -w` value |
| `@agent-popup-height`  | `70%` | `display-popup -h` value |
| `@agent-terminal-app`  | `''` | macOS app to bring forward on notification click (e.g. `Ghostty`, `iTerm`) |

### Paths

| Option | Default | Description |
|---|---|---|
| `@agent-state-dir`         | `${TMUX_TMPDIR:-/tmp}/agent-status-<uid>` | per-pane state files (`<state_dir>/<pane_id>`); transient, reboot-cleared |
| `@agent-descriptions-dir`  | `${XDG_DATA_HOME:-$HOME/.local/share}/tmux/agent-status/descriptions` | navigator descriptions |
| `@agent-log`               | `${XDG_DATA_HOME:-$HOME/.local/share}/tmux/agent-status/agent.log` | state-transition audit log |

## Architecture

```
Claude Code hooks (settings.json)
        ↓ SessionStart / UserPromptSubmit / PreToolUse / PostToolUse /
        ↓ Stop / PermissionRequest / SessionEnd
    set-state.sh / clear-state.sh
        ↓ writes <state-dir>/<pane_id>
        ↓ calls update-window-icon.sh
    update-window-icon.sh
        ↓ aggregates worst state across all panes in window
        ↓ sets window-scoped @agent-icon option
    tmux status format
        ↓ reads @agent-icon directly (no shell fork per render)
```

Plus:
- `clear-finished.sh` (tmux `pane-focus-in` hook): demotes `finished`
  → `idle` when you visit the pane.
- `clear-pane.sh` (tmux `pane-exited` hook): drops the state file when
  a pane dies and re-aggregates the window icon.

Two non-obvious transitions:
- **`asking` → `working`**: Claude Code has no "permission answered"
  hook, so `PostToolUse` (fires right after the approved tool runs)
  carries the pane back to `working`. Without it the question-mark icon
  would linger until the next tool call or `Stop`.
- **`SessionEnd` only clears on a real exit**: `clear-state.sh` reads the
  SessionEnd `reason`. `/clear` and `/resume` keep the session (and pane)
  alive, so the state is *kept*; only `other`/`logout`/etc. delete it.
  A truly closed pane is still cleaned up by the `pane-exited` hook.
- `focus-pane.sh`: target of `terminal-notifier -execute`, performs
  `switch-client + select-window + select-pane`.
- `agent-sessions.sh`: the fzf navigator popup.

## Why one state file per pane?

So multiple Claude instances in one window each keep their own state and
list as distinct navigator cards; the window icon shows the worst of them
(asking > working > finished > idle).

## License

MIT — see [LICENSE](./LICENSE).

[Claude Code]: https://github.com/anthropics/claude-code
[TPM]: https://github.com/tmux-plugins/tpm
