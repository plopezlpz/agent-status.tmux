// Unit-test the pi adapter's event->state mapping and reason guards with a
// mocked pi runtime — no pi install or live LLM needed.
//
// Run with: bun tests/test-extension.ts   (skipped elsewhere; see tests/run.sh)
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { mkdtempSync, realpathSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";

type ExecCall = { cmd: string; args: string[]; options?: { timeout?: number } };

function makePi(opts: { paneState?: string; paneSeq?: string } = {}) {
	const handlers: Record<string, (e: any, ctx?: any) => unknown> = {};
	const calls: ExecCall[] = [];
	const pi = {
		on(event: string, cb: (e: any, ctx?: any) => unknown) {
			handlers[event] = cb;
		},
		async exec(cmd: string, args: string[], options?: { timeout?: number }) {
			calls.push({ cmd, args, options });
			// Stand in for the pane's state and sequence.
			if (cmd === "tmux" && args[0] === "display") {
				return { stdout: `${opts.paneState ?? "idle"}\t${opts.paneSeq ?? "1"}\n`, code: 0 };
			}
			return { stdout: "", code: 0 };
		},
	};
	return { pi, handlers, calls };
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SCRIPTS = `${realpathSync(root)}/scripts/agent`;

let failed = 0;
function check(cond: boolean, msg: string) {
	if (!cond) {
		console.error(`FAIL: ${msg}`);
		failed++;
	}
}

const stateCalls = (calls: ExecCall[]) =>
	calls.filter((c) => c.cmd.endsWith("set-state.sh") || c.cmd.endsWith("clear-state.sh"));
const lastState = (calls: ExecCall[]): string | undefined => {
	const s = stateCalls(calls);
	const last = s[s.length - 1];
	if (!last) return undefined;
	return last.cmd.endsWith("clear-state.sh") ? "clear" : last.args[0];
};
const clears = (calls: ExecCall[]) => calls.filter((c) => c.cmd.endsWith("clear-state.sh")).length;
// Turn-path handlers queue work without awaiting it; let the queue drain.
const flush = () => new Promise((r) => setTimeout(r, 0));

// Loaded as installed: through a symlink in pi's extensions dir.
const extDir = mkdtempSync(resolve(tmpdir(), "agent-status-pi."));
symlinkSync(resolve(root, "scripts/pi/agent-status.ts"), resolve(extDir, "agent-status.ts"));
const mod = await import(resolve(extDir, "agent-status.ts"));
rmSync(extDir, { recursive: true, force: true });
const extension = mod.default as (pi: unknown) => void;

const ctx = (id: string, idle: boolean) => ({
	mode: "tui",
	isIdle: () => idle,
	sessionManager: { getSessionId: () => id },
});

// --- inside tmux: full mapping + guards ---
process.env.TMUX_PANE = "%1";
{
	const { pi, handlers, calls } = makePi();
	extension(pi);
	for (const ev of [
		"session_start",
		"agent_start",
		"agent_settled",
		"ui_prompt_start",
		"ui_prompt_end",
		"session_shutdown",
		"before_agent_start",
	]) {
		check(typeof handlers[ev] === "function", `registers ${ev}`);
	}
	check(handlers.agent_end === undefined, "does not report completion from agent_end");

	await handlers.session_start({ reason: "startup" }, ctx("pi-1", true));
	check(lastState(calls) === "idle", "session_start startup -> idle");
	check(
		calls.some((c) => c.cmd.endsWith("auto-desc.sh") && c.args[0] === "clear"),
		"session_start (non-reload) -> auto-desc clear",
	);
	const initial = stateCalls(calls)[0];
	check(initial.args[2] === "pi-1", "reports the pi session instance");
	check(initial.args[4] === "pi", "reports agent kind");
	check(initial.args[5] === "reset", "session_start resets instance authority");

	check(handlers.before_agent_start({ prompt: "hello world" }) === undefined, "before_agent_start does not wait on the status queue");
	await flush();
	const adSet = calls.find((c) => c.cmd.endsWith("auto-desc.sh") && c.args[0] === "set");
	check(!!adSet && adSet.args[1] === "hello world", "before_agent_start -> auto-desc set <prompt>");

	// Fire without awaiting to verify ordering for best-effort prompt events.
	const started = handlers.agent_start({}, ctx("pi-1", false));
	const blocked = handlers.ui_prompt_start({ title: "Allow command?" });
	await Promise.all([started, blocked]);
	await flush();
	check(lastState(calls) === "asking", "ui_prompt_start -> asking");
	const asking = stateCalls(calls).at(-1);
	check(asking?.args[1] === "Allow command?", "ui_prompt_start forwards title");

	handlers.ui_prompt_end({});
	await flush();
	check(lastState(calls) === "working", "ui_prompt_end while active -> working");

	const beforeUnsettled = stateCalls(calls).length;
	handlers.agent_settled({}, ctx("pi-1", false));
	await flush();
	check(stateCalls(calls).length === beforeUnsettled, "agent_settled while non-idle -> no completion");
	handlers.agent_settled({}, ctx("pi-1", true));
	await flush();
	check(lastState(calls) === "finished", "agent_settled idle -> completion");

	handlers.ui_prompt_start({ title: "Idle prompt" });
	handlers.ui_prompt_end({});
	await flush();
	check(lastState(calls) === "idle", "ui_prompt_end while settled -> idle");

	const before = stateCalls(calls).length;
	await handlers.session_start({ reason: "reload" }, ctx("pi-1", true));
	check(stateCalls(calls).length === before, "reload preserves existing pane state");

	await handlers.session_shutdown({ reason: "resume" });
	await handlers.session_shutdown({ reason: "new" });
	await handlers.session_shutdown({ reason: "fork" });
	check(clears(calls) === 0, "shutdown resume/new/fork -> no clear");

	await handlers.session_shutdown({ reason: "quit" });
	check(clears(calls) === 1, "shutdown quit -> clear");
	const clear = stateCalls(calls).find((c) => c.cmd.endsWith("clear-state.sh"));
	check(clear?.args[1] === "pi-1", "shutdown carries instance identity");

	const sc = calls.find((c) => c.cmd.endsWith("set-state.sh"));
	check(!!sc && sc.cmd === `${SCRIPTS}/set-state.sh`, "runs the checkout's scripts through the installed symlink");
	const seqs = stateCalls(calls).map((c) => Number(c.args[3])).filter(Number.isFinite);
	check(seqs.every((n, i) => i === 0 || n > seqs[i - 1]), "reports monotonic sequences");
	check(calls.every((c) => typeof c.options?.timeout === "number" && c.options.timeout > 0), "every exec is bounded by a timeout");
}

// --- reload after a wall-clock step back stays ahead of the pane's sequence ---
{
	const ahead = String(Date.now() * 1000 + 3_600_000_000);
	const { pi, handlers, calls } = makePi({ paneSeq: ahead });
	extension(pi);
	await handlers.session_start({ reason: "reload" }, ctx("pi-clock", false));
	check(stateCalls(calls).length === 0, "reload with existing state sends no reset");
	handlers.agent_settled({}, ctx("pi-clock", true));
	await flush();
	const settled = stateCalls(calls).at(-1);
	check(!!settled && Number(settled.args[3]) > Number(ahead), "reload seeds seq past the pane's @agent-seq");
}

// --- reload repairs a missing pane registration ---
{
	const { pi, handlers, calls } = makePi({ paneState: "" });
	extension(pi);
	await handlers.session_start({ reason: "reload" }, ctx("pi-reload", true));
	check(lastState(calls) === "idle", "reload with missing state -> idle registration");
	const repaired = stateCalls(calls).at(-1);
	check(repaired?.args[5] === "reset", "reload repair resets instance authority");
}

// --- headless modes inside tmux do not own the pane ---
{
	process.env.TMUX_PANE = "%1";
	const { pi, handlers, calls } = makePi();
	extension(pi);
	await handlers.session_start({ reason: "startup" }, { ...ctx("pi-rpc", false), mode: "rpc" });
	await handlers.agent_start({}, ctx("pi-rpc", false));
	await handlers.agent_settled({}, ctx("pi-rpc", true));
	check(stateCalls(calls).length === 0, "headless mode -> no pane registration");
}

// --- session file is recorded on the pane for ctrl-g descriptions, once per file.
{
	process.env.TMUX_PANE = "%7";
	const { pi, handlers, calls } = makePi();
	extension(pi);
	const withFile = (file: string) => ({ ...ctx("s1", true), sessionManager: { getSessionId: () => "s1", getSessionFile: () => file } });
	await handlers.session_start({ reason: "startup" }, withFile("/home/test/.pi/agent/sessions/a.jsonl"));
	handlers.agent_start({}, withFile("/home/test/.pi/agent/sessions/a.jsonl"));
	await flush();
	const sets = () => calls.filter((c) => c.cmd === "tmux" && c.args.includes("@agent-transcript") && !c.args.includes("-u"));
	check(sets().length === 1, "session file recorded once");
	check(sets()[0]?.args.at(-1) === "/home/test/.pi/agent/sessions/a.jsonl", "recorded the session file path");
	const target = sets()[0]?.args ?? [];
	check(target[target.indexOf("-t") + 1] === "%7", "session file is set on this pane (-t %7)");
	await handlers.session_start({ reason: "new" }, withFile("/home/test/.pi/agent/sessions/b.jsonl"));
	check(sets().at(-1)?.args.at(-1) === "/home/test/.pi/agent/sessions/b.jsonl", "new session records its own file");
	const none = makePi();
	extension(none.pi);
	await none.handlers.session_start({ reason: "startup" }, ctx("s2", true));
	const transcriptCalls = none.calls.filter((c) => c.args.includes("@agent-transcript"));
	check(transcriptCalls.length === 1 && transcriptCalls[0].args.includes("-u"), "new session without a file unsets the previous transcript");
	check(transcriptCalls[0]?.args[transcriptCalls[0].args.indexOf("-t") + 1] === "%7", "transcript unset targets this pane");
}

// --- outside tmux: no-op. The env guard lives INSIDE the exported function
//     (not at module scope), so calling it again with TMUX_PANE unset must
//     register nothing. Keep the guard there or this contract breaks.
{
	delete process.env.TMUX_PANE;
	const { pi, handlers } = makePi();
	extension(pi);
	check(Object.keys(handlers).length === 0, "outside tmux -> registers no handlers");
}

if (failed) {
	console.error(`\n${failed} check(s) failed`);
	process.exit(1);
}
console.log("PASS: pi extension");
