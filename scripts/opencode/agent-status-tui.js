// agent-status.tmux — bind OpenCode 1.x's selected root session to this pane.
import { execFile, execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Installed as a symlink to the plugin checkout: run that checkout's scripts.
const scripts = resolve(dirname(realpathSync(fileURLToPath(import.meta.url))), "../agent");

export default {
  id: "agent-status.tmux.opencode-session",
  tui: async (api) => {
    if (!process.env.TMUX_PANE) return;
    // `last` is the selected root; `bound` is the root this pane was last reset
    // to. Child views clear only `last`, so returning to the same root keeps its
    // state and label.
    let last, bound, pending = false;
    // Failed resets back off (100ms doubling to 5s); missing scripts stop it.
    let retryAt = 0, delay = 100, missing = false;
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
      // Selection and server events are separate streams; a reset clears the
      // prior stream sequence so neither clock can permanently stale the other.
      // A newly selected root starts idle, without the old label; its own
      // server events follow. `bind` leaves a pane the server plugin already
      // bound to this root (a first prompt from the home screen) as it is.
      pending = true;
      const child = execFile(`${scripts}/set-state.sh`, ["idle", "", id, "", "opencode", "bind"], { timeout: 5000 }, error => {
        pending = false;
        if (error) {
          if (error.code === "ENOENT") missing = true;
          else { retryAt = Date.now() + delay; delay = Math.min(delay * 2, 5000); }
          return;
        }
        retryAt = 0; delay = 100;
        last = bound = id;
      });
      child.stdin?.end();
    };
    // Unregister the pane when the TUI goes away; synchronous because the
    // process may be exiting. clear-state ignores a pane rebound elsewhere; its
    // pane lock can wait ~3.5s, so allow 5s.
    let quit = () => {
      quit = () => {};
      if (!bound) return;
      try { execFileSync(`${scripts}/clear-state.sh`, ["quit", bound, "opencode"], { timeout: 5000, stdio: "ignore" }); } catch {}
    };
    const onExit = () => quit();
    process.once("exit", onExit);
    sync();
    const timer = setInterval(sync, 100);
    api.lifecycle.onDispose(() => { clearInterval(timer); process.off("exit", onExit); quit(); });
  },
};
