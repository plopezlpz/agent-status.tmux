# agent-status.tmux

Live status indicators and a navigator popup for AI coding agent panes
([Claude Code] and [pi]) in tmux.

- Per-pane state: **working / asking / finished / idle** driven by agent
  events (Claude Code hooks, pi extension)
- Per-window aggregated icon in your tmux status line (worst state wins)
- Clickable macOS notifications (via `terminal-notifier`) that switch
  tmux to the pane that asked for input or finished a task — `notify-send`
  fallback on Linux
- `prefix A` popup: one card per live agent pane, grouped by
  `session · folder`, auto-labeled from each session's first prompt
  (`Ctrl-E` to override)

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

For [pi] panes, symlink the extension into pi's extensions directory instead
(one time, idempotent):

```bash
bash ~/.tmux/plugins/agent-status.tmux/install-pi-extension.sh
```

Restart `pi` (or run `/reload` in a running session) to activate it. pi panes
show **working / finished / idle**. pi runs without permission prompts by
default, so there is no **asking** state out of the box; if you run a
permission-gate extension, emit it yourself around the prompt:

```ts
const dir = (await pi.exec("tmux", ["show-option", "-gqv", "@agent-scripts-dir"])).stdout.trim();
await pi.exec(`${dir}/set-state.sh`, ["asking"]);   // before ctx.ui.confirm(...)
await pi.exec(`${dir}/set-state.sh`, ["working"]);  // after it returns
```

Finally, add the icon to your `window-status-format` (and current-format):

```tmux
setw -g window-status-format         "#[fg=...] #{?@agent-icon,#{@agent-icon} ,}#I:#W "
setw -g window-status-current-format "#[fg=...] #{?@agent-icon,#{@agent-icon} ,}#I:#W "
```

Reload tmux (`prefix r` if your config has the binding, else
`tmux source ~/.tmux.conf`) and start a Claude or pi session — the icon
should appear next to the window name when an agent is running.

## Uninstall

```bash
bash ~/.tmux/plugins/agent-status.tmux/uninstall-claude-hooks.sh   # Claude Code
bash ~/.tmux/plugins/agent-status.tmux/uninstall-pi-extension.sh   # pi
```

Then remove the TPM plugin line and uninstall via TPM (`prefix + alt + u`).

## Requirements

| Dep | Minimum | Notes |
|---|---|---|
| tmux | 3.3 | needs `display-popup -E` |
| fzf | 0.45 | needs the `transform` action |
| Bash | 3.2 | macOS default, fine |
| jq | any | required by the install script only |
| Claude Code | 2.1.x | needs `PostToolUse`, `PermissionRequest`/`PermissionDenied`, and `SessionEnd` (with `.reason`) hooks |
| pi | 0.78 | optional; uses `session_start` / `agent_start` / `agent_end` / `session_shutdown` events |
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
| `@agent-scripts-dir`       | `<plugin>/scripts/agent` | where agent adapters find the state scripts; set by the plugin, read by the pi extension |

## Architecture

```
Claude Code hooks (settings.json)
        ↓ SessionStart / UserPromptSubmit / PreToolUse / PostToolUse /
        ↓ Stop / PermissionRequest / PermissionDenied / SessionEnd
    set-state.sh / clear-state.sh
        ↓ writes <state-dir>/<pane_id>
        ↓ calls update-window-icon.sh
    update-window-icon.sh
        ↓ aggregates worst state across all panes in window
        ↓ sets window-scoped @agent-icon option
    tmux status format
        ↓ reads @agent-icon directly (no shell fork per render)
```

**pi** is driven instead by an auto-discovered TypeScript extension
(`scripts/pi/agent-status.ts`, symlinked by `install-pi-extension.sh`). It maps
pi's `session_start` / `agent_start` / `agent_end` / `session_shutdown` events
to the same `set-state.sh` / `clear-state.sh`, so everything downstream (icon,
notifications, navigator) is shared. It clears state only on a real `quit`
(reason guard), keeping the pane registered through `/new`, `/resume`, `/fork`,
and `/reload`. The extension locates the scripts via the `@agent-scripts-dir`
tmux option, so no path is baked in.

Plus:
- `clear-finished.sh` (tmux `pane-focus-in` hook): demotes `finished`
  → `idle` when you visit the pane.
- `clear-pane.sh` (tmux `pane-exited` hook): drops the state file when
  a pane dies and re-aggregates the window icon.

Two non-obvious transitions:
- **`asking` → `working`**: Claude Code has no "permission answered"
  hook, so the pane is carried back to `working` by `PostToolUse` (after
  an approved tool runs) and by `PermissionDenied` (after a rejected
  prompt — the turn continues). Without these the question-mark icon
  would linger until the next tool call or `Stop`.
- **`SessionEnd` only clears on a real exit**: `clear-state.sh` reads the
  SessionEnd `reason`. `/clear` and `/resume` keep the session (and pane)
  alive, so the state is *kept*; real exits (`other`/`logout`/
  `prompt_input_exit`/`bypass_permissions_disabled`) delete it. A truly
  closed pane is still cleaned up by the `pane-exited` hook.

> Hook *registrations* load at session start, so after
> `install-claude-hooks.sh` restart any already-running Claude sessions to
> pick up the state hooks. (`clear-state.sh` changes take effect
> immediately — the `SessionEnd` hook re-invokes the script each time.)
- `focus-pane.sh`: target of `terminal-notifier -execute`, performs
  `switch-client + select-window + select-pane`.
- `agent-sessions.sh`: the fzf navigator popup. Each card shows your `Ctrl-E`
  description if set, else an auto-default derived from the session's first
  prompt (trimmed to one short line), else a placeholder. The auto-default is
  captured on the first prompt and regenerated each new session; it lives in
  `<state-dir>/<pane_id>.desc` (transient, written by `auto-desc.sh` — wired via
  Claude `UserPromptSubmit`/`SessionStart` hooks and the pi extension).

## Why one state file per pane?

So multiple agent instances in one window each keep their own state and
list as distinct navigator cards; the window icon shows the worst of them
(asking > working > finished > idle).

## License

MIT — see [LICENSE](./LICENSE).

[Claude Code]: https://github.com/anthropics/claude-code
[pi]: https://github.com/earendil-works/pi
[TPM]: https://github.com/tmux-plugins/tpm
