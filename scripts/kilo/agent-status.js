// agent-status.tmux — Kilo lifecycle adapter.
import { execFileSync } from "node:child_process";
import { askingEvents, childStates, interactive, lifecycle, scriptsDir, sessionID, statusState, stoppedSession, workingEvents } from "../opencode/lifecycle.js";
// Kilo has no TUI selection plugin here, so pane ownership is gated on where
// the plugin runs: headless commands (`kilo run`, `serve`, ...) can inherit
// TMUX_PANE from an agent pane but must never report or reset it.
const { childSessions, aborted, rootOf, run, report, finish } = lifecycle("kilo");

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
  // Unregister synchronously as Kilo ends. The default TUI runs this plugin
  // in a worker, where exit and signal handlers never run, and calls
  // `dispose` instead; `kilo --mini` runs it on the main thread. A signal is
  // handled only when Kilo itself does not, and is then re-raised.
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
      // Its start only: a whole pasted file must not reach argv.
      if (prompt) void run("auto-desc.sh", ["set", prompt.slice(0, 2000)]);
      void report("working", sessionID, fresh);
    },
    event: async ({event}) => {
      const type=event?.type, p=event?.properties || {};
      // Session lifecycle events carry the session as `info` (child: info.parentID).
      const info = typeof type === "string" && type.startsWith("session.") ? p.info : undefined;
      const id = (typeof info?.id === "string" && info.id) || sessionID(p);
      if (info?.id && info.parentID) childSessions.set(info.id, info.parentID);
      // A child reports only its blockers, as its root: never a reset.
      if (id && childSessions.has(id)) { const state=childStates.get(type); if (state) void report(state, rootOf(id)); return; }
      if (type === "session.created") { if (id) { claim(id, true); void report("idle", id, true); } return; }
      if (type === "session.updated" || type === "session.deleted") return;
      if (type === "session.error" && p.error?.name === "MessageAbortedError") { if (id) aborted.add(id); return; }
      let state;
      if (type === "session.status") state = statusState(p.status);
      else if (workingEvents.includes(type)) state = "working";
      else if (askingEvents.includes(type)) state = "asking";
      else if (type === "session.idle") state = "finished";
      const stopped = stoppedSession(type, p);
      if (state) {
        const fresh = claim(id, false);
        if (state === "finished") void finish(id, fresh); else void report(state, id, fresh);
      }
      // After the report: a working report forgets an earlier abort.
      if (stopped) aborted.add(stopped);
    },
    // Kilo calls this as it shuts the plugin down (also on a config reload,
    // after which the next root event binds the pane again).
    dispose: async () => quit(),
  };
};

// Kilo's plugin shape; older Kilo builds load the named export.
export default { id: "agent-status.tmux.kilo", server: AgentStatusPlugin };
