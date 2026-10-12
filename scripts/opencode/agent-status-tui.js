// agent-status.tmux — bind OpenCode's selected root session to this pane.
import { execFile, execFileSync } from "node:child_process";

const quiet = { encoding: "utf8", timeout: 2000, stdio: ["ignore", "pipe", "ignore"] };

export default {
  id: "agent-status.tmux.opencode-session",
  tui: async (api) => {
    if (!process.env.TMUX_PANE) return;
    // `last` is the selected root; `bound` is the root this pane was last reset
    // to. Child views clear only `last`, so returning to the same root keeps its
    // state and label.
    let last, bound, pending = false, dir;
    // Failed resets back off (100ms doubling to 5s); missing scripts stop it.
    let retryAt = 0, delay = 100, missing = false;
    const scripts = () => {
      if (dir === undefined) {
        try { dir = execFileSync("tmux", ["show-option", "-gqv", "@agent-scripts-dir"], quiet).trim(); } catch { dir = ""; }
        dir ||= `${process.env.HOME}/.tmux/plugins/agent-status.tmux/scripts/agent`;
      }
      return dir;
    };
    const sync = () => {
      let id, session;
      try {
        const route = api.route.current;
        id = route?.name === "session" ? route.params?.sessionID : undefined;
        session = typeof id === "string" ? api.state.session.get(id) : undefined;
      } catch { return; }
      if (!session || session.parentID) { last = undefined; return; }
      if (id === last || pending || missing || Date.now() < retryAt) return;
      if (id === bound) { last = id; return; }
      // Selection and server events are separate streams; reset clears the
      // prior stream sequence so neither clock can permanently stale the other.
      // A newly selected root starts idle; its own server events follow.
      pending = true;
      const child = execFile(`${scripts()}/set-state.sh`, ["idle", "", id, "", "opencode", "reset"], { timeout: 5000 }, error => {
        pending = false;
        if (error) {
          if (error.code === "ENOENT") missing = true;
          else { retryAt = Date.now() + delay; delay = Math.min(delay * 2, 5000); }
          return;
        }
        retryAt = 0; delay = 100;
        last = bound = id;
        execFile(`${scripts()}/auto-desc.sh`, ["clear", "opencode"], { timeout: 5000 }, () => {}).stdin?.end();
      });
      child.stdin?.end();
    };
    // Unregister the pane when the TUI goes away; synchronous because the
    // process may be exiting. clear-state ignores a pane rebound elsewhere; its
    // pane lock can wait ~3.5s, so allow 5s.
    let quit = () => {
      quit = () => {};
      if (!bound) return;
      try { execFileSync(`${scripts()}/clear-state.sh`, ["quit", bound, "opencode"], { ...quiet, timeout: 5000 }); } catch {}
    };
    const onExit = () => quit();
    process.once("exit", onExit);
    sync();
    const timer = setInterval(sync, 100);
    api.lifecycle.onDispose(() => { clearInterval(timer); process.off("exit", onExit); quit(); });
  },
};
