// agent-status.tmux — shared by the OpenCode and Kilo lifecycle adapters.
// Installed adapters are symlinks, so this resolves from the plugin checkout.
import { execFile } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isMainThread } from "node:worker_threads";

// Kilo's `offline` status waits for the user to retry a lost connection.
export const statuses = new Map([["idle", "finished"], ["active", "working"], ["busy", "working"], ["pending", "working"], ["retry", "working"], ["running", "working"], ["streaming", "working"], ["working", "working"], ["offline", "asking"]]);
export const childStates = new Map([["permission.asked", "asking"], ["question.asked", "asking"], ["permission.replied", "working"], ["question.replied", "working"], ["question.rejected", "working"]]);
export const workingEvents = ["permission.replied", "question.replied", "question.rejected", "session.compacted"];
export const askingEvents = ["permission.asked", "question.asked", "session.error"];

// The checkout's state scripts.
export const scriptsDir = resolve(dirname(realpathSync(fileURLToPath(import.meta.url))), "../agent");
export function sessionID(properties) { return typeof properties?.sessionID === "string" && properties.sessionID || undefined; }
export function statusState(status) { const kind = typeof status === "string" ? status : status?.type; return typeof kind === "string" ? statuses.get(kind.toLowerCase()) : undefined; }

// Whether this process is an interactive session that owns its pane. The TUI
// runs its server, and so the plugin, in a worker thread. The main thread
// runs headless commands (`run`, `serve`, a `kilo daemon`, ...), which can
// inherit TMUX_PANE from an agent pane but must never report or reset it,
// and also Kilo's `--mini` and `run --interactive`.
const headless = new Set(["run", "serve", "web", "acp", "mcp", "github", "pr", "export", "import", "debug", "attach", "remote"]);
export function interactive(argv = process.argv, main = isMainThread) {
  if (!main) return true;
  const args = argv.slice(2);
  let command;
  for (let i = 0; i < args.length && command === undefined; i++) {
    if (args[i] === "--log-level") i++;
    else if (!args[i].startsWith("-")) command = args[i];
  }
  if (command === "run") return args.includes("-i") || args.includes("--interactive");
  return !headless.has(command);
}

// The session a user ended without the turn completing: a rejected permission
// or dismissed question stops the turn, and an Esc on a user's `!` shell
// command only ends its output with this note. An Esc on a model turn sends
// MessageAbortedError instead.
const shellAborted = "<metadata>\nUser aborted the command\n</metadata>";
export function stoppedSession(type, properties) {
  if (type === "permission.replied" && properties?.reply === "reject") return sessionID(properties);
  if (type === "question.rejected") return sessionID(properties);
  const part = type === "message.part.updated" ? properties?.part : undefined;
  if (part?.type === "tool" && part.state?.status === "completed" && typeof part.state.output === "string" && part.state.output.endsWith(shellAborted)) {
    return sessionID(part) || sessionID(properties);
  }
  return undefined;
}

// One adapter's reporting state: KIND names it to set-state.sh.
export function lifecycle(kind) {
  let seq = Date.now() * 1000, chain = Promise.resolve();
  // Child session -> its parent session.
  const childSessions = new Map();
  // Sessions whose last turn the user aborted: their idle is not a completion.
  const aborted = new Set();
  // A child's root session: the one whose pane its asks belong to.
  function rootOf(id) {
    for (let seen = 0; childSessions.has(id) && seen < 100; seen++) id = childSessions.get(id);
    return id;
  }
  // Serialized, bounded, and never rejecting: a stuck status script must not
  // stall later updates or the agent. Stdin is closed so no script can wait on it.
  function run(name, args) {
    chain = chain.then(() => new Promise(resolve => {
      try { execFile(`${scriptsDir}/${name}`, args, { timeout: 5000 }, () => resolve()).stdin?.end(); } catch { resolve(); }
    }));
    return chain;
  }
  // RESET: true for a reset, or set-state.sh's flag itself ("bind"). A report
  // without a session would get past set-state.sh's instance and sequence
  // checks: there is none.
  function report(state, id, reset = false) {
    if (!id) return chain;
    if (state === "working" || state === "asking") aborted.delete(id);
    return run("set-state.sh", [state, "", id, String(++seq), kind, reset === true ? "reset" : reset || ""]);
  }
  function finish(id, reset = false) { return report(id && aborted.has(id) ? "idle" : "finished", id, reset); }
  return { childSessions, aborted, rootOf, run, report, finish };
}
