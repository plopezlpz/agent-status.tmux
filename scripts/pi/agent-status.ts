/**
 * agent-status.tmux — pi lifecycle adapter.
 *
 * Agent events are serialized into the plugin's shared pane-state scripts;
 * status failures never affect the agent itself. No-op outside tmux.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	if (!process.env.TMUX_PANE) return;

	let scriptsDir: string | undefined;
	let instance = "";
	let seq = Date.now() * 1000;
	let rootSession = false;
	let agentActive = false;
	let blockedCount = 0;
	let lastState = "";
	let transcript = "";
	let queue = Promise.resolve();
	// Bound every status command; a blocked script must not stall the queue.
	const execOptions = { timeout: 5000 };

	const resolveDir = async (): Promise<string> => {
		if (scriptsDir === undefined) {
			let opt = "";
			try {
				const { stdout } = await pi.exec("tmux", ["show-option", "-gqv", "@agent-scripts-dir"], execOptions);
				opt = stdout.trim();
			} catch {
				// Fall through to the conventional TPM path.
			}
			scriptsDir = opt || `${process.env.HOME}/.tmux/plugins/agent-status.tmux/scripts/agent`;
		}
		return scriptsDir;
	};

	const run = (script: string, args: string[]): Promise<void> => {
		const next = queue.then(async () => {
			try {
				await pi.exec(`${await resolveDir()}/${script}`, args, execOptions);
			} catch {
				// A status update must never disrupt the agent.
			}
		});
		queue = next;
		return next;
	};

	const updateInstance = (ctx: any): void => {
		try {
			instance = ctx?.sessionManager?.getSessionId?.() || instance;
		} catch {
			// Keep the last known identity.
		}
	};

	const tmux = (args: string[]): Promise<void> => {
		const next = queue.then(async () => {
			try {
				await pi.exec("tmux", args, execOptions);
			} catch {
				// A status update must never disrupt the agent.
			}
		});
		queue = next;
		return next;
	};

	// Record the session file on the pane so the navigator's ctrl-g can read the
	// conversation (latest prompts) when generating a description. A new session
	// without a file yet unsets the previous session's path.
	const updateTranscript = (ctx: any, unsetMissing = false): Promise<void> => {
		let file = "";
		try {
			file = ctx?.sessionManager?.getSessionFile?.() || "";
		} catch {
			return Promise.resolve();
		}
		if (!file && unsetMissing) return tmux(["set-option", "-p", "-u", "-t", process.env.TMUX_PANE!, "@agent-transcript"]);
		if (!file || file === transcript || !file.endsWith(".jsonl")) return Promise.resolve();
		transcript = file;
		return tmux(["set-option", "-p", "-t", process.env.TMUX_PANE!, "@agent-transcript", file]);
	};

	const set = (state: string, message = "", reset = false): Promise<void> => {
		if (!reset && state === lastState) return Promise.resolve();
		lastState = state;
		return run("set-state.sh", [state, message, instance, String(++seq), "pi", reset ? "reset" : ""]);
	};

	// The pane's registration and sequence, read in one tmux call.
	const paneState = async (): Promise<{ state: string; seq: number }> => {
		try {
			const { stdout } = await pi.exec("tmux", [
				"display", "-p", "-t", process.env.TMUX_PANE!, "#{@agent-state}\t#{@agent-seq}",
			], execOptions);
			const [state = "", paneSeq = ""] = stdout.replace(/\n$/, "").split("\t");
			return { state, seq: /^[0-9]+$/.test(paneSeq) ? Number(paneSeq) : 0 };
		} catch {
			return { state: "", seq: 0 };
		}
	};

	pi.on("session_start", async (event, ctx) => {
		// Only the interactive TUI owns a visible tmux pane. Print/RPC modes can
		// inherit TMUX_PANE but must not register as the pane's active agent.
		if (ctx?.mode !== "tui") return;
		rootSession = true;
		updateInstance(ctx);
		agentActive = ctx?.isIdle?.() === false;
		if (event.reason === "reload") {
			// Reload normally preserves state, but must repair a missing pane option
			// (for example after upgrading from the old file-backed release). The
			// restarted clock must not fall behind the pane's accepted sequence.
			const pane = await paneState();
			seq = Math.max(seq, pane.seq + 1);
			if (!pane.state) await set(agentActive ? "working" : "idle", "", true);
			await updateTranscript(ctx);
			return;
		}
		agentActive = false;
		blockedCount = 0;
		await set("idle", "", true);
		await run("auto-desc.sh", ["clear", "pi"]);
		transcript = "";
		await updateTranscript(ctx, true);
	});

	// Turn-path handlers queue their updates without awaiting them, so a slow
	// status script never delays the agent; the queue preserves their order.
	pi.on("before_agent_start", (event) => {
		if (rootSession && event.prompt) void run("auto-desc.sh", ["set", event.prompt]);
	});

	pi.on("agent_start", (_event, ctx) => {
		if (!rootSession) return;
		updateInstance(ctx);
		agentActive = true;
		void set("working");
		void updateTranscript(ctx);
	});

	pi.on("ui_prompt_start", (event) => {
		if (!rootSession) return;
		blockedCount += 1;
		void set("asking", event.title || "");
	});

	pi.on("ui_prompt_end", () => {
		if (!rootSession) return;
		blockedCount = Math.max(0, blockedCount - 1);
		if (blockedCount === 0) void set(agentActive ? "working" : "idle");
	});

	pi.on("agent_settled", (_event, ctx) => {
		if (!rootSession || ctx?.isIdle?.() !== true) return;
		agentActive = false;
		void set("finished");
	});

	pi.on("session_shutdown", async (event) => {
		if (rootSession && event.reason === "quit") await run("clear-state.sh", ["quit", instance, "pi"]);
	});
}
