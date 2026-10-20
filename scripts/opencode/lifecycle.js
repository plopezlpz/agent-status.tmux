// agent-status.tmux — shared by the OpenCode and Kilo lifecycle adapters.
// Installed adapters are symlinks, so this resolves from the plugin checkout.
import { execFile } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const statuses = new Map([["idle", "finished"], ["active", "working"], ["busy", "working"], ["pending", "working"], ["retry", "working"], ["running", "working"], ["streaming", "working"], ["working", "working"]]);
export const childStates = new Map([["permission.asked", "asking"], ["question.asked", "asking"], ["permission.replied", "working"], ["question.replied", "working"], ["question.rejected", "working"]]);
export const workingEvents = ["tool.execute.before", "tool.execute.after", "permission.replied", "question.replied", "question.rejected", "session.compacted"];
export const askingEvents = ["permission.asked", "question.asked", "session.error"];

// The checkout's state scripts.
export const scriptsDir = resolve(dirname(realpathSync(fileURLToPath(import.meta.url))), "../agent");
export function sessionID(properties) { return typeof properties?.sessionID === "string" && properties.sessionID || undefined; }
export function statusState(status) { const kind = typeof status === "string" ? status : status?.type; return typeof kind === "string" ? statuses.get(kind.toLowerCase()) : undefined; }

// One adapter's reporting state: KIND names it to set-state.sh.
export function lifecycle(kind) {
  let seq = Date.now() * 1000, chain = Promise.resolve();
  const childSessions = new Set();
  // Sessions whose last turn the user aborted: their idle is not a completion.
  const aborted = new Set();
  // Serialized, bounded, and never rejecting: a stuck status script must not
  // stall later updates or the agent. Stdin is closed so no script can wait on it.
  function run(name, args) {
    chain = chain.then(() => new Promise(resolve => {
      try { execFile(`${scriptsDir}/${name}`, args, { timeout: 5000 }, () => resolve()).stdin?.end(); } catch { resolve(); }
    }));
    return chain;
  }
  function report(state, id, reset = false) {
    if (id && (state === "working" || state === "asking")) aborted.delete(id);
    return run("set-state.sh", [state, "", id || "", String(++seq), kind, reset ? "reset" : ""]);
  }
  function finish(id, reset = false) { return report(id && aborted.has(id) ? "idle" : "finished", id, reset); }
  return { childSessions, aborted, run, report, finish };
}
