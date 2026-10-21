// Behavioural tests for the OMP, OpenCode and Kilo adapters (the Kimi and
// MastraCode hooks: test-hook-event.sh).
// The adapters run from a copy of the plugin whose state scripts are
// argv-logging stubs (each adapter runs the scripts of its own checkout); no
// provider, live tmux server, or LLM is involved.
//
// Run with: bun tests/test-providers.ts   (skipped elsewhere; see tests/run.sh)
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { chmodSync, copyFileSync, cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { execFileSync, spawnSync } from "node:child_process";
const checkout = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const executable = (path: string, body: string) => { writeFileSync(path, body); chmodSync(path, 0o755); };

// Bun resolves execFileSync commands against the PATH the process started
// with, so the isolated environment (tmux stub first on PATH, temp HOME, and an
// empty TMUX_TMPDIR so even a real tmux finds no server) must exist before the
// adapters run: build it, then re-run this file inside it.
if (!process.env.AGENT_TEST_ROOT) {
  const tmp = mkdtempSync(resolve(tmpdir(), "agent-status-providers."));
  const home = resolve(tmp, "home"), bin = resolve(tmp, "bin");
  const stubs = resolve(tmp, "plugin/scripts/agent");
  cpSync(resolve(checkout, "scripts"), resolve(tmp, "plugin/scripts"), { recursive: true });
  rmSync(stubs, { recursive: true }); mkdirSync(stubs);
  mkdirSync(home); mkdirSync(bin); mkdirSync(resolve(tmp, "tmux"));
  // Each stub logs its name, argv, and whether stdin was closed or left open.
  for (const name of ["set-state.sh", "auto-desc.sh", "clear-state.sh"]) {
    executable(resolve(stubs, name), `#!/bin/bash
# bash 3.2's read -t cannot tell a timeout from EOF; ask select() instead.
if perl -MIO::Select -e 'exit(IO::Select->new(\\*STDIN)->can_read(0.5) ? 0 : 1)'; then stdin=closed; else stdin=open; fi
line=${name}; for arg in "$@"; do line="$line|$arg"; done
printf '%s|<stdin:%s>\\n' "$line" "$stdin" >> "$AGENT_TEST_LOG"
case " \${AGENT_TEST_FAIL:-} " in *" ${name} "*) exit 1 ;; esac
`);
  }
  // Lookups fail except a busy pane state, which an adapter must not copy onto
  // a newly selected session.
  executable(resolve(bin, "tmux"), '#!/bin/sh\ncase "$*" in *@agent-state*) echo working; exit 0 ;; esac\nexit 1\n');
  const env: Record<string, string | undefined> = { ...process.env, AGENT_TEST_ROOT: tmp, HOME: home, PATH: `${bin}:${process.env.PATH}`, TMUX_TMPDIR: resolve(tmp, "tmux"), AGENT_TEST_LOG: resolve(tmp, "calls.log") };
  delete env.TMUX; delete env.TMUX_PANE;
  const r = spawnSync(process.execPath, [fileURLToPath(import.meta.url)], { env, stdio: "inherit" });
  rmSync(tmp, { recursive: true, force: true });
  process.exit(r.status ?? 1);
}

let failures = 0;
const check = (ok: boolean, message: string) => { if (!ok) { console.error(`FAIL: ${message}`); failures++; } };
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
const tmp = process.env.AGENT_TEST_ROOT, home = process.env.HOME!, log = process.env.AGENT_TEST_LOG!;
// The plugin copy the adapters load from.
const root = resolve(tmp ?? "", "plugin");
if (!tmp || !home.startsWith(tmp) || process.env.TMUX || !process.env.TMUX_TMPDIR?.startsWith(tmp)) throw new Error("refusing to run outside the isolated environment");
// An adapter as manage-provider.sh installs it: a symlink in the provider's
// plugin dir, so its relative import of lifecycle.js must follow the link.
const installed = (adapter: string, dir: string) => {
  const dest = resolve(tmp, `config-${adapter}`, dir, "agent-status.tmux.js");
  mkdirSync(dirname(dest), { recursive: true });
  try { symlinkSync(resolve(root, `scripts/${adapter}/agent-status.js`), dest); } catch {}
  return dest;
};
{
  let reached = true;
  try { execFileSync("tmux", ["-V"], { stdio: "ignore" }); } catch { reached = false; }
  if (reached) throw new Error("tmux stub is not first on PATH; refusing to run");
}
writeFileSync(log, "");
const lines = () => readFileSync(log, "utf8").split("\n").filter(Boolean);
let mark = 0;
const since = () => { const all = lines(), out = all.slice(mark); mark = all.length; return out; };
const waitFor = async (pattern: string, timeout = 5000) => {
  for (const end = Date.now() + timeout; Date.now() < end; await sleep(10)) if (lines().slice(mark).some(l => l.includes(pattern))) return true;
  if (process.env.AGENT_TEST_DEBUG) console.error(lines().slice(mark));
  return false;
};
// A plugin copy whose set-state.sh takes a second: a report still running
// when the agent quits. It logs as it starts and as it ends.
const slow = resolve(tmp ?? "", "plugin-slow");
cpSync(resolve(root, "scripts"), resolve(slow, "scripts"), { recursive: true });
executable(resolve(slow, "scripts/agent/set-state.sh"), `#!/bin/sh
echo "set-state.sh|$1|$2|$3|started" >> "$AGENT_TEST_LOG"
sleep 1
echo "set-state.sh|$1|$2|$3|done" >> "$AGENT_TEST_LOG"
`);
// Whether GOT holds the clear starting with QUIT, and no report after it.
const clearedLast = (got: string[], quit: string) => {
  const at = got.findIndex(l => l.startsWith(quit));
  return at >= 0 && !got.slice(at).some(l => l.startsWith("set-state.sh|"));
};

// ---------------------------------------------------------------- OMP
process.env.TMUX_PANE = "%1";
process.env.AGENT_STATUS_OMP_IDLE_DEBOUNCE_MS = "0";
{
  const calls: {cmd:string,args:string[],options?:any}[] = [];
  const handlers: Record<string, Function> = {};
  const eventHandlers: Record<string, Function> = {};
  const pi = {
    on(name:string, fn:Function) { handlers[name] = fn; },
    events: { on(name:string, fn:Function) { eventHandlers[name] = fn; } },
    async exec(cmd:string,args:string[],options?:any) { calls.push({cmd,args,options}); if (cmd === "tmux") return {stdout:"/SCRIPTS\n"}; return {stdout:""}; },
  };
  const omp = (await import(resolve(root, "scripts/omp/agent-status.ts"))).default;
  omp(pi as any);
  const ctx = {hasUI:true,isIdle:()=>true,sessionManager:{getSessionId:()=>"same-id"}};
  const tick = (ms = 0) => sleep(ms);
  const states = () => calls.filter(c=>c.cmd.endsWith("set-state.sh")).map(c=>c.args[0]);
  const descs = () => calls.filter(c=>c.cmd.endsWith("auto-desc.sh")).map(c=>c.args[0]);
  await handlers.session_start({}, ctx); await tick();
  check(states().at(-1) === "idle", "OMP session starts idle");
  check(descs().at(-1) === "clear", "OMP idle session_start clears the label");
  await handlers.agent_start({}, ctx); await handlers.tool_approval_requested({reason:"allow?"},ctx); await handlers.tool_approval_requested({reason:"again?"},ctx);
  await handlers.tool_approval_resolved({},ctx); await tick();
  check(states().at(-1) === "asking", "OMP blocked counter survives one resolution");
  await handlers.tool_approval_resolved({},ctx); await tick();
  check(states().at(-1) === "working", "OMP resolved approval resumes work");
  await handlers.agent_end({messages:[]}); await tick(5);
  check(states().at(-1) === "finished", "OMP settle debounce reports completion");
  // A blocker after completion must not announce the same completion twice.
  eventHandlers["herdr:blocked"]({active:true,label:"look"}); await tick();
  check(states().at(-1) === "asking", "OMP idle blocker asks");
  eventHandlers["herdr:blocked"]({active:false}); await tick();
  check(states().at(-1) === "idle", "OMP unblock after completion settles idle, not finished");
  // An Esc while asking: the blocker never resolves, so agent_end must clear
  // it, and the run settles idle, not finished.
  await handlers.agent_start({}, ctx); await handlers.tool_approval_requested({reason:"allow?"},ctx);
  await handlers.agent_end({messages:[{role:"user"},{role:"assistant",stopReason:"aborted"}]}); await tick(5);
  check(states().at(-1) === "idle", "OMP Esc while blocked settles idle, not asking or finished");
  // A plan review asks; a replacement review resolves the old one.
  await handlers.plan_review_requested({reviewId:"r1",title:"Refactor"},ctx); await tick();
  check(calls.filter(c=>c.cmd.endsWith("set-state.sh")).at(-1)?.args.slice(0,2).join("|") === "asking|Plan review: Refactor", "OMP plan review asks");
  await handlers.plan_review_requested({reviewId:"r2",title:"Refactor v2"},ctx); await handlers.plan_review_requested({reviewId:"r2",title:"Refactor v2"},ctx);
  await handlers.plan_review_resolved({reviewId:"r1"},ctx); await tick();
  check(states().at(-1) === "asking", "OMP replaced plan review keeps asking");
  await handlers.plan_review_resolved({reviewId:"r2",choice:"execute"},ctx); await tick();
  check(states().at(-1) === "idle", "OMP resolved plan review settles idle");
  await handlers.agent_start({}, ctx); await tick();
  check(states().at(-1) === "working", "OMP agent_start resets stale blockers");
  // omp retries before a terminal agent_end: any provider error then asks with its text.
  await handlers.agent_end({messages:[{role:"assistant",stopReason:"error",errorMessage:"401 invalid x-api-key"}]}); await tick(5);
  check(calls.filter(c=>c.cmd.endsWith("set-state.sh")).at(-1)?.args.slice(0,2).join("|") === "asking|401 invalid x-api-key", "OMP terminal error asks with its message");
  await handlers.tool_execution_start({toolName:"ask",args:{questions:"not-an-array"}},ctx);
  await handlers.tool_execution_end({toolName:"ask"},ctx); await tick();
  check(calls.filter(c=>c.cmd.endsWith("set-state.sh")).at(-1)?.args.slice(0,2).join("|") === "asking|401 invalid x-api-key", "OMP error still asks after a blocker");
  // An Esc during a retry's backoff ends on the error being retried: idle.
  await handlers.agent_start({},ctx); await handlers.auto_retry_end({success:false,attempt:1,finalError:"Retry cancelled"});
  await handlers.agent_end({messages:[{role:"assistant",stopReason:"error",errorMessage:"429 rate limit"}]}); await tick(5);
  check(states().at(-1) === "idle", "OMP cancelled retry settles idle");
  // A continuation that never starts (a cancelled background job) settles
  // once nothing is left to resume the run.
  let running = [{id:"job"}];
  const waiting = {...ctx, isIdle:()=>true, hasPendingMessages:()=>false, getAsyncJobSnapshot:()=>({running,recent:[],delivery:{queued:0,delivering:false,pendingJobIds:[]}})};
  await handlers.agent_start({},ctx); await handlers.agent_end({willContinue:true,awaitingAsyncWork:true,messages:[{role:"assistant",stopReason:"stop"}]}, waiting);
  await tick(1100); check(states().at(-1) === "working", "OMP awaiting a running background job stays working");
  running = [];
  await tick(2200); check(states().at(-1) === "finished", "OMP settles when the awaited job ends without a wake");
  await handlers.agent_start({},ctx); await tick();
  await handlers.tool_execution_start({toolName:"ask",args:{questions:[{},{question:"Which?"}]}},ctx); await tick();
  check(calls.filter(c=>c.cmd.endsWith("set-state.sh")).at(-1)?.args[1] === "Which?", "OMP ask forwards the first question");
  await handlers.tool_execution_end({toolName:"ask"},ctx);
  const clearsBefore = descs().length;
  await handlers.session_switch({reason:"new"}, ctx); await tick();
  check(states().at(-1) === "idle" && descs().length === clearsBefore + 1 && descs().at(-1) === "clear", "OMP session_switch resets and clears the label");
  // A /btw branch starts a new session with only session_branch: the pane follows it.
  const branched = {...ctx, sessionManager:{getSessionId:()=>"branch-id"}};
  await handlers.agent_start({}, ctx); await handlers.session_branch({reason:"btw"}, branched); await tick();
  const rebound = calls.filter(c=>c.cmd.endsWith("set-state.sh")).at(-1)?.args ?? [];
  check(rebound[0] === "idle" && rebound[2] === "branch-id" && rebound[5] === "reset" && descs().at(-1) === "clear", "OMP session_branch rebinds the pane idle and clears the label");
  await handlers.agent_start({}, branched); await tick();
  check(calls.filter(c=>c.cmd.endsWith("set-state.sh")).at(-1)?.args.slice(0,3).join("|") === "working||branch-id", "OMP branched session reports");
  const shutdown = handlers.session_shutdown({});
  check(shutdown instanceof Promise, "OMP session_shutdown returns its clear for OMP to await");
  await shutdown;
  check(calls.at(-1)?.cmd.endsWith("clear-state.sh") === true && calls.at(-1)?.args.join(" ") === "quit branch-id omp", "OMP shutdown clears its own instance");
  check(calls.every(c => typeof c.options?.timeout === "number"), "OMP bounds every exec with a timeout");
}

// ----------------------------------------------------------- OpenCode
{
  // OpenCode and Kilo share lifecycle.js; each adapter keeps its own sessions.
  const { lifecycle, interactive } = await import(resolve(root, "scripts/opencode/lifecycle.js"));
  const a = lifecycle("opencode"), b = lifecycle("kilo");
  a.childSessions.set("child", "root"); a.aborted.add("aborted");
  check(!b.childSessions.has("child") && !b.aborted.has("aborted"), "lifecycle() instances keep separate session state");
  a.childSessions.set("grandchild", "child");
  check(a.rootOf("grandchild") === "root" && a.rootOf("root") === "root", "lifecycle() finds a child's root session");
  // The TUI runs the server in a worker; the main thread runs headless
  // commands, and Kilo's --mini and run --interactive.
  const argv = (...args: string[]) => ["bun", "/$bunfs/root/src/index.js", ...args];
  check(interactive(["bun", "/$bunfs/root/src/cli/tui/worker.js"], false), "the TUI's server worker is interactive");
  for (const args of [[], ["--continue"], ["--mini"], ["/some/project"], ["run", "-i"], ["run", "--interactive", "x"], ["--log-level", "DEBUG"]]) {
    check(interactive(argv(...args), true), `${JSON.stringify(args)} on the main thread is interactive`);
  }
  for (const args of [["run", "x"], ["serve"], ["--log-level", "DEBUG", "run", "x"], ["remote"], ["attach", "http://h"], ["acp"]]) {
    check(!interactive(argv(...args), true), `${JSON.stringify(args)} on the main thread is headless`);
  }
}
process.env.TMUX_PANE = "%2";
{
  const mod = await import(installed("opencode", "plugins"));
  const { AgentStatusPlugin } = mod;
  // OpenCode 1.x calls the default export's server(); OpenCode 2 its setup(),
  // in a shared service that belongs to no pane.
  check(mod.default?.id && mod.default.server === AgentStatusPlugin && typeof mod.default.setup === "function", "OpenCode exports a definition for OpenCode 1.x and 2");
  mod.default.setup({});
  const argv = process.argv;
  process.argv = [argv[0], argv[1], "serve", "--port", "4096"];
  check(Object.keys(await AgentStatusPlugin()).length === 0, "OpenCode headless `opencode serve` registers no hooks");
  process.argv = argv;
  const plugin = await AgentStatusPlugin();
  const event = (type: string, properties: any) => plugin.event({ event: { type, properties } });
  await sleep(100);
  check(since().length === 0, "OpenCode 2's setup() reports nothing");
  let sentinel = 0;
  // The chain is serialized, so a sentinel line proves every earlier call ran.
  const drain = async () => { const id = `sentinel-${++sentinel}`; await event("session.idle", { sessionID: id }); check(await waitFor(id), "OpenCode chain drains"); return since().filter(l => !l.includes("sentinel-")); };

  const started = Date.now();
  await plugin["chat.message"]({ sessionID: "root-1" }, { parts: [{ type: "text", text: "fix the bug" }] });
  check(Date.now() - started < 200 && lines().length === mark, "OpenCode chat.message does not wait on status scripts");
  await event("session.status", { sessionID: "root-1", status: { type: "busy" } });
  await event("permission.asked", { sessionID: "root-1" });
  await event("session.idle", { sessionID: "root-1" });
  let got = await drain();
  // A prompt binds its root (a session started from the home screen is shown
  // by the TUI only after its first events), before its label replaces the
  // old one, then reports working in a pane the bind left as it was.
  check(got[0]?.startsWith("set-state.sh|working||root-1|") && got[0].includes("|opencode|bind|"), "OpenCode chat.message binds its root");
  check(got[1]?.startsWith("auto-desc.sh|set|fix the bug|"), "OpenCode records first prompt text");
  check(got[2]?.startsWith("set-state.sh|working||root-1|") && got[2].includes("|opencode||"), "OpenCode chat.message -> working with root identity");
  const states = (lines: string[]) => lines.filter(l => l.startsWith("set-state.sh|")).map(l => l.split("|")[1] + (l.includes("|bind|") ? "/bind" : "")).join(",");
  check(states(got) === "working/bind,working,working,asking,finished", "OpenCode root lifecycle mapping");
  check(got.every(l => l.endsWith("<stdin:closed>")), "OpenCode closes script stdin");
  const seqs = got.filter(l => l.startsWith("set-state.sh|")).map(l => Number(l.split("|")[4]));
  check(seqs.every((n, i) => i === 0 || n > seqs[i - 1]), "OpenCode sends monotonic sequences");

  await event("session.created", { sessionID: "child-1", info: { id: "child-1", parentID: "root-1" } });
  await plugin["chat.message"]({ sessionID: "child-1" }, { parts: [{ type: "text", text: "subtask" }] });
  await event("session.status", { sessionID: "child-1", status: { type: "busy" } });
  await event("permission.asked", { sessionID: "child-1" });
  await event("permission.replied", { sessionID: "child-1" });
  await event("session.idle", { sessionID: "child-1" });
  await event("session.created", { sessionID: "child-2", info: { id: "child-2", parentID: "child-1" } });
  await event("question.asked", { sessionID: "child-2" });
  got = await drain();
  check(got.length === 3 && got[0].startsWith("set-state.sh|asking||root-1|") && got[1].startsWith("set-state.sh|working||root-1|") && got[2].startsWith("set-state.sh|asking||root-1|"), "OpenCode child events report only blockers, as their root");
  check(got.every(l => !l.includes("child-") && !l.includes("|reset|")), "OpenCode child events never carry their own identity or reset");

  await event("session.error", { sessionID: "root-1", error: { name: "MessageAbortedError", data: { message: "aborted" } } });
  await event("session.status", { sessionID: "root-1", status: { type: "idle" } });
  await event("session.idle", { sessionID: "root-1" });
  got = await drain();
  check(got.length === 2 && got.every(l => l.startsWith("set-state.sh|idle||root-1|")), "OpenCode ESC abort -> idle without asking or finished");
  await plugin["chat.message"]({ sessionID: "root-1" }, { parts: [] });
  await event("session.error", { sessionID: "root-1", error: { name: "APIError", data: { message: "boom" } } });
  await event("session.idle", { sessionID: "root-1" });
  got = await drain();
  check(states(got) === "working/bind,working,asking,finished", "OpenCode real errors still ask, and the next turn finishes");
  // A new session from the home screen, while the pane shows root-1.
  await plugin["chat.message"]({ sessionID: "root-2" }, { parts: [{ type: "text", text: "second session" }] });
  got = await drain();
  const pasted = (lines: string[]) => lines.find(l => l.startsWith("auto-desc.sh|set|"))?.split("|")[2].length;
  check(got.length === 3 && got[0].startsWith("set-state.sh|working||root-2|") && got[0].includes("|bind|") && got[1].startsWith("auto-desc.sh|set|second session|") && got[2].startsWith("set-state.sh|working||root-2|") && got[2].includes("|opencode||"), `OpenCode a prompt in another root rebinds the pane before its label (${JSON.stringify(got)})`);
  // Only a long prompt's start reaches argv.
  await plugin["chat.message"]({ sessionID: "root-2" }, { parts: [{ type: "text", text: "x".repeat(300000) }] });
  check(pasted(await drain()) === 2000, "OpenCode passes only a long prompt's start");
  // A rejected permission or question, or an Esc on a `!` shell command, ends
  // the turn without completing it.
  for (const [name, stop] of [
    ["a rejected permission", () => event("permission.replied", { sessionID: "root-1", requestID: "per_1", reply: "reject" })],
    ["a rejected question", () => event("question.rejected", { sessionID: "root-1", requestID: "que_1" })],
    ["an Esc on a shell command", () => event("message.part.updated", { sessionID: "root-1", part: { type: "tool", sessionID: "root-1", tool: "bash", state: { status: "completed", output: "x\n\n<metadata>\nUser aborted the command\n</metadata>" } } })],
  ] as const) {
    await event("session.status", { sessionID: "root-1", status: { type: "busy" } });
    await stop();
    await event("session.status", { sessionID: "root-1", status: { type: "idle" } });
    got = await drain();
    check(got.at(-1)?.startsWith("set-state.sh|idle||root-1|") === true, `OpenCode ${name} settles idle, not finished`);
  }
  await event("permission.replied", { sessionID: "root-1", requestID: "per_2", reply: "once" });
  await event("session.status", { sessionID: "root-1", status: { type: "idle" } });
  got = await drain();
  check(got.at(-1)?.startsWith("set-state.sh|finished||root-1|") === true, "OpenCode an allowed permission still finishes");
  // Events and prompts without a session belong to no root this pane shows.
  await plugin["chat.message"]({}, { parts: [{ type: "text", text: "no session" }] });
  await event("session.error", { error: { name: "APIError", data: { message: "boom" } } });
  await event("session.status", { status: { type: "busy" } });
  await event("session.idle", {});
  got = await drain();
  check(got.length === 0, `OpenCode reports nothing without a session (${JSON.stringify(got)})`);
}

// --------------------------------------------------------------- Kilo
process.env.TMUX_PANE = "%3";
{
  const mod = await import(installed("kilo", "plugin"));
  const { AgentStatusPlugin } = mod;
  check(mod.default?.id && mod.default.server === AgentStatusPlugin, "Kilo exports a plugin definition");
  const argv = process.argv;
  process.argv = [argv[0], argv[1], "run", "do it"];
  check(Object.keys(await AgentStatusPlugin()).length === 0, "Kilo headless `kilo run` registers no hooks");
  process.argv = [argv[0], argv[1], "--continue"];
  const plugin = await AgentStatusPlugin();
  process.argv = argv;
  check(typeof plugin.event === "function", "Kilo interactive TUI registers hooks");
  const event = (type: string, properties: any) => plugin.event({ event: { type, properties } });
  let sentinel = 0;
  const drain = async () => { const id = `sentinel-${++sentinel}`; await event("session.idle", { sessionID: id }); check(await waitFor(id), "Kilo chain drains"); return since().filter(l => !l.includes("sentinel-")); };

  await event("session.created", { info: { id: "k-root" } });
  await plugin["chat.message"]({ sessionID: "k-root" }, { parts: [{ type: "text", text: "kilo prompt" }] });
  let got = await drain();
  check(got[0]?.startsWith("auto-desc.sh|clear|kilo|"), "Kilo new root session clears the label");
  check(got[1]?.startsWith("set-state.sh|idle||k-root|") && got[1].includes("|kilo|reset|"), "Kilo root session.created resets from info.id");
  check(got[2]?.startsWith("auto-desc.sh|set|kilo prompt|") && got[3]?.startsWith("set-state.sh|working||k-root|") && got[3].includes("|kilo||"), "Kilo prompt in the bound root -> label + working, no reset");
  check(got.every(l => l.endsWith("<stdin:closed>")), "Kilo closes script stdin");
  await plugin["chat.message"]({ sessionID: "k-root" }, { parts: [{ type: "text", text: "x".repeat(300000) }] });
  got = await drain();
  check(got.find(l => l.startsWith("auto-desc.sh|set|"))?.split("|")[2].length === 2000, "Kilo passes only a long prompt's start");

  await event("session.created", { info: { id: "k-child", parentID: "k-root" } });
  await plugin["chat.message"]({ sessionID: "k-child" }, { parts: [{ type: "text", text: "child" }] });
  await event("session.status", { sessionID: "k-child", status: { type: "busy" } });
  await event("question.asked", { sessionID: "k-child" });
  await event("session.idle", { sessionID: "k-child" });
  got = await drain();
  check(got.length === 1 && got[0].startsWith("set-state.sh|asking||k-root|") && !got[0].includes("|reset|"), "Kilo child session never resets and reports as its root");

  // Kilo's offline status waits for the user.
  await event("session.status", { sessionID: "k-root", status: { type: "offline", requestID: "r", message: "lost" } });
  got = await drain();
  check(got.length === 1 && got[0].startsWith("set-state.sh|asking||k-root|"), "Kilo offline status asks");
  await event("permission.replied", { sessionID: "k-root", requestID: "per_1", reply: "reject" });
  await event("session.idle", { sessionID: "k-root" });
  got = await drain();
  check(got.at(-1)?.startsWith("set-state.sh|idle||k-root|") === true, "Kilo a rejected permission settles idle, not finished");

  await event("session.error", { sessionID: "k-root", error: { name: "MessageAbortedError" } });
  await event("session.idle", { sessionID: "k-root" });
  got = await drain();
  check(got.length === 1 && got[0].startsWith("set-state.sh|idle||k-root|"), "Kilo ESC abort -> idle without asking");

  // Picking an existing session sends no session.created: its prompt rebinds.
  await plugin["chat.message"]({ sessionID: "k-old" }, { parts: [{ type: "text", text: "resume work" }] });
  await event("session.status", { sessionID: "k-root", status: { type: "busy" } });
  got = await drain();
  check(got[0]?.startsWith("auto-desc.sh|clear|kilo|") && got[1]?.startsWith("auto-desc.sh|set|resume work|"), "Kilo prompt in another root clears then sets the label");
  check(got[2]?.startsWith("set-state.sh|working||k-old|") && got[2].includes("|kilo|reset|"), "Kilo prompt in another root rebinds the pane");
  check(got[3]?.startsWith("set-state.sh|working||k-root|") && !got[3].includes("|reset|"), "Kilo background root events never steal the pane");

  // A restarted `kilo -c` binds its first root event, and unregisters on exit or
  // an unhandled signal (run in child processes: exit handlers end the process).
  const child = resolve(tmp, "kilo-child.mjs");
  writeFileSync(child, `const { AgentStatusPlugin } = await import(${JSON.stringify(installed("kilo", "plugin"))});
import { readFileSync } from "node:fs";
const plugin = await AgentStatusPlugin();
await plugin.event({ event: { type: "session.status", properties: { sessionID: process.env.KILO_SESSION, status: { type: "busy" } } } });
for (let i = 0; i < 500 && !readFileSync(process.env.AGENT_TEST_LOG, "utf8").includes(\`|\${process.env.KILO_SESSION}|\`); i++) await new Promise(r => setTimeout(r, 10));
if (process.argv.includes("--signal")) process.kill(process.pid, "SIGTERM"); else process.exit(0);
await new Promise(r => setTimeout(r, 5000));
`);
  for (const mode of ["--exit", "--signal"]) {
    const id = `k-resume${mode}`;
    const r = spawnSync(process.execPath, [child, "--continue", mode], { env: { ...process.env, TMUX_PANE: "%6", KILO_SESSION: id }, encoding: "utf8" });
    got = since();
    check(got[0]?.startsWith("auto-desc.sh|clear|kilo|") && got[1]?.startsWith(`set-state.sh|working||${id}|`) && got[1].includes("|kilo|reset|"), `Kilo first root event binds a resumed session (${mode})`);
    check(got.at(-1)?.startsWith(`clear-state.sh|quit|${id}|kilo|`) === true, `Kilo clears its instance on ${mode.slice(2)}`);
    check(mode === "--exit" ? r.status === 0 : r.signal === "SIGTERM", `Kilo ${mode.slice(2)} still ends the process (${r.status} ${r.signal} ${r.stderr})`);
  }

  // The default TUI runs the plugin in a worker, where exit handlers never
  // run: Kilo calls dispose() as it quits.
  const quitting = await AgentStatusPlugin();
  await quitting["chat.message"]({ sessionID: "k-quit" }, { parts: [] });
  check(await waitFor("|k-quit|"), "Kilo binds a session before quitting");
  since();
  await quitting.dispose();
  got = since();
  check(got.length === 1 && got[0].startsWith("clear-state.sh|quit|k-quit|kilo|"), "Kilo dispose clears its instance");
  await quitting.dispose();
  check(since().length === 0, "Kilo clears its instance once");

  // Events and prompts without a session belong to no root.
  await plugin["chat.message"]({}, { parts: [{ type: "text", text: "no session" }] });
  await event("session.error", { error: { name: "APIError" } });
  await event("session.status", { status: { type: "busy" } });
  got = await drain();
  check(got.length === 0, `Kilo reports nothing without a session (${JSON.stringify(got)})`);

  // A report still running, or queued, as Kilo quits lands before the clear
  // or not at all.
  process.env.TMUX_PANE = "%8";
  const racing = await (await import(resolve(slow, "scripts/kilo/agent-status.js"))).AgentStatusPlugin();
  await racing["chat.message"]({ sessionID: "k-race" }, { parts: [] });
  check(await waitFor("set-state.sh|working||k-race|started"), "Kilo starts a slow report");
  await racing.event({ event: { type: "session.status", properties: { sessionID: "k-race", status: { type: "busy" } } } });
  await racing.dispose();
  await sleep(1500);
  got = since();
  check(clearedLast(got, "clear-state.sh|quit|k-race|kilo|"), `Kilo quit clears after its last report (${JSON.stringify(got)})`);
}

// -------------------------------------------------------- OpenCode TUI
process.env.TMUX_PANE = "%4";
{
  const tui = (await import(resolve(root, "scripts/opencode/agent-status-tui.js"))).default;
  const sessions: Record<string, any> = { A: { id: "A" }, B: { id: "B" }, C: { id: "C", parentID: "A" } };
  let route: any = { name: "home" };
  let dispose: Function | undefined;
  const exitListeners = process.listenerCount("exit");
  await tui.tui({ route: { get current() { return route; } }, state: { session: { get: (id: string) => sessions[id] } }, lifecycle: { onDispose: (fn: Function) => { dispose = fn; } } });
  const open = async (id: string) => { route = { name: "session", params: { sessionID: id } }; await sleep(250); };
  await open("A");
  check(await waitFor("set-state.sh|idle||A||opencode|bind|"), "TUI root selection binds the pane");
  let got = since();
  check(got.length === 1, "TUI root selection leaves the label to set-state (bind)");
  check(got.every(l => l.endsWith("<stdin:closed>")), "TUI closes script stdin");
  await open("C"); await open("A");
  check(since().length === 0, "TUI returning from a child view to the same root keeps state and label");
  await open("B");
  check(await waitFor("set-state.sh|idle||B||opencode|bind|"), "TUI switching roots binds the new root");
  got = since();
  check(process.listenerCount("exit") === exitListeners + 1, "TUI registers an exit cleanup");
  dispose?.();
  got = since();
  check(got.length === 1 && got[0].startsWith("clear-state.sh|quit|B|opencode|"), "TUI dispose clears the bound root synchronously");
  check(process.listenerCount("exit") === exitListeners, "TUI dispose removes its exit cleanup");

  // A failing reset backs off instead of retrying every 100ms; missing scripts
  // stop it. Each case is a plugin copy with its own scripts.
  const start = async (plugin: string, id: string) => {
    const file = resolve(plugin, "scripts/opencode/agent-status-tui.js");
    mkdirSync(dirname(file), { recursive: true }); copyFileSync(resolve(root, "scripts/opencode/agent-status-tui.js"), file);
    const copy = (await import(file)).default;
    let stop: Function | undefined; const selected = { name: "session", params: { sessionID: id } };
    sessions[id] = { id };
    await copy.tui({ route: { get current() { return selected; } }, state: { session: { get: (sid: string) => sessions[sid] } }, lifecycle: { onDispose: (fn: Function) => { stop = fn; } } });
    return stop!;
  };
  const failing = resolve(tmp, "plugin-failing/scripts/agent"); mkdirSync(failing, { recursive: true });
  executable(resolve(failing, "set-state.sh"), `#!/bin/sh\necho "set-state.sh|$3|failed" >> "$AGENT_TEST_LOG"\nexit 1\n`);
  let stop = await start(resolve(tmp, "plugin-failing"), "F1");
  await sleep(1000); stop();
  const attempts = since().filter(l => l.includes("|F1|failed")).length;
  check(attempts >= 2 && attempts <= 5, `TUI backs off failed resets (${attempts} attempts in 1s)`);
  const empty = resolve(tmp, "plugin-empty");
  stop = await start(empty, "E1");
  await sleep(300);
  const late = resolve(empty, "scripts/agent"); mkdirSync(late, { recursive: true });
  executable(resolve(late, "set-state.sh"), `#!/bin/sh\necho "set-state.sh|$3|late" >> "$AGENT_TEST_LOG"\n`);
  await sleep(500); stop();
  check(!since().some(l => l.includes("|E1|")), "TUI stops retrying once the scripts are missing");
  // A script it cannot even start (an argument Node rejects) must not
  // throw into OpenCode.
  let threw = false;
  try { stop = await start(resolve(tmp, "plugin-bad-id"), "bad\0id"); await sleep(300); stop(); } catch { threw = true; }
  check(!threw, "TUI survives a script it cannot start");
  // A bind still running as the TUI quits lands before the clear or not at all.
  since();
  stop = await start(slow, "Q1");
  check(await waitFor("set-state.sh|idle||Q1|started"), "TUI starts a slow bind");
  stop();
  await sleep(1500);
  got = since();
  check(clearedLast(got, "clear-state.sh|quit|Q1|opencode|"), `TUI quit clears after its bind (${JSON.stringify(got)})`);
}

// ------------------------------------------------------ OpenCode 2 TUI
// OpenCode 2 runs sessions in a shared service; the TUI plugin reports alone,
// from its events, for the root session of the active tab.
process.env.TMUX_PANE = "%7";
{
  const v2 = (await import(resolve(root, "scripts/opencode/v2/tui.js"))).default;
  check(typeof v2.id === "string" && typeof v2.setup === "function", "OpenCode 2 TUI plugin has an id and setup()");
  const handlers: Record<string, Function[]> = {}, parents: Record<string, string> = {};
  const running = new Set<string>();
  let route: any = { type: "home" };
  const ctx = {
    ui: { router: { current: () => route } },
    data: {
      on: (type: string, fn: Function) => { (handlers[type] ??= []).push(fn); return () => { handlers[type] = handlers[type].filter(f => f !== fn); }; },
      session: { root: (id: string) => { while (parents[id]) id = parents[id]; return id; }, status: (id: string) => running.has(id) ? "running" : "idle" },
    },
  };
  const emit = (type: string, data: any) => { for (const fn of handlers[type] ?? []) fn({ id: "evt", type, data }); };
  const quiet = async (what: string) => { await sleep(250); check(since().length === 0, `OpenCode 2: ${what} reports nothing`); };
  const expect = async (what: string, ...want: string[]) => {
    check(await waitFor(want.at(-1)!), `OpenCode 2: ${what}`);
    await sleep(50);
    const got = since();
    check(got.length === want.length && want.every((w, i) => got[i]?.startsWith(w)), `OpenCode 2: ${what} (${JSON.stringify(got)})`);
  };
  const open = (id: string) => { route = { type: "session", sessionID: id }; };
  const exitListeners = process.listenerCount("exit");
  const cleanup = await v2.setup(ctx);
  await quiet("the home screen");

  // A first prompt from the home screen: the session works before the TUI
  // shows it.
  emit("session.created", { sessionID: "R1" });
  emit("session.inbox.enqueued", { sessionID: "R1", inboxID: "m1", item: { type: "user", payload: { text: "fix the bug" }, delivery: "steer" } });
  emit("session.execution.started", { sessionID: "R1" });
  await quiet("an unselected session");
  open("R1");
  await expect("selecting a working session binds it working", "set-state.sh|working||R1|", "auto-desc.sh|clear|opencode|", "auto-desc.sh|set|fix the bug|");

  // Asks, the subagent's too, count until each is answered.
  emit("session.created", { sessionID: "C1", parentID: "R1" }); parents.C1 = "R1";
  emit("permission.asked", { sessionID: "R1", id: "per_1", action: "bash", resources: [] });
  await expect("a permission asks", "set-state.sh|asking||R1|");
  emit("form.created", { form: { id: "frm_1", sessionID: "C1", title: "Which?" } });
  emit("permission.replied", { sessionID: "R1", requestID: "per_1", reply: "once" });
  await quiet("an answer while a subagent still asks");
  emit("form.replied", { sessionID: "C1", id: "frm_1", answer: {} });
  await expect("the last answer resumes work", "set-state.sh|working||R1|");
  emit("session.execution.started", { sessionID: "C1" });
  emit("session.execution.succeeded", { sessionID: "C1" });
  await quiet("a subagent's turn");
  emit("session.execution.succeeded", { sessionID: "R1" });
  await expect("a completed turn finishes", "set-state.sh|finished||R1|");

  // A turn the user stops is not a completion.
  for (const [name, stop] of [
    ["a rejected permission", () => { emit("permission.asked", { sessionID: "R1", id: "per_2" }); emit("permission.replied", { sessionID: "R1", requestID: "per_2", reply: "reject" }); emit("session.execution.succeeded", { sessionID: "R1" }); }],
    ["a cancelled form", () => { emit("form.created", { form: { id: "frm_2", sessionID: "R1" } }); emit("form.cancelled", { sessionID: "R1", id: "frm_2" }); emit("session.execution.succeeded", { sessionID: "R1" }); }],
    ["an interrupt", () => { emit("session.execution.interrupted", { sessionID: "R1", reason: "superseded" }); emit("session.execution.interrupted", { sessionID: "R1", reason: "user" }); }],
  ] as const) {
    emit("session.execution.started", { sessionID: "R1" });
    stop();
    check(await waitFor("set-state.sh|idle||R1|"), `OpenCode 2: ${name} settles idle`);
    await sleep(50);
    check(!since().some(l => l.startsWith("set-state.sh|finished")), `OpenCode 2: ${name} does not finish`);
  }
  // A subagent's rejected permission carries feedback: the turn goes on.
  emit("session.execution.started", { sessionID: "R1" });
  emit("permission.asked", { sessionID: "C1", id: "per_3" });
  emit("permission.replied", { sessionID: "C1", requestID: "per_3", reply: "reject" });
  emit("session.execution.succeeded", { sessionID: "R1" });
  await expect("a turn that goes on after a subagent's rejected permission finishes", "set-state.sh|working||R1|", "set-state.sh|asking||R1|", "set-state.sh|working||R1|", "set-state.sh|finished||R1|");
  // So does a subagent's cancelled form: it ends only that ask.
  emit("session.execution.started", { sessionID: "R1" });
  emit("form.created", { form: { id: "frm_3", sessionID: "C1" } });
  emit("form.cancelled", { sessionID: "C1", id: "frm_3" });
  emit("session.execution.succeeded", { sessionID: "R1" });
  await expect("a turn that goes on after a subagent's cancelled form finishes", "set-state.sh|working||R1|", "set-state.sh|asking||R1|", "set-state.sh|working||R1|", "set-state.sh|finished||R1|");
  emit("session.execution.started", { sessionID: "R1" });
  emit("session.execution.failed", { sessionID: "R1", error: { type: "unknown", message: "boom" } });
  await expect("a failed turn finishes", "set-state.sh|working||R1|", "set-state.sh|finished||R1|");

  // Tabs: the pane follows the active one.
  emit("session.execution.started", { sessionID: "R2" });
  emit("session.execution.started", { sessionID: "OTHER" });
  await quiet("a background tab or another TUI's session");
  open("R2");
  await expect("switching to a busy tab shows it working", "set-state.sh|working||R2|", "auto-desc.sh|clear|opencode|");
  emit("session.execution.succeeded", { sessionID: "R2" });
  await expect("the active tab finishes", "set-state.sh|finished||R2|");
  emit("session.execution.started", { sessionID: "R1" });
  emit("session.execution.succeeded", { sessionID: "R1" });
  open("C1");
  await expect("a subagent view shows its root, a finished turn as seen", "set-state.sh|idle||R1|", "auto-desc.sh|clear|opencode|", "auto-desc.sh|set|fix the bug|");
  open("R1"); route = { type: "home" };
  await quiet("returning to the root or the home screen");
  // Only a long prompt's start reaches argv, then and on each rebind.
  emit("session.inbox.enqueued", { sessionID: "R4", inboxID: "m4", item: { type: "user", payload: { text: "y".repeat(300000) } } });
  open("R4");
  check(await waitFor("auto-desc.sh|set|y"), "OpenCode 2: a long prompt sets the label");
  await sleep(50);
  check(since().find(l => l.startsWith("auto-desc.sh|set|"))?.split("|")[2].length === 2000, "OpenCode 2: passes only a long prompt's start");
  running.add("R3"); open("R3");
  await expect("a session running before the TUI started shows working", "set-state.sh|working||R3|", "auto-desc.sh|clear|opencode|");

  check(process.listenerCount("exit") === exitListeners + 1, "OpenCode 2 TUI registers an exit cleanup");
  await cleanup();
  const got = since();
  check(got.length === 1 && got[0].startsWith("clear-state.sh|quit|R3|opencode|"), "OpenCode 2 TUI cleanup clears the bound root synchronously");
  check(process.listenerCount("exit") === exitListeners, "OpenCode 2 TUI cleanup removes its exit cleanup");
  check(Object.values(handlers).every(list => list.length === 0), "OpenCode 2 TUI cleanup unsubscribes its events");
}

// A report still running, or queued, as the OpenCode 2 TUI quits lands
// before the clear or not at all.
process.env.TMUX_PANE = "%9";
{
  const v2 = (await import(resolve(slow, "scripts/opencode/v2/tui.js"))).default;
  const handlers: Record<string, Function[]> = {};
  const ctx = {
    ui: { router: { current: () => ({ type: "session", sessionID: "V1" }) } },
    data: { on: (type: string, fn: Function) => { (handlers[type] ??= []).push(fn); return () => {}; }, session: { root: (id: string) => id, status: () => "running" } },
  };
  since();
  const cleanup = await v2.setup(ctx);
  check(await waitFor("set-state.sh|working||V1|started"), "OpenCode 2 starts a slow report");
  for (const fn of handlers["session.execution.succeeded"] ?? []) fn({ data: { sessionID: "V1" } });
  await cleanup();
  await sleep(1500);
  const got = since();
  check(clearedLast(got, "clear-state.sh|quit|V1|opencode|"), `OpenCode 2 quit clears after its last report (${JSON.stringify(got)})`);
}

if (failures) process.exit(1);
console.log("PASS: provider adapters");
