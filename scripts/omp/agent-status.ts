/** agent-status.tmux — OMP lifecycle adapter. */
// @ts-nocheck
import { realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Installed as a symlink to the plugin checkout: run that checkout's scripts.
const scriptsDir = resolve(dirname(realpathSync(fileURLToPath(import.meta.url))), "../agent");

// AGENT_STATUS_OMP_<NAME> milliseconds, else FALLBACK.
const duration = (name: string, fallback: number) => {
	const n = Number.parseInt(process.env[`AGENT_STATUS_OMP_${name}`] || "", 10);
	return Number.isFinite(n) && n >= 0 ? n : fallback;
};

export default function (pi) {
	if (!process.env.TMUX_PANE) return;
	let instance = "", seq = Date.now() * 1000, root = false, active = false;
	let blocked = 0, blockedMessage = "", failure = false, failureMessage = "", retryCancelled = false;
	const reviews = new Set();
	// announced: completion already published, so later blocker churn settles idle.
	let lastState = "", lastMessage = "", announced = true, idleTimer: any, settleTimer: any;
	let queue = Promise.resolve();
	// Bound every status command; a blocked script must not stall the queue.
	const execOptions = { timeout: 5000 };
	const run = (script: string, args: string[]) => {
		queue = queue.then(async () => { try { await pi.exec(`${scriptsDir}/${script}`, args, execOptions); } catch {} });
		return queue;
	};
	const updateInstance = (ctx: any) => { try { instance = ctx?.sessionManager?.getSessionId?.() || instance; } catch {} };
	const desired = () => blocked ? ["asking", blockedMessage] : failure ? ["asking", failureMessage] : active ? ["working", ""] : [announced ? "idle" : "finished", ""];
	const publish = (force = false, reset = false) => {
		const [state, message] = desired();
		if (!force && state === lastState && message === lastMessage) return Promise.resolve();
		lastState = state; lastMessage = message;
		if (state === "finished") announced = true;
		return run("set-state.sh", [state, message, instance, String(++seq), "omp", reset ? "reset" : ""]);
	};
	const clearIdleTimer = () => { if (idleTimer) clearTimeout(idleTimer); idleTimer = undefined; };
	const clearTimers = () => { if (idleTimer) clearTimeout(idleTimer); if (settleTimer) clearInterval(settleTimer); idleTimer = settleTimer = undefined; };
	const clearFailure = () => { failure = retryCancelled = false; failureMessage = ""; };
	const clearBlocked = () => { blocked = 0; blockedMessage = ""; reviews.clear(); };
	const activate = (ctx: any, reset = false) => {
		if (ctx?.hasUI !== true) return false;
		root = true; updateInstance(ctx);
		if (reset) { clearTimers(); clearFailure(); clearBlocked(); active = false; announced = true; }
		return true;
	};
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
	// A /btw branch or an entry fork (session_branch) also starts a new session.
	const selected = (_e: any, ctx: any) => {
		if (!activate(ctx, true)) return;
		lastState = "idle"; lastMessage = "";
		void run("set-state.sh", ["idle", "", instance, String(++seq), "omp", "reset"]);
		void run("auto-desc.sh", ["clear", "omp"]);
	};
	pi.on("session_switch", selected);
	pi.on("session_branch", selected);
	// Only the prompt's start can name the pane: keep a pasted file out of argv.
	pi.on("before_agent_start", (e) => { if (root && e?.prompt) void run("auto-desc.sh", ["set", String(e.prompt).slice(0, 2000)]); });
	pi.on("agent_start", (_e, ctx) => { if (!root && !activate(ctx)) return; updateInstance(ctx); clearTimers(); clearFailure(); clearBlocked(); active = true; announced = false; void publish(); });
	pi.on("tool_approval_requested", (e, ctx) => { if (root || activate(ctx)) void block(e?.reason || `${e?.toolName || "Tool"} approval`); });
	pi.on("tool_approval_resolved", (_e, ctx) => { if (root || activate(ctx)) void unblock(); });
	pi.on("tool_execution_start", (e, ctx) => { if (e?.toolName === "ask" && (root || activate(ctx))) { const questions = e?.args?.questions; void block(Array.isArray(questions) ? questions.find((q: any) => q?.question)?.question : undefined); } });
	pi.on("tool_execution_end", (e, ctx) => { if (e?.toolName === "ask" && (root || activate(ctx))) void unblock(); });
	// The plan review (omp 18.12+) waits on the user; a replacement resolves the old one.
	pi.on("plan_review_requested", (e, ctx) => { if ((root || activate(ctx)) && !reviews.has(e?.reviewId)) { reviews.add(e?.reviewId); void block(`Plan review: ${e?.title || "plan"}`); } });
	pi.on("plan_review_resolved", (e, ctx) => { if ((root || activate(ctx)) && reviews.delete(e?.reviewId)) void unblock(); });
	// An Esc during a retry's backoff ends the run on the error it was retrying.
	pi.on("auto_retry_end", (e) => { if (root && e?.success === false && e?.finalError === "Retry cancelled") retryCancelled = true; });
	// omp retries before a terminal agent_end, so its error is final: it asks.
	// An Esc (aborted) is no completion.
	const settle = (e: any) => {
		const assistant = [...(Array.isArray(e?.messages) ? e.messages : [])].reverse().find((m: any) => m?.role === "assistant");
		const aborted = assistant?.stopReason === "aborted" || retryCancelled;
		// An abort can end the run without resolving its blocker.
		active = false; clearTimers(); clearFailure(); clearBlocked();
		if (aborted) announced = true;
		else if (assistant?.stopReason === "error") { failure = true; failureMessage = String(assistant.errorMessage || "provider error"); }
		idleTimer = setTimeout(() => { idleTimer = undefined; void publish(); }, duration("IDLE_DEBOUNCE_MS", 250)); idleTimer.unref?.();
	};
	// Nothing left to resume the run: idle, no queued prompt or background job.
	const quiet = (ctx: any) => {
		try {
			const jobs = ctx?.getAsyncJobSnapshot?.();
			return ctx?.isIdle?.() === true && ctx?.hasPendingMessages?.() !== true && !(jobs?.running?.length || jobs?.delivery?.queued || jobs?.delivery?.delivering);
		} catch { return false; }
	};
	pi.on("agent_end", (e, ctx) => {
		if (!root || !active) return;
		if (e?.willContinue !== true) return settle(e);
		// A continuation may never start (an Esc, or a cancelled background job
		// wakes nothing) and then no agent_end follows: settle once quiet twice.
		if (settleTimer) clearInterval(settleTimer);
		let quietPolls = 0;
		settleTimer = setInterval(() => { quietPolls = quiet(ctx) ? quietPolls + 1 : 0; if (quietPolls >= 2) settle(e); }, 1000); settleTimer.unref?.();
	});
	// OMP emits session_shutdown (no reason field) only when the session is
	// disposed on exit, and awaits the handler; /new and /resume use session_switch.
	pi.on("session_shutdown", () => { clearTimers(); if (root) return run("clear-state.sh", ["quit", instance, "omp"]); });
}
