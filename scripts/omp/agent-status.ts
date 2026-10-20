/** agent-status.tmux — OMP lifecycle adapter. */
// @ts-nocheck
import { realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Installed as a symlink to the plugin checkout: run that checkout's scripts.
const scriptsDir = resolve(dirname(realpathSync(fileURLToPath(import.meta.url))), "../agent");

const retryable = /overloaded|provider.?returned.?error|rate.?limit|too many requests|429|500|502|503|504|service.?unavailable|server.?error|internal.?error|network.?error|connection.?error|connection.?refused|connection.?lost|websocket.?closed|websocket.?error|other side closed|fetch failed|upstream.?connect|reset before headers|socket hang up|ended without|http2 request did not get a response|timed? out|timeout|terminated|retry delay/i;
// AGENT_STATUS_OMP_<NAME> milliseconds, else FALLBACK.
const duration = (name: string, fallback: number) => {
	const n = Number.parseInt(process.env[`AGENT_STATUS_OMP_${name}`] || "", 10);
	return Number.isFinite(n) && n >= 0 ? n : fallback;
};

export default function (pi) {
	if (!process.env.TMUX_PANE) return;
	let instance = "", seq = Date.now() * 1000, root = false, active = false;
	let blocked = 0, blockedMessage = "", retryHold = false, failure = false, failureMessage = "";
	// announced: completion already published, so later blocker churn settles idle.
	let lastState = "", lastMessage = "", announced = true, idleTimer: any, retryTimer: any;
	let queue = Promise.resolve();
	// Bound every status command; a blocked script must not stall the queue.
	const execOptions = { timeout: 5000 };
	const run = (script: string, args: string[]) => {
		queue = queue.then(async () => { try { await pi.exec(`${scriptsDir}/${script}`, args, execOptions); } catch {} });
		return queue;
	};
	const updateInstance = (ctx: any) => { try { instance = ctx?.sessionManager?.getSessionId?.() || instance; } catch {} };
	const desired = () => blocked ? ["asking", blockedMessage] : failure ? ["asking", failureMessage] : active || retryHold ? ["working", ""] : [announced ? "idle" : "finished", ""];
	const publish = (force = false, reset = false) => {
		const [state, message] = desired();
		if (!force && state === lastState && message === lastMessage) return Promise.resolve();
		lastState = state; lastMessage = message;
		if (state === "finished") announced = true;
		return run("set-state.sh", [state, message, instance, String(++seq), "omp", reset ? "reset" : ""]);
	};
	const clearIdleTimer = () => { if (idleTimer) clearTimeout(idleTimer); idleTimer = undefined; };
	const clearTimers = () => { if (idleTimer) clearTimeout(idleTimer); if (retryTimer) clearTimeout(retryTimer); idleTimer = retryTimer = undefined; };
	const clearFailure = () => { retryHold = failure = false; failureMessage = ""; };
	const clearBlocked = () => { blocked = 0; blockedMessage = ""; };
	const activate = (ctx: any, reset = false) => {
		if (ctx?.hasUI !== true) return false;
		root = true; updateInstance(ctx);
		if (reset) { clearTimers(); clearFailure(); clearBlocked(); active = false; announced = true; }
		return true;
	};
	// Keep a pending retry expiry: only the idle debounce yields to a blocker.
	const block = (message = "waiting for user input") => { clearIdleTimer(); blocked += 1; blockedMessage = message; return publish(); };
	const unblock = () => { blocked = Math.max(0, blocked - 1); if (!blocked) blockedMessage = ""; return publish(); };

	pi.events.on("herdr:blocked", (data: any) => { if (root) void (data?.active ? block(data.label) : unblock()); });
	// OMP emits session_start once at startup and session_switch for /new,
	// /fork and /resume; each idle selection starts without the old label.
	pi.on("session_start", (_e, ctx) => {
		if (!activate(ctx)) return;
		active = ctx?.isIdle?.() === false;
		if (active) void publish(true, true);
		else {
			lastState = "idle"; lastMessage = ""; announced = true;
			void run("set-state.sh", ["idle", "", instance, String(++seq), "omp", "reset"]);
			void run("auto-desc.sh", ["clear", "omp"]);
		}
	});
	pi.on("session_switch", (_e, ctx) => {
		if (!activate(ctx, true)) return;
		lastState = "idle"; lastMessage = "";
		void run("set-state.sh", ["idle", "", instance, String(++seq), "omp", "reset"]);
		void run("auto-desc.sh", ["clear", "omp"]);
	});
	pi.on("before_agent_start", (e) => { if (root && e?.prompt) void run("auto-desc.sh", ["set", e.prompt]); });
	pi.on("agent_start", (_e, ctx) => { if (!root && !activate(ctx)) return; updateInstance(ctx); clearTimers(); clearFailure(); clearBlocked(); active = true; announced = false; void publish(); });
	pi.on("tool_approval_requested", (e, ctx) => { if (root || activate(ctx)) void block(e?.reason || `${e?.toolName || "Tool"} approval`); });
	pi.on("tool_approval_resolved", (_e, ctx) => { if (root || activate(ctx)) void unblock(); });
	pi.on("tool_execution_start", (e, ctx) => { if (e?.toolName === "ask" && (root || activate(ctx))) { const questions = e?.args?.questions; void block(Array.isArray(questions) ? questions.find((q: any) => q?.question)?.question : undefined); } });
	pi.on("tool_execution_end", (e, ctx) => { if (e?.toolName === "ask" && (root || activate(ctx))) void unblock(); });
	pi.on("agent_end", (e) => {
		if (!root || !active || e?.willContinue === true) return;
		active = false;
		const assistant = [...(Array.isArray(e?.messages) ? e.messages : [])].reverse().find((m: any) => m?.role === "assistant");
		const error = assistant?.stopReason === "error" ? String(assistant.errorMessage || "") : "";
		// An abort can end the run without resolving its blocker.
		clearTimers(); clearFailure(); clearBlocked();
		if (retryable.test(error)) {
			retryHold = true; failureMessage = error || "retryable provider error"; void publish();
			retryTimer = setTimeout(() => { retryHold = false; failure = true; void publish(); }, duration("RETRY_GRACE_MS", 2500)); retryTimer.unref?.();
		} else {
			idleTimer = setTimeout(() => { idleTimer = undefined; void publish(); }, duration("IDLE_DEBOUNCE_MS", 250)); idleTimer.unref?.();
		}
	});
	// OMP emits session_shutdown (no reason field) only when the session is
	// disposed on exit, and awaits the handler; /new and /resume use session_switch.
	pi.on("session_shutdown", () => { clearTimers(); if (root) return run("clear-state.sh", ["quit", instance, "omp"]); });
}
