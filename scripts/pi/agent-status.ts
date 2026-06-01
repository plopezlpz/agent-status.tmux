/**
 * agent-status.tmux — pi adapter.
 *
 * Maps pi lifecycle events to the plugin's per-pane tmux state scripts so pi
 * panes get the same window icon, notifications, and navigator cards as Claude
 * Code panes. Reuses set-state.sh / clear-state.sh (single source of truth);
 * this file only translates events to state names. No-op outside tmux.
 *
 * Install via ../../install-pi-extension.sh (symlinks this into
 * ~/.pi/agent/extensions/).
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	// set-state.sh keys state by $TMUX_PANE; nothing to do outside tmux.
	if (!process.env.TMUX_PANE) return;

	// Resolve the state-scripts dir once. The tmux entrypoint advertises it as
	// @agent-scripts-dir, so we avoid baked paths and stay symlink/update-safe.
	// Fall back to the conventional TPM install path if the option is unset.
	let scriptsDir: string | undefined;
	const resolveDir = async (): Promise<string> => {
		if (scriptsDir === undefined) {
			let opt = "";
			try {
				const { stdout } = await pi.exec("tmux", ["show-option", "-gqv", "@agent-scripts-dir"]);
				opt = stdout.trim();
			} catch {
				// tmux missing/unreadable — fall through to the default.
			}
			scriptsDir = opt || `${process.env.HOME}/.tmux/plugins/agent-status.tmux/scripts/agent`;
		}
		return scriptsDir;
	};

	const run = async (script: string, args: string[]): Promise<void> => {
		try {
			await pi.exec(`${await resolveDir()}/${script}`, args);
		} catch {
			// A status update must never disrupt the agent.
		}
	};

	const set = (state: string) => run("set-state.sh", [state]);

	// session_start fires on startup/new/resume/fork (reset to idle + drop the
	// previous session's auto-description) and on reload (extension hot-reload —
	// keep current state and label, don't reset mid-work).
	pi.on("session_start", async (event) => {
		if (event.reason !== "reload") {
			await set("idle");
			await run("auto-desc.sh", ["clear"]);
		}
	});

	// Capture the session's first prompt as the default navigator label
	// (auto-desc.sh only writes once per session; the navigator ignores it when
	// a Ctrl-E override exists).
	pi.on("before_agent_start", async (event) => {
		if (event.prompt) await run("auto-desc.sh", ["set", event.prompt]);
	});

	pi.on("agent_start", async () => {
		await set("working");
	});

	pi.on("agent_end", async () => {
		await set("finished");
	});

	// session_shutdown fires on real quit AND on session replacement
	// (new/resume/fork) and reload. Only a real quit should clear state — the
	// others keep the pane registered (session_start re-idles it). A truly
	// closed pane is cleaned up by the tmux pane-exited hook.
	pi.on("session_shutdown", async (event) => {
		if (event.reason === "quit") await run("clear-state.sh", []);
	});
}
