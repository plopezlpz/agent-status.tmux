// Unit-test the pi adapter's event->state mapping and reason guards with a
// mocked pi runtime — no pi install or live LLM needed.
//
// Run with: bun tests/test-extension.ts   (skipped elsewhere; see tests/run.sh)
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

type ExecCall = { cmd: string; args: string[] };

function makePi(opts: { tmuxStdout?: string; tmuxThrows?: boolean } = {}) {
	const handlers: Record<string, (e: unknown) => unknown> = {};
	const calls: ExecCall[] = [];
	const pi = {
		on(event: string, cb: (e: unknown) => unknown) {
			handlers[event] = cb;
		},
		async exec(cmd: string, args: string[]) {
			calls.push({ cmd, args });
			// Stand in for `tmux show-option -gqv @agent-scripts-dir`.
			if (cmd === "tmux") {
				if (opts.tmuxThrows) throw new Error("tmux not found");
				return { stdout: opts.tmuxStdout ?? "/SCRIPTS\n", code: 0 };
			}
			return { stdout: "", code: 0 };
		},
	};
	return { pi, handlers, calls };
}

const TPM_FALLBACK = "/home/test/.tmux/plugins/agent-status.tmux/scripts/agent";

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

const mod = await import(resolve(dirname(fileURLToPath(import.meta.url)), "../scripts/pi/agent-status.ts"));
const extension = mod.default as (pi: unknown) => void;

// --- inside tmux: full mapping + guards ---
process.env.TMUX_PANE = "%1";
process.env.HOME = "/home/test";
{
	const { pi, handlers, calls } = makePi();
	extension(pi);
	for (const ev of ["session_start", "agent_start", "agent_end", "session_shutdown"]) {
		check(typeof handlers[ev] === "function", `registers ${ev}`);
	}

	await handlers.session_start({ reason: "startup" });
	check(lastState(calls) === "idle", "session_start startup -> idle");

	await handlers.agent_start({});
	check(lastState(calls) === "working", "agent_start -> working");

	await handlers.agent_end({});
	check(lastState(calls) === "finished", "agent_end -> finished");

	// reload must NOT reset to idle (no exec at all)
	const before = calls.length;
	await handlers.session_start({ reason: "reload" });
	check(calls.length === before, "session_start reload -> no state change");

	// non-quit shutdown reasons must NOT clear
	await handlers.session_shutdown({ reason: "resume" });
	await handlers.session_shutdown({ reason: "new" });
	await handlers.session_shutdown({ reason: "fork" });
	check(clears(calls) === 0, "shutdown resume/new/fork -> no clear");

	// real quit clears exactly once
	await handlers.session_shutdown({ reason: "quit" });
	check(clears(calls) === 1, "shutdown quit -> clear");

	// script path comes from @agent-scripts-dir
	const sc = calls.find((c) => c.cmd.endsWith("set-state.sh"));
	check(!!sc && sc.cmd.startsWith("/SCRIPTS/"), "uses @agent-scripts-dir for script path");
}

// --- fallback path: tmux lookup throws -> conventional TPM path ---
{
	process.env.TMUX_PANE = "%1";
	process.env.HOME = "/home/test";
	const { pi, handlers, calls } = makePi({ tmuxThrows: true });
	extension(pi);
	await handlers.session_start({ reason: "startup" });
	const sc = calls.find((c) => c.cmd.endsWith("set-state.sh"));
	check(!!sc && sc.cmd === `${TPM_FALLBACK}/set-state.sh`, "tmux throws -> falls back to TPM path");
}

// --- fallback path: empty @agent-scripts-dir -> conventional TPM path ---
{
	process.env.TMUX_PANE = "%1";
	process.env.HOME = "/home/test";
	const { pi, handlers, calls } = makePi({ tmuxStdout: "\n" });
	extension(pi);
	await handlers.session_start({ reason: "startup" });
	const sc = calls.find((c) => c.cmd.endsWith("set-state.sh"));
	check(!!sc && sc.cmd === `${TPM_FALLBACK}/set-state.sh`, "empty option -> falls back to TPM path");
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
