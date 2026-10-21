// agent-status.tmux — OpenCode 1.x lifecycle adapter.
import { askingEvents, childStates, interactive, lifecycle, sessionID, statusState, stoppedSession, workingEvents } from "./lifecycle.js";

const pane = process.env.TMUX_PANE;
const { childSessions, aborted, rootOf, run, report, finish, stop } = lifecycle("opencode");

export const AgentStatusPlugin = async () => {
  if (!pane || !interactive()) return {};
  // The TUI's worker, where this runs, shuts down (and disposes this plugin)
  // only after the TUI plugin (agent-status-tui.js) has cleared the pane from
  // the main thread. That plugin posts "quit" on this channel as it quits, so
  // reports stop as quitting starts: none may land after the clear. It is
  // also disposed when turned off in OpenCode's plugin dialog, and posts
  // "start" when turned on again. Disposing this plugin (a reload, a config
  // change) only stops later reports: nothing clears the pane then.
  let quitting = false, channel;
  try {
    channel = new BroadcastChannel("agent-status.tmux.opencode.quit");
    channel.onmessage = ({ data }) => { quitting = data === "quit"; if (quitting) stop(); };
    channel.unref?.();
  } catch {}
  return {
    // Fire-and-forget: the chain keeps order without delaying the turn.
    "chat.message": async ({ sessionID }, output) => {
      if (quitting || !sessionID || childSessions.has(sessionID)) return;
      const prompt = output?.parts?.find(part => part?.type === "text" && part.text)?.text;
      // A prompt claims the pane for its root. The TUI shows a session
      // started from the home screen only after its first events, which a
      // pane still holding the previous session would drop. `bind` leaves a
      // pane already showing this root as it is (the plain report then sets
      // working), and a rebind drops the old label before the new one is set.
      void report("working", sessionID, "bind");
      // Its start only: a whole pasted file must not reach argv.
      if (prompt) void run("auto-desc.sh", ["set", prompt.slice(0, 2000)]);
      void report("working", sessionID);
    },
    event: async ({ event }) => {
      if (quitting) return;
      const type = event?.type, properties = event?.properties || {};
      // Session lifecycle events carry the session as `info` (child: info.parentID).
      const info = typeof type === "string" && type.startsWith("session.") ? properties.info : undefined;
      const id = sessionID(properties) || (typeof info?.id === "string" && info.id) || undefined;
      if (info?.id && info.parentID) childSessions.set(info.id, info.parentID);
      const stopped = stoppedSession(type, properties);
      if (id && childSessions.has(id)) {
        // A child reports only its blockers, as its root: the pane takes them
        // only while it shows that root.
        const state = childStates.get(type);
        if (state) void report(state, rootOf(id));
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
      if (workingEvents.includes(type)) void report("working", id);
      else if (askingEvents.includes(type)) void report("asking", id);
      else if (type === "session.idle") void finish(id);
      // After the report: a working report forgets an earlier abort.
      if (stopped && !childSessions.has(stopped)) aborted.add(stopped);
    },
    // OpenCode calls this as it shuts the plugin down (also on a config
    // reload, after which a new instance reports).
    dispose: async () => { quitting = true; try { channel?.close(); } catch {} },
  };
};

// OpenCode 1.x calls `server`. OpenCode 2 loads this file too, in its shared
// background service, which belongs to no pane: there `setup` does nothing,
// and the TUI plugin (v2/tui.js) reports instead.
export default { id: "agent-status.tmux.opencode", server: AgentStatusPlugin, setup: () => {} };
