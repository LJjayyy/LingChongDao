#!/usr/bin/env python3
"""Offline contract checks. Uses synthetic HOME/socket/helper; no Codex install."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent
PLUGIN = ROOT / "plugins/lingchongdao-codex"
SCRIPT = PLUGIN / "scripts/forward-hook.sh"
EVENTS = {
    "SessionStart": "同步会话开始", "UserPromptSubmit": "同步新任务",
    "PreToolUse": "同步工具开始", "PostToolUse": "同步工具结果",
    "PermissionRequest": "处理权限请求", "Stop": "同步本轮结束",
    "SessionEnd": "同步会话结束", "SubagentStart": "同步子任务开始",
    "SubagentStop": "同步子任务结束", "Interrupt": "同步任务中断",
}

class PluginContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="lcdp-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.home = self.base / "家 '"
        self.support = self.home / "Library/Application Support/LingChongDao"
        self.socket_path = self.support / "run/bridge.sock"
        self.socket_path.parent.mkdir(parents=True)
        self.installed_plugin = self.base / "plugin folder"
        shutil.copytree(PLUGIN, self.installed_plugin)
        self.helper = self.installed_plugin / "bin/lingchongdao-hook"
        self.helper.parent.mkdir(parents=True, exist_ok=True)
        self.helper.unlink(missing_ok=True)  # Tests never execute a copied real binary.
        self.env = dict(os.environ, HOME=str(self.home), PLUGIN_ROOT=str(self.installed_plugin),
                        LCD_TEST_RECORD=str(self.base / "called"), LCD_TEST_INPUT=str(self.base / "input"))
        for variable in ("LCD_TEST_FAIL", "LCD_TEST_RESPONSE"):
            self.env.pop(variable, None)
        self.payload = b'{"session_id":"synthetic","hook_event_name":"Stop"}\n'

    def install_fake_runtime(self):
        self.helper.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$LCD_TEST_RECORD"\n'
                               'cat > "$LCD_TEST_INPUT"\n'
                               'if [ -n "${LCD_TEST_RESPONSE:-}" ]; then\n'
                               '  printf "%s\\n" "$LCD_TEST_RESPONSE"\n'
                               'else printf "{}\\n"; fi\n'
                               'exit "${LCD_TEST_FAIL:-0}"\n')
        self.helper.chmod(0o700)
        self.bind_socket(self.socket_path)

    def bind_socket(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        local_socket = socket.socket(socket.AF_UNIX)
        local_socket.bind(str(path))
        self.addCleanup(local_socket.close)

    def run_hook(self, *arguments):
        started = time.monotonic()
        result = subprocess.run(["/bin/sh", str(SCRIPT), *arguments], env=self.env,
                                input=self.payload, capture_output=True, timeout=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(time.monotonic() - started, 2)
        return result.stdout

    def test_manifest_marketplace_and_names(self):
        manifest = json.loads((PLUGIN / ".codex-plugin/plugin.json").read_text())
        marketplace = json.loads((ROOT / ".agents/plugins/marketplace.json").read_text())
        entry = marketplace["plugins"][0]
        self.assertEqual((ROOT / entry["source"]["path"]).resolve(), PLUGIN.resolve())
        self.assertEqual(entry["name"], manifest["name"])
        self.assertEqual(manifest["version"], "0.1.6")
        interface = manifest["interface"]
        for key in ("logo", "logoDark"):
            logo = (PLUGIN / interface[key]).resolve()
            self.assertTrue(logo.is_file(), f"{key} must point at a packaged image")
            self.assertIn(str(PLUGIN.resolve()), str(logo))
        self.assertRegex(interface["brandColor"], r"^#[0-9A-Fa-f]{6}$")
        self.assertEqual(entry["policy"]["installation"], "AVAILABLE")
        hooks = json.loads((PLUGIN / manifest["hooks"]).read_text())["hooks"]
        self.assertEqual(set(hooks), set(EVENTS))
        for event, title in EVENTS.items():
            handler = hooks[event][0]["hooks"][0]
            self.assertEqual(handler["statusMessage"], "灵宠岛 · " + title)
            self.assertNotIn("async", handler)  # Approval and lifecycle order must be preserved.
            self.assertIn('"${PLUGIN_ROOT}/scripts/forward-hook.sh"', handler["command"])
            self.assertNotIn("/Users/", handler["command"])
            self.assertEqual(handler["timeout"], 60 if event == "PermissionRequest" else 3)
        self.assertNotIn("mcpServers", manifest)

    def test_missing_helper_does_not_make_a_decision(self):
        self.assertEqual(self.run_hook("--approval"), b'{}\n')
        self.assertFalse((self.base / "called").exists())

    def test_missing_socket_does_not_run_helper(self):
        self.install_fake_runtime()
        self.socket_path.unlink()
        self.assertEqual(self.run_hook("--approval"), b'{}\n')
        self.assertFalse((self.base / "called").exists())

    def test_non_socket_path_does_not_run_helper(self):
        self.install_fake_runtime()
        self.socket_path.unlink()
        self.socket_path.write_text("not a socket")
        self.assertEqual(self.run_hook("--approval"), b'{}\n')
        self.assertFalse((self.base / "called").exists())

    def test_event_input_and_helper_arguments_are_preserved(self):
        self.install_fake_runtime()
        self.assertEqual(self.run_hook(), b'{}\n')
        self.assertEqual((self.base / "input").read_bytes(), self.payload)
        self.assertEqual((self.base / "called").read_text().splitlines(),
                         ["--provider", "codex", "--socket", str(self.socket_path), "--timeout", "2"])

    def test_only_native_helper_returns_approval(self):
        self.install_fake_runtime()
        response = '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}'
        self.env["LCD_TEST_RESPONSE"] = response
        self.assertEqual(self.run_hook("--approval"), (response + "\n").encode())
        self.assertEqual((self.base / "called").read_text().splitlines()[-1], "45")

    def test_helper_failure_discards_partial_output(self):
        self.install_fake_runtime()
        self.env["LCD_TEST_FAIL"] = "7"
        self.env["LCD_TEST_RESPONSE"] = '{"hookSpecificOutput":{"decision":{"behavior":"allow"}}}'
        self.assertEqual(self.run_hook("--approval"), b'{}\n')

    def test_plugin_path_with_spaces_is_quoted(self):
        self.install_fake_runtime()
        hooks = json.loads((self.installed_plugin / "hooks/hooks.json").read_text())["hooks"]
        command = hooks["Stop"][0]["hooks"][0]["command"]
        result = subprocess.run(["/bin/sh", "-c", command], env=self.env,
                                input=self.payload, capture_output=True, timeout=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b'{}\n')
        self.assertEqual((self.base / "input").read_bytes(), self.payload)

    def test_unknown_arguments_fail_open_without_running_helper(self):
        self.install_fake_runtime()
        self.assertEqual(self.run_hook("--unrecognized"), b'{}\n')
        self.assertEqual(self.run_hook("--approval", "extra"), b'{}\n')
        self.assertFalse((self.base / "called").exists())

    def test_missing_plugin_root_does_not_use_a_global_helper(self):
        self.install_fake_runtime()
        self.env.pop("PLUGIN_ROOT")
        self.assertEqual(self.run_hook("--approval"), b'{}\n')
        self.assertFalse((self.base / "called").exists())

    def test_no_config_read_or_edit_needed(self):
        self.install_fake_runtime()
        codex = self.home / ".codex"
        codex.mkdir()
        config = codex / "hooks.json"
        config.write_text("unparseable unrelated user config")
        config.chmod(0)
        self.addCleanup(lambda: config.chmod(0o600))
        self.assertEqual(self.run_hook(), b'{}\n')
        self.assertTrue((self.base / "called").exists())


    def test_legacy_socket_is_used_only_when_current_socket_is_absent(self):
        self.install_fake_runtime()
        self.socket_path.unlink()
        legacy = self.home / "Library/Application Support/AIIsland/run/bridge.sock"
        self.bind_socket(legacy)
        self.assertEqual(self.run_hook(), b'{}\n')
        self.assertEqual((self.base / "called").read_text().splitlines()[3], str(legacy))

    def test_current_socket_wins_when_both_clients_are_present(self):
        self.install_fake_runtime()
        legacy = self.home / "Library/Application Support/AIIsland/run/bridge.sock"
        self.bind_socket(legacy)
        self.assertEqual(self.run_hook(), b'{}\n')
        self.assertEqual((self.base / "called").read_text().splitlines()[3], str(self.socket_path))

    def test_non_socket_current_path_never_selects_legacy_client(self):
        self.install_fake_runtime()
        self.socket_path.unlink()
        self.socket_path.write_text("not a socket")
        legacy = self.home / "Library/Application Support/AIIsland/run/bridge.sock"
        self.bind_socket(legacy)
        self.assertEqual(self.run_hook("--approval"), b'{}\n')
        self.assertFalse((self.base / "called").exists())

    def test_broken_symlink_current_path_never_selects_legacy_client(self):
        self.install_fake_runtime()
        self.socket_path.unlink()
        self.socket_path.symlink_to(self.base / "missing-target")
        legacy = self.home / "Library/Application Support/AIIsland/run/bridge.sock"
        self.bind_socket(legacy)
        self.assertEqual(self.run_hook("--approval"), b'{}\n')
        self.assertFalse((self.base / "called").exists())

    def test_old_global_helper_is_never_executed(self):
        self.install_fake_runtime()
        self.helper.unlink()
        legacy_helper = self.home / "Library/Application Support/AIIsland/bin/ai-island-hook"
        legacy_helper.parent.mkdir(parents=True, exist_ok=True)
        legacy_helper.write_text('#!/bin/sh\nprintf "called" > "$LCD_TEST_RECORD"\n')
        legacy_helper.chmod(0o700)
        legacy = self.home / "Library/Application Support/AIIsland/run/bridge.sock"
        self.bind_socket(legacy)
        self.assertEqual(self.run_hook("--approval"), b'{}\n')
        self.assertFalse((self.base / "called").exists())

    def test_canonical_helper_and_socket_names_are_current(self):
        script = SCRIPT.read_text()
        self.assertIn('helper="$PLUGIN_ROOT/bin/lingchongdao-hook"', script)
        self.assertIn('socket="$HOME/Library/Application Support/LingChongDao/run/bridge.sock"', script)
        self.assertNotIn('bin/ai-island-hook', script)

if __name__ == "__main__":
    unittest.main(verbosity=2)
