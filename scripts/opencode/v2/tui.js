// agent-status.tmux — OpenCode 2 adapter: a TUI plugin, installed as the
// plugins/agent-status.tmux directory (a symlink to this one).
//
// OpenCode 2 runs every session in one shared background service, which
// belongs to no pane, so all reporting comes from here, the TUI process in
// the pane. The pane shows the root session of the active tab: switching tabs
// rebinds it to that session's state.
import { execFileSync } from "node:child_process";
import { lifecycle, scriptsDir } from "../lifecycle.js";

export default {
  id: "agent-status.tmux.opencode-tui",
  setup: (ctx) => {
    if (!process.env.TMUX_PANE) return;
    const { run, report, stop } = lifecycle("opencode");
    // Per root session, from the service's events (it sends every session's):
    // its state, open asks (permission and form ids), whether the user stopped
    // its turn (a rejected permission or cancelled form), its first prompt.
    const states = new Map(), asks = new Map(), stopped = new Set(), prompts = new Map();
    const parents = new Map();
    let bound;
    const rootOf = (id) => {
      let root;
      try { root = ctx.data.session.root(id); } catch {}
      if (typeof root === "string" && root !== id) return root;
      for (let n = 0; parents.has(id) && n < 100; n++) id = parents.get(id);
      return id;
    };
    const root = (id) => typeof id === "string" && rootOf(id) === id;
    // The pane follows the active tab's root; the home screen keeps it.
    const sync = () => {
      let id;
      try {
        const route = ctx.ui.router.current();
        if (route?.type === "session" && typeof route.sessionID === "string") id = rootOf(route.sessionID);
      } catch { return; }
      if (!id || id === bound) return;
      bound = id;
      // A completion shown on selection is already seen.
      let state = states.get(id);
      if (!state) { try { state = ctx.data.session.status(id) === "running" ? "working" : "idle"; } catch { state = "idle"; } }
      void report(state === "finished" ? "idle" : state, id, true);
      void run("auto-desc.sh", ["clear", "opencode"]);
      if (prompts.has(id)) void run("auto-desc.sh", ["set", prompts.get(id)]);
    };
    const set = (id, state) => {
      if (states.get(id) === state) return;
      states.set(id, state);
      if (id === bound) void report(state, id); else sync();
    };
    const ask = (sessionID, key, open) => {
      if (typeof sessionID !== "string" || !key) return;
      const id = rootOf(sessionID), keys = asks.get(id) ?? new Set();
      if (open) keys.add(key); else keys.delete(key);
      asks.set(id, keys);
      if (keys.size) set(id, "asking");
      else if (states.get(id) === "asking") set(id, "working");
    };
    const end = (sessionID, state) => {
      if (!root(sessionID)) return;
      asks.delete(sessionID);
      set(sessionID, state === "finished" && stopped.has(sessionID) ? "idle" : state);
      stopped.delete(sessionID);
    };
    const handlers = {
      "session.created": ({ sessionID, parentID }) => { if (typeof parentID === "string") parents.set(sessionID, parentID); },
      "session.deleted": ({ sessionID }) => { for (const map of [states, asks, prompts, parents]) map.delete(sessionID); },
      "session.inbox.enqueued": ({ sessionID, item }) => {
        const text = item?.type === "user" ? item.payload?.text : undefined;
        if (!root(sessionID) || typeof text !== "string" || !text.trim() || prompts.has(sessionID)) return;
        // Its start only: a whole pasted file must not reach argv.
        prompts.set(sessionID, text.slice(0, 2000));
        sync();
        if (sessionID === bound) void run("auto-desc.sh", ["set", prompts.get(sessionID)]);
      },
      "session.execution.started": ({ sessionID }) => {
        if (!root(sessionID)) return;
        stopped.delete(sessionID);
        set(sessionID, asks.get(sessionID)?.size ? "asking" : "working");
      },
      "session.execution.succeeded": ({ sessionID }) => end(sessionID, "finished"),
      "session.execution.failed": ({ sessionID }) => end(sessionID, "finished"),
      // A superseded turn is followed by the next one.
      "session.execution.interrupted": ({ sessionID, reason }) => { if (reason !== "superseded") end(sessionID, "idle"); },
      "permission.asked": ({ sessionID, id }) => ask(sessionID, id, true),
      // Only the session's own reject or cancel stops its turn. A subagent's
      // carries the user's feedback: the subagent goes on, and so does the
      // turn.
      "permission.replied": ({ sessionID, requestID, reply }) => {
        if (reply === "reject" && root(sessionID)) stopped.add(sessionID);
        ask(sessionID, requestID, false);
      },
      "form.created": ({ form }) => ask(form?.sessionID, form?.id, true),
      "form.replied": ({ sessionID, id }) => ask(sessionID, id, false),
      "form.cancelled": ({ sessionID, id }) => {
        if (root(sessionID)) stopped.add(sessionID);
        ask(sessionID, id, false);
      },
    };
    const offs = [];
    for (const [type, handler] of Object.entries(handlers)) {
      try { offs.push(ctx.data.on(type, (event) => { try { handler(event?.data ?? {}); } catch {} })); } catch {}
    }
    // Unregister the pane when the TUI goes away; synchronous because the
    // process may be exiting. clear-state ignores a pane rebound elsewhere; its
    // pane lock can wait ~3.5s, so allow 5s. Reports stop first: none may
    // land after the clear.
    let quit = () => {
      quit = () => {};
      stop();
      if (!bound) return;
      try { execFileSync(`${scriptsDir}/clear-state.sh`, ["quit", bound, "opencode"], { timeout: 5000, stdio: "ignore" }); } catch {}
    };
    const onExit = () => quit();
    process.once("exit", onExit);
    sync();
    const timer = setInterval(sync, 100);
    return () => {
      clearInterval(timer);
      for (const off of offs) { try { off?.(); } catch {} }
      process.off("exit", onExit);
      quit();
    };
  },
};
