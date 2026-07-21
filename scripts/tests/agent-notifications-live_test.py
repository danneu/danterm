#!/usr/bin/env python3
"""Offline behavioral self-test for the live agent notification harness."""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import os
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "agent-notifications-live.py"
SPEC = importlib.util.spec_from_file_location("agent_notifications_live", SCRIPT)
assert SPEC and SPEC.loader
live = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = live
SPEC.loader.exec_module(live)


class HarnessTests(unittest.TestCase):
    def test_exact_osc_parsing_rejects_embedded_or_unterminated_sequences(self):
        data = b"noise\x1b]9;ok\x07tail\x1b]9;unterminated"
        self.assertEqual(live.terminal_sequences(data, "codex"), [b"\x1b]9;ok\x07"])

    def test_duplicate_detection_is_possible_from_real_pty_capture(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            output, _ = live.drive_pty(
                [str(SCRIPT), "--fake-child", "claude", "--fake-mode", "duplicate"],
                os.environ.copy(), root, root / "pty.raw",
                lambda data: len(live.terminal_sequences(data, "claude")) >= 2, 2)
            # The fake child emits notifications only after reading our cursor
            # position response, so reaching this assertion proves query handling.
            self.assertEqual(len(live.terminal_sequences(output, "claude")), 2)

    def test_timeout_preserves_capture(self):
        with tempfile.TemporaryDirectory() as raw:
            capture = Path(raw) / "pty.raw"
            with self.assertRaises(TimeoutError):
                live.drive_pty([str(SCRIPT), "--fake-child", "codex", "--fake-mode", "timeout"],
                               os.environ.copy(), Path(raw), capture, lambda _: False, 0.2)
            self.assertTrue(capture.exists())

    def test_hook_synchronization_uses_stable_fields_and_sanitizes_paths(self):
        with tempfile.TemporaryDirectory() as raw:
            log = Path(raw) / "events.jsonl"
            scenario = live.Scenario("fixture", "", "PermissionRequest", True, True)
            live.drive_pty(
                [str(SCRIPT), "--fake-child", "codex", "--fake-log", str(log)],
                os.environ.copy(), Path(raw), Path(raw) / "pty.raw",
                lambda _: bool(live.sanitized_json_lines(log)), 2)
            self.assertTrue(live.event_matches(live.sanitized_json_lines(log)[0], scenario))
            self.assertNotIn("cwd", live.sanitized_json_lines(log)[0])

    def test_auth_symlink_cleanup_does_not_remove_auth_target(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            target = root / "real-auth.json"
            target.write_text("{}")
            link = root / "auth.json"
            link.symlink_to(target)
            output, _ = live.drive_pty(
                [str(SCRIPT), "--fake-child", "codex", "--fake-auth", str(link)],
                os.environ.copy(), root, root / "pty.raw",
                lambda data: bool(live.terminal_sequences(data, "codex")), 2)
            self.assertTrue(live.terminal_sequences(output, "codex"))
            self.assertFalse(link.exists())
            self.assertTrue(target.exists())

    def test_codex_config_is_isolated_private_and_registers_test_agent(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "source"
            source.mkdir()
            (source / "auth.json").write_text("{}")
            (source / "config.toml").write_text('model = "configured-model"\n')
            fixture = root / "fixture"
            fixture.mkdir()
            (fixture / "workspace").mkdir()
            with mock.patch.dict(os.environ, {"CODEX_HOME": str(source)}, clear=False):
                _, argv, link = live.configure_codex(fixture, SCRIPT)
            try:
                with open(fixture / "codex-home/config.toml", "rb") as stream:
                    config = tomllib.load(stream)
                self.assertEqual(config["agents"]["live-worker"]["description"],
                                 "Restricted live notification fixture worker")
                self.assertEqual(config["tui"]["notification_method"], "osc9")
                self.assertEqual(argv[-2:], ["--model", "configured-model"])
                self.assertEqual((fixture / "codex-home").stat().st_mode & 0o777, 0o700)
                self.assertEqual((fixture / "codex-home/config.toml").stat().st_mode & 0o777, 0o600)
            finally:
                link.unlink(missing_ok=True)

    def test_contract_failure_retains_artifacts_and_prints_location(self):
        with tempfile.TemporaryDirectory() as raw:
            parent = Path(raw)

            def fail_with_capture(_kind, scenario, suite_root, _script, _repo):
                case = suite_root / scenario.name
                case.mkdir()
                (case / "pty.raw").write_bytes(b"fixture")
                raise live.ContractFailure("fixture failure")

            stderr = io.StringIO()
            stdout = io.StringIO()
            scenario = live.Scenario("failure-case", "", "Stop")
            with (mock.patch.dict(os.environ, {"DANTERM_AGENT_NOTIFICATION_ARTIFACTS": raw}, clear=False),
                  mock.patch.object(live, "SCENARIOS", (scenario,)),
                  mock.patch.object(live.shutil, "which", return_value="/bin/true"),
                  mock.patch.object(live, "version", return_value="fake 1.0"),
                  mock.patch.object(live, "run_scenario", side_effect=fail_with_capture),
                  redirect_stderr(stderr), redirect_stdout(stdout)):
                self.assertEqual(live.run_live("codex"), 1)
            artifacts = list(parent.glob("danterm-agent-notifications-*"))
            self.assertEqual(len(artifacts), 1)
            self.assertTrue((artifacts[0] / "failure-case/pty.raw").exists())
            self.assertIn(str(artifacts[0]), stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
