// agent-status.tmux — OpenCode lifecycle adapter.
import { execFile, execFileSync } from "node:child_process";

const pane = process.env.TMUX_PANE;
let seq = Date.now() * 1000;
const childSessions = new Set();
// Sessions whose last turn the user aborted: their idle is not a completion.
const aborted = new Set();
const statuses = new Map([["idle", "finished"], ["active", "working"], ["busy", "working"], ["pending", "working"], ["retry", "working"], ["running", "working"], ["streaming", "working"], ["working", "working"]]);
const childStates = new Map([["permission.asked", "asking"], ["question.asked", "asking"], ["permission.replied", "working"], ["question.replied", "working"], ["question.rejected", "working"]]);
let scripts;
function scriptsDir() {
  if (scripts !== undefined) return scripts;
  try { scripts = execFileSync("tmux", ["show-option", "-gqv", "@agent-scripts-dir"], { encoding: "utf8", timeout: 2000, stdio: ["ignore", "pipe", "ignore"] }).trim(); } catch { scripts = ""; }
  // Cache the fallback too, or every later call would resolve to "/<script>".
  return scripts ||= `${process.env.HOME}/.tmux/plugins/agent-status.tmux/scripts/agent`;
}
// Serialized, bounded, and never rejecting: a stuck status script must not
// stall later updates or the agent. Stdin is closed so no script can wait on it.
let chain = Promise.resolve();
function run(name, args) {
  chain = chain.then(() => new Promise(resolve => {
    try { execFile(`${scriptsDir()}/${name}`, args, { timeout: 5000 }, () => resolve()).stdin?.end(); } catch { resolve(); }
  }));
  return chain;
}
function report(state, sessionID, reset = false) {
  if (sessionID && (state === "working" || state === "asking")) aborted.delete(sessionID);
  return run("set-state.sh", [state, "", sessionID || "", String(++seq), "opencode", reset ? "reset" : ""]);
}
function finish(sessionID) { return report(sessionID && aborted.has(sessionID) ? "idle" : "finished", sessionID); }
function sessionID(properties) { return typeof properties?.sessionID === "string" && properties.sessionID || undefined; }
function statusState(status) { const kind = typeof status === "string" ? status : status?.type; return typeof kind === "string" ? statuses.get(kind.toLowerCase()) : undefined; }

export const AgentStatusPlugin = async () => {
  if (!pane) return {};
  return {
    // Fire-and-forget: the chain keeps order without delaying the turn.
    "chat.message": async ({ sessionID }, output) => {
      if (sessionID && childSessions.has(sessionID)) return;
      const prompt = output?.parts?.find(part => part?.type === "text" && part.text)?.text;
      if (prompt) void run("auto-desc.sh", ["set", prompt]);
      void report("working", sessionID);
    },
    event: async ({ event }) => {
      const type = event?.type, properties = event?.properties || {};
      // Session lifecycle events carry the session as `info` (child: info.parentID).
      const info = typeof type === "string" && type.startsWith("session.") ? properties.info : undefined;
      const id = sessionID(properties) || (typeof info?.id === "string" && info.id) || undefined;
      if (info?.id && info.parentID) childSessions.add(info.id);
      if (id && childSessions.has(id)) {
        const state = childStates.get(type);
        if (state) void report(state); // never let a child replace root identity
        return;
      }
      // OpenCode's server events are global. Report their session identity and
      // let the TUI-selected @agent-instance reject unrelated root sessions.
      if (type === "session.created" || type === "session.updated" || type === "session.deleted") return;
      if (type === "session.status") {
        const state = statusState(properties.status);
        if (state === "finished") void finish(id); else if (state) void report(state, id);
        return;
      }
      // ESC aborts surface as MessageAbortedError; the user is already here.
      if (type === "session.error" && properties.error?.name === "MessageAbortedError") { if (id) aborted.add(id); return; }
      if (["tool.execute.before", "tool.execute.after", "permission.replied", "question.replied", "question.rejected", "session.compacted"].includes(type)) void report("working", id);
      else if (["permission.asked", "question.asked", "session.error"].includes(type)) void report("asking", id);
      else if (type === "session.idle") void finish(id);
    },
  };
};
