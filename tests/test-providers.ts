// Behavioural tests for the OMP, OpenCode, Kilo, Kimi, and MastraCode adapters.
// Script calls land in argv-logging stubs under a temp HOME (tmux is stubbed to
// fail, so adapters fall back to $HOME/.tmux/plugins/...); no provider, live
// tmux server, or LLM is involved.
//
// Run with: bun tests/test-providers.ts   (skipped elsewhere; see tests/run.sh)
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { execFileSync, spawnSync } from "node:child_process";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const executable = (path: string, body: string) => { writeFileSync(path, body); chmodSync(path, 0o755); };

// Bun resolves execFileSync commands against the PATH the process started
// with, so the isolated environment (tmux stub first on PATH, temp HOME, and an
// empty TMUX_TMPDIR so even a real tmux finds no server) must exist before the
// adapters run: build it, then re-run this file inside it.
if (!process.env.AGENT_TEST_ROOT) {
  const tmp = mkdtempSync(resolve(tmpdir(), "agent-status-providers."));
  const home = resolve(tmp, "home"), bin = resolve(tmp, "bin");
  const stubs = resolve(home, ".tmux/plugins/agent-status.tmux/scripts/agent");
  mkdirSync(stubs, { recursive: true }); mkdirSync(bin, { recursive: true }); mkdirSync(resolve(tmp, "tmux"));
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
  // The hook adapters' shared body is real; only what it calls is stubbed.
  copyFileSync(resolve(root, "scripts/agent/hook-event.sh"), resolve(stubs, "hook-event.sh"));
  // Lookups fail (forcing the HOME fallback) except a busy pane state, which
  // an adapter must not copy onto a newly selected session.
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

// ---------------------------------------------------------------- OMP
process.env.TMUX_PANE = "%1";
process.env.HERDR_OMP_IDLE_DEBOUNCE_MS = "0";
process.env.HERDR_OMP_RETRY_GRACE_MS = "5";
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
  // Abort while asking: the blocker never resolves, so agent_end must clear it.
  await handlers.agent_start({}, ctx); await handlers.tool_approval_requested({reason:"allow?"},ctx);
  await handlers.agent_end({messages:[]}); await tick(5);
  check(states().at(-1) === "finished", "OMP abort while blocked does not stay asking");
  await handlers.agent_start({}, ctx); await tick();
  check(states().at(-1) === "working", "OMP agent_start resets stale blockers");
  // A blocker during the retry grace must not cancel the retry expiry.
  await handlers.agent_end({messages:[{role:"assistant",stopReason:"error",errorMessage:"429 rate limit"}]});
  await tick(1); check(states().at(-1) === "working", "OMP retry grace remains working");
  await handlers.tool_execution_start({toolName:"ask",args:{questions:"not-an-array"}},ctx);
  await handlers.tool_execution_end({toolName:"ask"},ctx);
  await tick(15); check(states().at(-1) === "asking", "OMP retry expiry asks for attention after a blocker");
  await handlers.agent_start({},ctx); await tick();
  await handlers.tool_execution_start({toolName:"ask",args:{questions:[{},{question:"Which?"}]}},ctx); await tick();
  check(calls.filter(c=>c.cmd.endsWith("set-state.sh")).at(-1)?.args[1] === "Which?", "OMP ask forwards the first question");
  await handlers.tool_execution_end({toolName:"ask"},ctx);
  const clearsBefore = descs().length;
  await handlers.session_switch({reason:"new"}, ctx); await tick();
  check(states().at(-1) === "idle" && descs().length === clearsBefore + 1 && descs().at(-1) === "clear", "OMP session_switch resets and clears the label");
  const shutdown = handlers.session_shutdown({});
  check(shutdown instanceof Promise, "OMP session_shutdown returns its clear for OMP to await");
  await shutdown;
  check(calls.at(-1)?.cmd.endsWith("clear-state.sh") === true && calls.at(-1)?.args.join(" ") === "quit same-id omp", "OMP shutdown clears its own instance");
  check(calls.every(c => typeof c.options?.timeout === "number"), "OMP bounds every exec with a timeout");
}

// ----------------------------------------------------------- OpenCode
{
  // OpenCode and Kilo share lifecycle.js; each adapter keeps its own sessions.
  const { lifecycle } = await import(resolve(root, "scripts/opencode/lifecycle.js"));
  const a = lifecycle("opencode"), b = lifecycle("kilo");
  a.childSessions.add("child"); a.aborted.add("aborted");
  check(!b.childSessions.has("child") && !b.aborted.has("aborted"), "lifecycle() instances keep separate session state");
}
process.env.TMUX_PANE = "%2";
{
  const { AgentStatusPlugin } = await import(installed("opencode", "plugins"));
  const plugin = await AgentStatusPlugin();
  const event = (type: string, properties: any) => plugin.event({ event: { type, properties } });
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
  check(got[0]?.startsWith("auto-desc.sh|set|fix the bug|"), "OpenCode records first prompt text");
  check(got[1]?.startsWith("set-state.sh|working||root-1|") && got[1].includes("|opencode||"), "OpenCode chat.message -> working with root identity");
  check(got.slice(1).map(l => l.split("|")[1]).join(",") === "working,working,asking,finished", "OpenCode root lifecycle mapping");
  check(got.every(l => l.endsWith("<stdin:closed>")), "OpenCode closes script stdin");
  const seqs = got.slice(1).map(l => Number(l.split("|")[4]));
  check(seqs.every((n, i) => i === 0 || n > seqs[i - 1]), "OpenCode sends monotonic sequences");

  await event("session.created", { sessionID: "child-1", info: { id: "child-1", parentID: "root-1" } });
  await plugin["chat.message"]({ sessionID: "child-1" }, { parts: [{ type: "text", text: "subtask" }] });
  await event("session.status", { sessionID: "child-1", status: { type: "busy" } });
  await event("permission.asked", { sessionID: "child-1" });
  await event("permission.replied", { sessionID: "child-1" });
  await event("session.idle", { sessionID: "child-1" });
  got = await drain();
  check(got.length === 2 && got[0].startsWith("set-state.sh|asking|||") && got[1].startsWith("set-state.sh|working|||"), "OpenCode child events report only blockers, without identity");
  check(got.every(l => !l.includes("child-1") && !l.includes("|reset|")), "OpenCode child events never carry identity or reset");

  await event("session.error", { sessionID: "root-1", error: { name: "MessageAbortedError", data: { message: "aborted" } } });
  await event("session.status", { sessionID: "root-1", status: { type: "idle" } });
  await event("session.idle", { sessionID: "root-1" });
  got = await drain();
  check(got.length === 2 && got.every(l => l.startsWith("set-state.sh|idle||root-1|")), "OpenCode ESC abort -> idle without asking or finished");
  await plugin["chat.message"]({ sessionID: "root-1" }, { parts: [] });
  await event("session.error", { sessionID: "root-1", error: { name: "APIError", data: { message: "boom" } } });
  await event("session.idle", { sessionID: "root-1" });
  got = await drain();
  check(got.map(l => l.split("|")[1]).join(",") === "working,asking,finished", "OpenCode real errors still ask, and the next turn finishes");
}

// --------------------------------------------------------------- Kilo
process.env.TMUX_PANE = "%3";
{
  const { AgentStatusPlugin } = await import(installed("kilo", "plugin"));
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

  await event("session.created", { info: { id: "k-child", parentID: "k-root" } });
  await plugin["chat.message"]({ sessionID: "k-child" }, { parts: [{ type: "text", text: "child" }] });
  await event("session.status", { sessionID: "k-child", status: { type: "busy" } });
  await event("question.asked", { sessionID: "k-child" });
  await event("session.idle", { sessionID: "k-child" });
  got = await drain();
  check(got.length === 1 && got[0].startsWith("set-state.sh|asking|||") && !got[0].includes("|reset|"), "Kilo child session never resets and reports without identity");

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
  check(await waitFor("auto-desc.sh|clear|opencode"), "TUI root selection clears the label");
  let got = since();
  check(got[0]?.startsWith("set-state.sh|idle||A||opencode|reset|"), "TUI root selection resets the pane to idle (no copied state)");
  check(got.every(l => l.endsWith("<stdin:closed>")), "TUI closes script stdin");
  await open("C"); await open("A");
  check(since().length === 0, "TUI returning from a child view to the same root keeps state and label");
  await open("B");
  check(await waitFor("auto-desc.sh|clear|opencode"), "TUI switching roots clears the label");
  got = since();
  check(got[0]?.startsWith("set-state.sh|idle||B||opencode|reset|"), "TUI switching roots resets to idle");
  check(process.listenerCount("exit") === exitListeners + 1, "TUI registers an exit cleanup");
  dispose?.();
  got = since();
  check(got.length === 1 && got[0].startsWith("clear-state.sh|quit|B|opencode|"), "TUI dispose clears the bound root synchronously");
  check(process.listenerCount("exit") === exitListeners, "TUI dispose removes its exit cleanup");

  // A failing reset backs off instead of retrying every 100ms; missing scripts stop it.
  const start = async (homeDir: string, id: string) => {
    const saved = process.env.HOME; process.env.HOME = homeDir;
    let stop: Function | undefined; const selected = { name: "session", params: { sessionID: id } };
    sessions[id] = { id };
    await tui.tui({ route: { get current() { return selected; } }, state: { session: { get: (sid: string) => sessions[sid] } }, lifecycle: { onDispose: (fn: Function) => { stop = fn; } } });
    process.env.HOME = saved;
    return stop!;
  };
  const failing = resolve(tmp, "home-failing/.tmux/plugins/agent-status.tmux/scripts/agent"); mkdirSync(failing, { recursive: true });
  executable(resolve(failing, "set-state.sh"), `#!/bin/sh\necho "set-state.sh|$3|failed" >> "$AGENT_TEST_LOG"\nexit 1\n`);
  let stop = await start(resolve(tmp, "home-failing"), "F1");
  await sleep(1000); stop();
  const attempts = since().filter(l => l.includes("|F1|failed")).length;
  check(attempts >= 2 && attempts <= 5, `TUI backs off failed resets (${attempts} attempts in 1s)`);
  const empty = resolve(tmp, "home-empty"); mkdirSync(empty, { recursive: true });
  stop = await start(empty, "E1");
  await sleep(300);
  const late = resolve(empty, ".tmux/plugins/agent-status.tmux/scripts/agent"); mkdirSync(late, { recursive: true });
  executable(resolve(late, "set-state.sh"), `#!/bin/sh\necho "set-state.sh|$3|late" >> "$AGENT_TEST_LOG"\n`);
  await sleep(500); stop();
  check(!since().some(l => l.includes("|E1|")), "TUI stops retrying once the scripts are missing");
}

// ------------------------------------------------- Kimi / MastraCode hooks
for (const [kind, name, headlessArgs, interactiveArgs, moreHeadless, moreInteractive] of [
  ["kimi", "kimi", ["-p", "summarize"], ["--yolo"], [["-m", "k2", "-p", "x"], ["--prompt=x"], ["acp"], ["-S", "-p", "x"]], [["fix the -p flag"], ["--model", "web"], ["-S", "s1", "--yolo"]]],
  ["mastracode", "mastracode", ["--prompt", "summarize"], [], [["-p", "x"], ["--prompt=x"]], [["fix the -p flag"]]],
] as const) {
  const script = resolve(root, `scripts/${kind}/agent-status.sh`);
  const provider = resolve(tmp, `provider-${kind}`); mkdirSync(provider, { recursive: true });
  // A fake provider binary that runs the hook as its child, like the real CLI.
  executable(resolve(provider, name), `#!/bin/bash\n"$HOOK_SCRIPT" "$HOOK_ACTION" < "$HOOK_INPUT"\n`);
  const env = { ...process.env, TMUX_PANE: "%5" };
  const hook = (action: string, payload: object, via?: readonly string[]) => {
    const input = resolve(tmp, "hook-input.json"); writeFileSync(input, JSON.stringify(payload));
    const r = via
      ? spawnSync(resolve(provider, name), [...via], { env: { ...env, HOOK_SCRIPT: script, HOOK_ACTION: action, HOOK_INPUT: input }, encoding: "utf8" })
      : spawnSync(script, [action], { env, input: JSON.stringify(payload), encoding: "utf8" });
    check(r.status === 0, `${kind} ${action} hook exits 0 (${r.stderr})`);
    return since();
  };
  since();
  let got = hook("session", { session_id: "s1", hook_event_name: "SessionStart", source: "startup" });
  check(got[0]?.startsWith(`set-state.sh|idle||s1||${kind}|reset|`), `${kind} SessionStart resets to idle`);
  check(got[1]?.startsWith("auto-desc.sh|clear|startup|"), `${kind} SessionStart passes its real source to auto-desc`);
  got = hook("session", { session_id: "s1", hook_event_name: "SessionStart", source: "compact" });
  check(got.length === 0, `${kind} compact SessionStart neither resets nor clears`);
  got = hook("working", { session_id: "s1", hook_event_name: "UserPromptSubmit", prompt: "hi" }, interactiveArgs);
  check(got.some(l => l.startsWith(`set-state.sh|working||s1||${kind}|`)), `${kind} interactive process reports`);
  got = hook("session", { session_id: "h1", hook_event_name: "SessionStart", source: "startup" }, headlessArgs);
  check(got.length === 0, `${kind} headless process never resets the pane`);
  got = hook("working", { session_id: "h1", hook_event_name: "UserPromptSubmit", prompt: "hi" }, headlessArgs);
  check(got.length === 0, `${kind} headless process never reports`);
  for (const args of moreHeadless) {
    got = hook("working", { session_id: "h1", hook_event_name: "UserPromptSubmit", prompt: "hi" }, args);
    check(got.length === 0, `${kind} ${JSON.stringify(args)} is headless`);
  }
  for (const args of moreInteractive) {
    got = hook("working", { session_id: "s1", hook_event_name: "UserPromptSubmit", prompt: "hi" }, args);
    check(got.some(l => l.startsWith(`set-state.sh|working||s1||${kind}|`)), `${kind} ${JSON.stringify(args)} is interactive`);
  }
  {
    const r = spawnSync(script, ["working"], { env: { ...env, AGENT_TEST_FAIL: "auto-desc.sh" }, input: JSON.stringify({ session_id: "s1", prompt: "hi" }), encoding: "utf8" });
    got = since();
    check(r.status === 0 && got.some(l => l.startsWith(`set-state.sh|working||s1||${kind}|`)), `${kind} a failing auto-desc still reports working`);
  }
  got = hook("blocked", { session_id: "s1", hook_event_name: "PreToolUse", tool_name: "Bash" });
  check(got.length === 1 && got[0].startsWith(`set-state.sh|asking|Bash|s1||${kind}|<stdin:closed>`), `${kind} a blocked tool asks, naming the tool`);
  got = hook("blocked", { session_id: "s1", message: "Allow edit?", tool_name: "Edit" });
  check(got[0]?.startsWith(`set-state.sh|asking|Allow edit?|s1||${kind}|<stdin:closed>`), `${kind} a blocked message wins over the tool name`);
  got = hook("idle", { session_id: "s1", hook_event_name: "Stop" });
  check(got.length === 1 && got[0].startsWith(`set-state.sh|finished||s1||${kind}|<stdin:closed>`), `${kind} Stop finishes the turn`);
  got = hook("interrupt", { session_id: "s1", hook_event_name: "Interrupt" });
  check(got.length === 1 && got[0].startsWith(`set-state.sh|idle||s1||${kind}|<stdin:closed>`), `${kind} an interrupt settles idle without a reset`);
  got = hook("end", { session_id: "s1", hook_event_name: "SessionEnd", reason: "exit" });
  check(got.length === 1 && got[0].startsWith(`clear-state.sh|exit|s1|${kind}|`), `${kind} SessionEnd clears its own instance`);
  got = hook("end", { session_id: "s1", hook_event_name: "SessionEnd" });
  check(got[0]?.startsWith(`clear-state.sh|exit|s1|${kind}|`), `${kind} SessionEnd without a reason still quits`);
}

if (failures) process.exit(1);
console.log("PASS: provider adapters");
