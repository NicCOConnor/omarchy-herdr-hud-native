import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT
SHELL = Path("/usr/share/omarchy/shell")

def module(name):
    loader = importlib.machinery.SourceFileLoader(name, str(NATIVE / "bin" / name))
    spec = importlib.util.spec_from_loader(name, loader)
    result = importlib.util.module_from_spec(spec)
    loader.exec_module(result)
    return result

class NativeTests(unittest.TestCase):
    def test_attach_execs_only_explicit_target(self):
        attach = module("herdr-attach")
        with patch.object(attach.shutil, "which", return_value="/usr/bin/herdr"), patch.object(attach.os, "execv") as execute, \
                patch.object(attach, "scroll_config", return_value=None):
            attach.main(["attach", "term_safe"])
            execute.assert_called_once_with("/usr/bin/herdr", ["/usr/bin/herdr", "terminal", "attach", "term_safe"])
            for target in ("--takeover", "w1:p1", "term_x;touch /tmp/unsafe", ""):
                with self.assertRaises(ValueError):
                    attach.main(["attach", target])
            self.assertEqual(execute.call_count, 1)

    def test_attach_uses_hud_only_one_line_scroll_config(self):
        attach = module("herdr-attach")
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=False):
            os.environ.pop("HERDR_CONFIG_PATH", None)
            home = Path(directory)
            user = home / ".config/herdr/config.toml"
            user.parent.mkdir(parents=True)
            cases = {
                "[keys]\nprefix = \"ctrl+b\"\n\n[ui]\nmouse_capture = true\n": "[ui]\nmouse_scroll_lines = 1\nmouse_capture = true",
                "[ui]\n# mouse_scroll_lines = 3\nmouse_scroll_lines = 5\n": "mouse_scroll_lines = 1",
                "[keys]\nprefix = \"ctrl+b\"\n": "[ui]\nmouse_scroll_lines = 1",
            }
            for original, expected in cases.items():
                user.write_text(original)
                path = attach.scroll_config(home)
                self.assertEqual(path, home / ".config/herdr-hud-native/herdr-attach.toml")
                self.assertIn(expected, path.read_text())
                self.assertNotIn("mouse_scroll_lines = 5", path.read_text())
                self.assertEqual(user.read_text(), original)
            with patch.object(attach.shutil, "which", return_value="/usr/bin/herdr"), \
                    patch.object(attach.os, "execv"), patch.object(attach.Path, "home", return_value=home):
                attach.main(["attach", "term_safe"])
                self.assertEqual(os.environ["HERDR_CONFIG_PATH"], str(home / ".config/herdr-hud-native/herdr-attach.toml"))

    def test_missing_herdr_never_execs_shell(self):
        attach = module("herdr-attach")
        with patch.object(attach.shutil, "which", return_value=None), patch.object(attach.os, "execv") as execute:
            with self.assertRaisesRegex(ValueError, "not installed"):
                attach.main(["attach", "term_safe"])
            execute.assert_not_called()

    def test_monitor_rejects_write_commands(self):
        monitor = module("herdr-monitor")
        for command in ("prompt", "output", "attach", "run"):
            with self.assertRaises(monitor.BridgeError):
                monitor.main(["monitor", command])

    def test_preview_rechecks_identity(self):
        monitor = module("herdr-monitor")
        agent = {"pane_id": "w1:p1", "terminal_id": "term_safe"}
        with patch.object(monitor, "agents", side_effect=[[agent], []]), patch.object(monitor, "herdr", return_value="safe output"):
            with self.assertRaisesRegex(monitor.BridgeError, "changed"):
                monitor.preview("w1:p1", "term_safe")

    def test_notification_preview_rejects_tui_snapshots(self):
        monitor = module("herdr-monitor")
        for text in (
            "pSeek V4.1 Flash · 11.9s\n┃\n│\n~/Projects/omarchy-herdr-hud-native:\n│ Build · DeepSeek V4.1 Flash OpenCode Go ·\nhigh",
            "Build · DeepSeek V4.1 Flash OpenCode Go · high",
            "Finished\nesc to interrupt",
            "\x1b[31mFinished\x1b[0m",
            "Finished\n└──────────",
        ):
            with self.subTest(text=text):
                self.assertEqual(monitor.notification_preview(text), "")

    def test_notification_preview_preserves_plain_text_and_its_end(self):
        monitor = module("herdr-monitor")
        self.assertEqual(monitor.notification_preview("\nИсправлено.\nТесты проходят.\n"), "Исправлено.\nТесты проходят.")
        self.assertEqual(monitor.notification_preview("   "), "")
        text = "Earlier output: " + "result " * 100 + "Latest: tests pass."
        preview = monitor.notification_preview(text)
        self.assertEqual(preview, "…" + text[-599:].lstrip())
        self.assertTrue(preview.endswith("Latest: tests pass."))
        self.assertLessEqual(len(preview), 600)

    def test_notification_preview_preserves_prose_and_unicode(self):
        monitor = module("herdr-monitor")
        for text in (
            "Progress: ███░ 75%",
            "The menu contains Build • and Plan • options.",
            "Press ctrl+c to cancel the command.",
            "ctrl+c to cancel",
            "Use │ to separate columns.",
        ):
            with self.subTest(text=text):
                self.assertEqual(monitor.notification_preview(text), text)

    def test_preview_returns_empty_for_tui_to_keep_hud_fallback(self):
        monitor = module("herdr-monitor")
        agent = {"pane_id": "w1:p1", "terminal_id": "term_safe"}
        output = io.StringIO()
        with patch.object(monitor, "agents", return_value=[agent]), patch.object(monitor, "herdr", return_value="│ Build · DeepSeek"), contextlib.redirect_stdout(output):
            monitor.preview("w1:p1", "term_safe")
        self.assertEqual(json.loads(output.getvalue()), {"preview": ""})

    def test_claude_preview_reads_transcript_not_pane(self):
        monitor = module("herdr-monitor")
        first, second = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
        agent = {"pane_id": "w1:p1", "terminal_id": "term_safe", "agent": "claude",
                 "agent_session": {"value": first}}
        entries = [
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "Older reply"}]}},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "Fixed the **build**."},
                                                          {"type": "tool_use", "name": "Bash"}]}},
            {"type": "assistant", "isSidechain": True, "message": {"content": [{"type": "text", "text": "subagent"}]}},
        ]
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": directory}):
            project = Path(directory) / "projects" / "-repo"
            project.mkdir(parents=True)
            (project / f"{first}.jsonl").write_text(json.dumps({"type": "continued-in", "continuedInSessionId": second}) + "\n")
            (project / f"{second}.jsonl").write_text("\n".join(json.dumps(e) for e in entries) + "\n")
            with patch.object(monitor, "agents", return_value=[agent]), \
                    patch.object(monitor, "herdr") as herdr, contextlib.redirect_stdout(output):
                monitor.preview("w1:p1", "term_safe")
            herdr.assert_not_called()
            self.assertIsNone(monitor.claude_transcript("../../etc/passwd"))
        self.assertEqual(json.loads(output.getvalue()), {"preview": "Fixed the build."})

    def test_hermes_and_opencode_previews_read_session_stores(self):
        import sqlite3
        monitor = module("herdr-monitor")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hermes = root / "hermes"
            hermes.mkdir()
            db = sqlite3.connect(hermes / "state.db")
            db.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT)")
            db.executemany("INSERT INTO messages (session_id, role, content) VALUES (?, ?, ?)", [
                ("20261005_225026_cdc9cb", "assistant", "Older reply"),
                ("20261005_225026_cdc9cb", "assistant", "Theme applied."),
                ("20261005_225026_cdc9cb", "tool", "tool output"),
                ("20261005_225026_cdc9cb", "assistant", ""),
                ("20261005_000000_ffffff", "assistant", "Other session"),
            ])
            db.commit(); db.close()
            data = root / "data"
            (data / "opencode").mkdir(parents=True)
            db = sqlite3.connect(data / "opencode" / "opencode.db")
            db.execute("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)")
            db.execute("CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, data TEXT)")
            db.executemany("INSERT INTO message VALUES (?, ?, ?, ?)", [
                ("msg_1", "ses_abc", 1, json.dumps({"role": "assistant"})),
                ("msg_2", "ses_abc", 2, json.dumps({"role": "assistant"})),
                ("msg_3", "ses_abc", 3, json.dumps({"role": "user"})),
            ])
            db.executemany("INSERT INTO part VALUES (?, ?, ?)", [
                ("prt_1", "msg_1", json.dumps({"type": "text", "text": "Old"})),
                ("prt_2", "msg_2", json.dumps({"type": "reasoning", "text": "secret"})),
                ("prt_3", "msg_2", json.dumps({"type": "text", "text": "Fixed it."})),
                ("prt_4", "msg_2", json.dumps({"type": "text", "text": "hidden", "synthetic": True})),
            ])
            db.commit(); db.close()
            with patch.dict(os.environ, {"HERMES_HOME": str(hermes), "XDG_DATA_HOME": str(data)}):
                self.assertEqual(monitor.hermes_last_reply("20261005_225026_cdc9cb"), "Theme applied.")
                self.assertEqual(monitor.opencode_last_reply("ses_abc"), "Fixed it.")
                self.assertEqual(monitor.hermes_last_reply("../../etc"), "")
                self.assertEqual(monitor.opencode_last_reply("ses_x' OR 1=1--"), "")
                agent = {"pane_id": "w1:p1", "terminal_id": "term_safe", "agent": "opencode",
                         "agent_session": {"value": "ses_abc"}}
                output = io.StringIO()
                with patch.object(monitor, "agents", return_value=[agent]), \
                        patch.object(monitor, "herdr") as herdr, contextlib.redirect_stdout(output):
                    monitor.preview("w1:p1", "term_safe")
                herdr.assert_not_called()
                self.assertEqual(json.loads(output.getvalue()), {"preview": "Fixed it."})
            with patch.dict(os.environ, {"HERMES_HOME": str(root / "missing"), "XDG_DATA_HOME": str(root / "missing")}):
                self.assertEqual(monitor.hermes_last_reply("20261005_225026_cdc9cb"), "")
                self.assertEqual(monitor.opencode_last_reply("ses_abc"), "")

    def test_read_only_roster(self):
        monitor = module("herdr-monitor")
        payloads = [{"result": {"agents": [{"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "t1"}]}},
                    {"result": {"workspaces": [{"workspace_id": "w1", "label": "Work"}]}},
                    {"result": {"tabs": [{"tab_id": "t1", "label": "Agent"}]}}]
        output = io.StringIO()
        with patch.object(monitor, "herdr", side_effect=map(json.dumps, payloads)), contextlib.redirect_stdout(output):
            monitor.roster()
        agent = json.loads(output.getvalue())["agents"][0]
        self.assertEqual((agent["workspace_label"], agent["tab_label"]), ("Work", "Agent"))

    def test_bounded_process(self):
        monitor = module("herdr-monitor")
        with self.assertRaisesRegex(monitor.BridgeError, "did not respond"):
            monitor.run([sys.executable, "-c", "import time; time.sleep(5)"], timeout=0.1)
        with patch.object(monitor, "STDOUT_LIMIT", 1024), self.assertRaisesRegex(monitor.BridgeError, "byte limit"):
            monitor.run([sys.executable, "-c", "print('x'*2048)"])

    def test_hud_has_no_reconstructed_chat_or_keyboard_interceptor(self):
        source = (NATIVE / "HerdrHud.qml").read_text()
        for removed in ("renderConversation", "submitPrompt", "outputProc", "promptArea", "Keys.onPressed", "scrollOutputToBottom"):
            self.assertNotIn(removed, source)
        self.assertEqual(source.count("  TerminalPane {"), 1)
        self.assertIn("WowFrame {", source)
        self.assertIn("WowLauncher {", source)
        self.assertIn("root.queueAlert(agent)", source)
        self.assertNotIn("QMLTermWidget", source)

    def test_roster_keeps_herdr_order(self):
        # Re-sorting by attention moved agents under the cursor on selection.
        source = (NATIVE / "HerdrHud.qml").read_text()
        self.assertIn("readonly property var sortedAgents: agents\n", source)
        self.assertNotIn("Roster.sorted(", source)

    def test_release_structure(self):
        for name in ("Roster.js", "Alerts.js", "WowFrame.qml", "WowLauncher.qml", "LICENSE"):
            self.assertTrue((NATIVE / name).exists(), name)
        manifest = json.loads((ROOT / "manifest.json").read_text())
        self.assertEqual(manifest["id"], "indie.herdr-hud")
        self.assertEqual(manifest["version"], "0.1.0")
        self.assertTrue((ROOT / manifest["entryPoints"]["panel"]).is_file())
        source = (ROOT / "HerdrHud.qml").read_text()
        self.assertNotIn("legacyStateFile", source)
        self.assertNotIn("/.config/herdr-hud/state.json", source)
        for path in ("native", "poc", "bin/stage-native", "bin/herdr-hud", "index.html"):
            self.assertFalse((ROOT / path).exists(), path)

    def test_missing_dependency_keeps_monitor_loadable(self):
        source = (NATIVE / "TerminalPane.qml").read_text()
        self.assertNotIn("import QMLTermWidget", source)
        self.assertIn('terminalLoader.setSource("NativeTerminal.qml"', source)
        self.assertIn("Loader.Error", source)
        self.assertNotIn("sendText", source)

    def test_native_client_uses_signal_not_escape_prefix_to_close(self):
        source = (NATIVE / "NativeTerminal.qml").read_text()
        self.assertIn("session.sendSignal(15)", source)
        self.assertIn("session.sendSignal(9)", source)
        self.assertNotIn("sendText", source)
        self.assertIn('shellProgram: "/usr/bin/env"', source)
        self.assertIn('"python3"', source)

    def test_terminal_copies_on_selection_release(self):
        source = (NATIVE / "NativeTerminal.qml").read_text()
        self.assertIn("onIsBusySelecting: busy =>", source)
        self.assertIn("if (!busy) Qt.callLater(root.copyAndClearSelection)", source)
        pane = (NATIVE / "TerminalPane.qml").read_text()
        self.assertIn("Shift+drag to select & copy", pane)
        self.assertNotIn("function copySelection()", pane)
        self.assertIn("function toggleConnection()", pane)
        hud = (NATIVE / "HerdrHud.qml").read_text()
        self.assertNotIn('text: "Copy"', hud)
        self.assertIn('text: terminalPane.clientRunning ? "Disconnect" : "Reconnect"', hud)

    @unittest.skipUnless(shutil.which("quickshell") and SHELL.exists(), "Omarchy is required")
    def test_qml_compilation(self):
        with tempfile.TemporaryDirectory(prefix="herdr-native-qml-") as directory:
            temp = Path(directory)
            (temp / "Commons").symlink_to(SHELL / "Commons")
            (temp / "Ui").symlink_to(SHELL / "Ui")
            shutil.copytree(NATIVE, temp / "native")
            (temp / "shell.qml").write_text('''import QtQuick
import Quickshell
Scope {
  Timer {
    interval: 100; running: true
    onTriggered: {
      var names = ["NativeTerminal.qml", "TerminalPane.qml", "HerdrHud.qml"]
      for (var index = 0; index < names.length; index++) {
        var component = Qt.createComponent("native/" + names[index])
        if (component.status !== Component.Ready && !component.errorString().includes("No PanelWindow backend loaded")) {
          console.error("NATIVE_FAIL", component.errorString()); Qt.quit(); return
        }
        if (names[index] === "NativeTerminal.qml" && component.status === Component.Ready) {
          var terminal = component.createObject(null, {terminalTarget: "term_test"})
          if (!terminal) { console.error("NATIVE_FAIL", component.errorString()); Qt.quit(); return }
          try {
            terminal.copyAndClearSelection()
            terminal.clearSelection()
            if (terminal.clearingSelection || terminal.selecting) throw new Error("Selection reset remained active")
          } catch (error) {
            console.error("NATIVE_FAIL", error); Qt.quit(); return
          }
          terminal.destroy()
        }
      }
      console.log("NATIVE_COMPILE_PASS")
      Qt.quit()
    }
  }
}
''')
            env = dict(os.environ, HOME=directory, XDG_RUNTIME_DIR=directory, QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software", QT_QPA_PLATFORMTHEME="", DISPLAY="")
            env.pop("WAYLAND_DISPLAY", None)
            result = subprocess.run(["quickshell", "--no-color", "-p", str(temp / "shell.qml")], env=env, capture_output=True, text=True, timeout=15)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn("NATIVE_COMPILE_PASS", output)
            self.assertNotIn("NATIVE_FAIL", output)

if __name__ == "__main__":
    unittest.main()
