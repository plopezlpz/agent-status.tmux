// agent-status.tmux — OpenCode lifecycle adapter.
import { askingEvents, childStates, lifecycle, sessionID, statusState, workingEvents } from "./lifecycle.js";

const pane = process.env.TMUX_PANE;
const { childSessions, aborted, run, report, finish } = lifecycle("opencode");

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
      if (workingEvents.includes(type)) void report("working", id);
      else if (askingEvents.includes(type)) void report("asking", id);
      else if (type === "session.idle") void finish(id);
    },
  };
};
