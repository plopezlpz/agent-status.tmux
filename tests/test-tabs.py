#!/usr/bin/env python3
"""Navigator popup: key bindings, the sessions tab and switching tabs.

Disposable tmux servers on private sockets (TMUX points every plain `tmux`
call at them, including focus-pane.sh's), PTY clients and real fzf matching.
An fzf wrapper replays one scripted step ("key<TAB>query") per fzf run.
Run: python3 tests/test-tabs.py
"""
import fcntl
import os
from pathlib import Path
import pty
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

PLUGIN = Path(__file__).resolve().parents[1]
SCRIPTS = PLUGIN / "scripts"
TMUX = shutil.which("tmux")
FZF = shutil.which("fzf")
SEP = "\x1f"

FZF_WRAPPER = r'''#!/usr/bin/env python3
import os, subprocess, sys
d = os.environ["TEST_FZF_DIR"]
count = os.path.join(d, "count")
n = int(open(count).read()) if os.path.exists(count) else 0
open(count, "w").write(str(n + 1))
key, _, query = open(os.path.join(d, "steps")).read().splitlines()[n].partition("\t")
args = sys.argv[1:]
open(os.path.join(d, "args.%d" % n), "w").write("\n".join(args))
data = sys.stdin.buffer.read()
if key == "cancel":
    sys.exit(130)
r = subprocess.run([FZF] + [a for a in args if not a.startswith("--expect=")] + ["--filter=" + query],
                   input=data, capture_output=True)
lines = r.stdout.decode().split("\n")
out = []
if "--print-query" in args:
    out = [lines.pop(0), key if key in ("tab", "btab") else ""]
out.append(lines[0] if lines else "")
gone = os.environ.get("TEST_GONE_WINDOW")
if gone:
    subprocess.run(["tmux", "kill-window", "-t", gone])
gone = os.environ.get("TEST_GONE_CLIENT")
if gone:
    subprocess.run(["tmux", "detach-client", "-t", gone])
sys.stdout.write("\n".join(out) + "\n")
sys.exit(r.returncode)
'''


@unittest.skipUnless(TMUX and FZF, "tmux and fzf are required")
class TabsTests(unittest.TestCase):
    def setUp(self):
        # /tmp keeps the socket path under the macOS 104-byte limit.
        self.tmp = tempfile.TemporaryDirectory(prefix="agent-tabs-", dir="/tmp")
        self.dir = Path(self.tmp.name)
        self.socket = str(self.dir / "s")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("TMUX", "FZF_", "AGENT_NAV"))}
        self.env.update(TERM="xterm-256color", SHELL="/bin/sh", TMUX_TMPDIR=str(self.dir))
        self.clients = []
        self.addCleanup(self.cleanup)
        self.tm("-f", "/dev/null", "new-session", "-d", "-s", "home", "-n", "shell", "sleep 600")
        self.tm("set-option", "-gw", "automatic-rename", "off")
        self.tm("set-option", "-g", "@agent-descriptions-dir", str(self.dir / "descriptions"))
        pid = self.tm("display", "-p", "#{pid}").stdout.strip()
        # Plain `tmux` in the scripts under test reaches only this server.
        self.inner = dict(self.env, TMUX=self.socket + "," + pid + ",0")

    def cleanup(self):
        subprocess.run([TMUX, "-S", self.socket, "kill-server"], env=self.env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for process, master in self.clients:
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            os.close(master)
        self.tmp.cleanup()

    def tm(self, *args, check=True):
        return subprocess.run([TMUX, "-S", self.socket] + list(args), env=self.env, text=True,
                              capture_output=True, timeout=10, check=check)

    def attach(self, session):
        master, slave = pty.openpty()
        tty = os.ttyname(slave)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        process = subprocess.Popen([TMUX, "-S", self.socket, "attach-session", "-t", session],
                                   stdin=slave, stdout=slave, stderr=slave, env=self.env)
        os.close(slave)
        self.clients.append((process, master))
        deadline = time.monotonic() + 3
        while tty not in self.client_sessions():
            if process.poll() is not None or time.monotonic() > deadline:
                self.fail("test client failed to attach")
            time.sleep(0.02)
        return tty

    def client_sessions(self):
        output = self.tm("list-clients", "-F", "#{client_name}" + SEP + "#{session_id}").stdout
        return dict(line.split(SEP) for line in output.splitlines())

    def prepare(self):
        self.origin = self.tm("display", "-p", "-t", "home", "#{session_id}").stdout.strip()
        self.origin_window = self.tm("display", "-p", "-t", "home", "#{window_id}").stdout.strip()
        self.other = self.tm("new-session", "-d", "-P", "-F", "#{session_id}",
                             "-s", "bystander", "sleep 600").stdout.strip()
        self.target = self.tm("new-session", "-d", "-P", "-F", "#{session_id}",
                              "-s", "work project", "-n", "editor main", "sleep 600").stdout.strip()
        self.target_window = self.tm("display", "-p", "-t", self.target, "#{window_id}").stdout.strip()
        self.logs = self.tm("new-window", "-d", "-P", "-F", "#{window_id}",
                            "-t", self.target, "-n", "logs", "sleep 600").stdout.strip()
        self.tm("select-window", "-t", self.target + ":" + self.logs)
        self.client = self.attach(self.origin)
        self.bystander = self.attach(self.other)  # Make another client most recent.
        self.fzf_dir = self.dir / "fzf"
        (self.fzf_dir / "bin").mkdir(parents=True)
        wrapper = self.fzf_dir / "bin/fzf"
        wrapper.write_text(FZF_WRAPPER.replace("[FZF]", repr([FZF])))
        wrapper.chmod(0o755)
        self.run_env = dict(self.inner, PATH=str(self.fzf_dir / "bin") + os.pathsep + self.env["PATH"],
                            TEST_FZF_DIR=str(self.fzf_dir),
                            AGENT_NAV_CLIENT=self.client,
                            AGENT_NAV_SESSION=self.origin,
                            AGENT_NAV_WINDOW=self.origin_window)

    def run_script(self, args, steps, **extra):
        (self.fzf_dir / "steps").write_text("".join(k + "\t" + q + "\n" for k, q in steps))
        (self.fzf_dir / "count").unlink(missing_ok=True)
        return subprocess.run(["bash"] + args, env=dict(self.run_env, **extra),
                              text=True, capture_output=True, timeout=20)

    def switch(self, query, **extra):
        return self.run_script([str(SCRIPTS / "session-switcher.sh")], [("enter", query)], **extra)

    def fzf_args(self, n):
        return (self.fzf_dir / ("args.%d" % n)).read_text().splitlines()

    # ----- bindings --------------------------------------------------------
    def test_bindings_open_their_tab_with_invoking_context(self):
        self.prepare()
        self.tm("set-option", "-g", "@agent-sessions-key", "a")
        subprocess.run([str(PLUGIN / "agent-status.tmux")], env=self.inner, check=True, timeout=20)
        output = self.dir / "popup-context"
        capture = self.dir / "capture.sh"
        capture.write_text('#!/bin/sh\nprintf "%s\\n" "$1" "$AGENT_NAV_CLIENT" "$AGENT_NAV_SESSION" '
                           '"$AGENT_NAV_WINDOW" > ' + shlex.quote(str(output)) + '\n')
        capture.chmod(0o755)
        for key, tab in (("a", "sessions"), ("A", "agents")):
            command = shlex.split(self.tm("list-keys", "-T", "prefix", key).stdout)
            command = command[command.index("run-shell"):]
            self.assertIn('"%s/navigator.sh" %s' % (SCRIPTS, tab), command[-1])
            command[-1] = command[-1].replace(str(SCRIPTS / "navigator.sh"), str(capture))
            self.tm("bind-key", key, *command)
            output.unlink(missing_ok=True)
            self.tm("send-keys", "-K", "-c", self.client, "C-b", key)
            deadline = time.monotonic() + 3
            while not (output.exists() and output.read_text()) and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertEqual(output.read_text().splitlines(),
                             [tab, self.client, self.origin, self.origin_window])

    def test_sessions_key_is_unbound_by_default(self):
        self.tm("unbind-key", "-T", "prefix", "a", check=False)
        subprocess.run([str(PLUGIN / "agent-status.tmux")], env=self.inner, check=True, timeout=20)
        self.assertEqual(self.tm("list-keys", "-T", "prefix", "a", check=False).stdout, "")

    # ----- sessions tab ------------------------------------------------------
    def test_session_window_query_targets_only_invoker_and_keeps_zoom(self):
        self.prepare()
        target = self.target + ":" + self.target_window
        self.tm("split-window", "-d", "-t", target, "sleep 600")
        self.tm("resize-pane", "-Z", "-t", target)
        result = self.switch("'work 'editor")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.client_sessions(), {self.client: self.target, self.bystander: self.other})
        self.assertEqual(self.tm("display", "-p", "-t", self.target, "#{window_id}").stdout.strip(), self.target_window)
        self.assertEqual(self.tm("display", "-p", "-t", target, "#{window_zoomed_flag}").stdout.strip(), "1")

    def test_session_row_and_folder_query(self):
        self.prepare()
        result = self.switch("'bystander 'window")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.client_sessions()[self.client], self.other)
        folder = self.dir / "unique-folder"
        folder.mkdir()
        self.tm("new-window", "-d", "-t", self.target, "-n", "folder-test", "-c", str(folder), "sleep 600")
        result = self.switch("unique-folder")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.client_sessions()[self.client], self.target)
        self.assertEqual(self.client_sessions()[self.bystander], self.other)

    def test_no_match_and_missing_context_do_not_switch(self):
        self.prepare()
        before = self.client_sessions()
        self.assertEqual(self.switch("no-such-search-result-xyz").returncode, 0)
        self.assertEqual(self.run_script([str(SCRIPTS / "session-switcher.sh")], [("cancel", "")]).returncode, 0)
        self.assertNotEqual(self.switch("work editor", AGENT_NAV_CLIENT="").returncode, 0)
        self.assertEqual(self.client_sessions(), before)

    def test_stale_window_and_client_do_not_redirect(self):
        self.prepare()
        before = self.client_sessions()
        result = self.switch("'work 'editor", TEST_GONE_WINDOW=self.target + ":" + self.target_window)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.client_sessions(), before)
        self.switch("'work 'logs", TEST_GONE_CLIENT=self.client)
        self.assertEqual(self.client_sessions(), {self.bystander: self.other})

    def test_linked_window_keeps_selected_session(self):
        self.prepare()
        linked = self.tm("new-session", "-d", "-P", "-F", "#{session_id}",
                         "-s", "linked destination", "sleep 600").stdout.strip()
        self.tm("link-window", "-s", self.target + ":" + self.target_window, "-t", linked + ":5")
        result = self.switch("'linked 'editor")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.client_sessions(), {self.client: linked, self.bystander: self.other})
        self.assertEqual(self.tm("display", "-p", "-t", linked, "#{window_id}").stdout.strip(), self.target_window)

    # ----- tabs --------------------------------------------------------------
    def test_tab_keeps_query_across_tabs_then_switches(self):
        self.prepare()
        result = self.run_script([str(SCRIPTS / "navigator.sh"), "sessions"],
                                 [("tab", "wor"), ("btab", "work"), ("enter", "'work 'editor")])
        self.assertEqual(result.returncode, 0, result.stderr)
        first, second, third = (self.fzf_args(n) for n in range(3))
        self.assertIn("--query=", first)
        self.assertIn("--with-nth=5..", first)       # sessions tab
        self.assertIn("--query=wor", second)
        self.assertIn("--with-nth=4..", second)      # agents tab
        self.assertIn("--query=work", third)
        self.assertIn("--with-nth=5..", third)
        for args in (first, second):
            label = next(a for a in args if a.startswith("--border-label="))
            self.assertIn(" agents ", label)
            self.assertIn(" sessions ", label)
        self.assertEqual(self.client_sessions(), {self.client: self.target, self.bystander: self.other})

    def test_standalone_tab_has_no_tab_keys(self):
        self.prepare()
        self.switch("'work 'editor")
        args = self.fzf_args(0)
        self.assertFalse([a for a in args if a.startswith("--expect")])
        self.assertNotIn("--print-query", args)

    def test_cancel_and_no_match_in_tabs_do_not_switch(self):
        self.prepare()
        before = self.client_sessions()
        result = self.run_script([str(SCRIPTS / "navigator.sh"), "agents"], [("tab", "x"), ("cancel", "")])
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_script([str(SCRIPTS / "navigator.sh"), "sessions"], [("enter", "no-such-thing-xyz")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.client_sessions(), before)

    def test_agent_card_jumps_on_invoking_client(self):
        self.prepare()
        pane = self.tm("display", "-p", "-t", self.target + ":" + self.target_window, "#{pane_id}").stdout.strip()
        self.tm("set-option", "-p", "-t", pane, "@agent-state", "idle")
        self.tm("set-option", "-p", "-t", pane, "@agent-auto-description", "unique agent task")
        result = self.run_script([str(SCRIPTS / "navigator.sh"), "agents"], [("enter", "unique agent task")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.client_sessions(), {self.client: self.target, self.bystander: self.other})
        self.assertEqual(self.tm("display", "-p", "-t", self.target, "#{window_id}").stdout.strip(), self.target_window)


if __name__ == "__main__":
    unittest.main(verbosity=2)
