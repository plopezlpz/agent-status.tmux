// agent-status.tmux — Kilo lifecycle adapter.
import { execFileSync } from "node:child_process";
import { askingEvents, childStates, lifecycle, scriptsDir, sessionID, statusState, workingEvents } from "../opencode/lifecycle.js";
// Kilo has no TUI selection plugin here, so pane ownership is gated on the
// command line: headless commands (`kilo run`, `serve`, ...) can inherit
// TMUX_PANE from an agent pane but must never report or reset it.
const headless = new Set(["run", "serve", "web", "acp", "mcp", "github", "pr", "export", "import", "debug"]);
function interactive() { const command = process.argv.slice(2).find(arg => !arg.startsWith("-")); return !headless.has(command); }
const { childSessions, aborted, run, report, finish } = lifecycle("kilo");

export const AgentStatusPlugin = async () => {
  if (!process.env.TMUX_PANE || !interactive()) return {};
  // The root session this process last bound to the pane. `kilo -c` or picking
  // an existing session sends no session.created, so a prompt in another root
  // rebinds; other events bind only while nothing is bound, so concurrent
  // background roots cannot make the pane flap.
  let bound;
  const claim = (id, user) => {
    if (!id || id === bound || (!user && bound !== undefined)) return false;
    bound = id; void run("auto-desc.sh", ["clear", "kilo"]);
    return true;
  };
  // Kilo has no exit event: unregister synchronously as the process ends. A
  // signal is handled only when Kilo itself does not, and is then re-raised.
  let quit = () => {
    quit = () => {};
    if (!bound) return;
    try { execFileSync(`${scriptsDir}/clear-state.sh`, ["quit", bound, "kilo"], {timeout:5000, stdio:"ignore"}); } catch {}
  };
  process.once("exit", () => quit());
  for (const signal of ["SIGINT", "SIGTERM"]) {
    const onSignal = () => {
      process.off(signal, onSignal);
      if (process.listenerCount(signal) > 0) return;
      quit(); process.kill(process.pid, signal);
    };
    try { process.on(signal, onSignal); } catch {}
  }
  return {
    "chat.message": async ({sessionID}, output) => {
      if (sessionID && childSessions.has(sessionID)) return;
      const fresh = claim(sessionID, true);
      const prompt=output?.parts?.find(part => part?.type === "text" && part.text)?.text;
      if (prompt) void run("auto-desc.sh", ["set", prompt]);
      void report("working", sessionID, fresh);
    },
    event: async ({event}) => {
      const type=event?.type, p=event?.properties || {};
      // Session lifecycle events carry the session as `info` (child: info.parentID).
      const info = typeof type === "string" && type.startsWith("session.") ? p.info : undefined;
      const id = (typeof info?.id === "string" && info.id) || sessionID(p);
      if (info?.id && info.parentID) childSessions.add(info.id);
      if (id && childSessions.has(id)) { const state=childStates.get(type); if (state) void report(state); return; } // never let a child replace root identity
      if (type === "session.created") { if (id) { claim(id, true); void report("idle", id, true); } return; }
      if (type === "session.updated" || type === "session.deleted") return;
      if (type === "session.error" && p.error?.name === "MessageAbortedError") { if (id) aborted.add(id); return; }
      let state;
      if (type === "session.status") state = statusState(p.status);
      else if (workingEvents.includes(type)) state = "working";
      else if (askingEvents.includes(type)) state = "asking";
      else if (type === "session.idle") state = "finished";
      if (!state) return;
      const fresh = claim(id, false);
      if (state === "finished") void finish(id, fresh); else void report(state, id, fresh);
    },
  };
};
