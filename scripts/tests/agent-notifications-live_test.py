#!/usr/bin/env python3
"""Offline behavioral self-test for the live agent notification harness."""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
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

    def test_screen_normalization_exposes_ansi_positioned_startup_errors(self):
        data = b"\x1b[2GNot\x1b[6Glogged\x1b[13Gin\r\n"
        self.assertIn(b"notloggedin", live.normalized_screen(data))

    def test_deprecated_model_migration_dialog_is_a_setup_failure(self):
        scenario = live.Scenario("root-completes", "", "Stop")
        data = b"\x1b[2GGPT-5.4 Mini will be deprecated soon"
        self.assertTrue(live.scenario_is_ready(
            "codex", scenario, Path("/nonexistent"), data, live.ReadinessState(),
            now=0, notification_grace=5))

    def test_running_background_task_distinguishes_parent_parking_from_completion(self):
        parked = {"hook_event_name": "Stop", "background_tasks": [
            {"type": "subagent", "status": "running"}
        ]}
        completed = {"hook_event_name": "Stop", "background_tasks": [
            {"type": "subagent", "status": "completed"}
        ]}
        self.assertTrue(live.has_active_background_task(parked))
        self.assertFalse(live.has_active_background_task(completed))

    def test_subagent_identity_can_precede_an_unidentified_elicitation(self):
        scenario = live.Scenario("subagent-elicitation", "", "Elicitation", True, True,
                                 "DANTERM_LIVE_ELICITATION")
        events = [
            {"hook_event_name": "PreToolUse", "agent_id": "worker-1",
             "tool_name": "mcp__fixture__live_notification_fixture"},
            {"hook_event_name": "Elicitation", "message": "DANTERM_LIVE_ELICITATION"},
        ]
        self.assertTrue(live.has_identified_subagent_elicitation(events, scenario))
        self.assertFalse(live.has_identified_subagent_elicitation(events[1:], scenario))

    def test_codex_elicitation_requires_the_fixture_call_and_its_dialog(self):
        scenario = live.Scenario("root-elicitation", "", "Elicitation", True,
                                 marker="DANTERM_LIVE_ELICITATION")
        call = {"hook_event_name": "PreToolUse",
                "tool_name": "mcp__fixture__live_notification_fixture"}
        dialog = {"hook_event_name": "PermissionRequest",
                  "tool_name": "mcp__fixture__live_notification_fixture"}
        self.assertFalse(live.has_required_upstream("codex", [call], scenario))
        self.assertTrue(live.has_required_upstream("codex", [call, dialog], scenario))

    def test_upstream_evidence_without_notification_fails_after_grace_period(self):
        with tempfile.TemporaryDirectory() as raw:
            log = Path(raw) / "events.jsonl"
            log.write_text(json.dumps({
                "hook_event_name": "PermissionRequest",
                "agent_id": "worker-1",
                "tool_name": "Bash",
            }) + "\n")
            scenario = live.Scenario("subagent-approval", "", "PermissionRequest",
                                     True, True)
            state = live.ReadinessState()
            self.assertFalse(live.scenario_is_ready(
                "codex", scenario, log, b"", state, now=10.0, notification_grace=2.0))
            with self.assertRaisesRegex(live.ContractFailure,
                                       "notification missing 2s after PermissionRequest"):
                live.scenario_is_ready(
                    "codex", scenario, log, b"", state, now=12.1,
                    notification_grace=2.0)

    def test_terminal_root_stop_before_subagent_evidence_is_detected(self):
        scenario = live.Scenario("subagent-completes", "", "SubagentStop", subagent=True)
        terminal = [{"hook_event_name": "Stop", "background_tasks": []}]
        parked = [{"hook_event_name": "Stop", "background_tasks": [
            {"type": "subagent", "status": "running"}
        ]}]
        parked_by_lifecycle = [
            {"hook_event_name": "SubagentStart", "agent_id": "worker-1"},
            {"hook_event_name": "Stop", "background_tasks": []},
        ]
        completed = [
            {"hook_event_name": "SubagentStart", "agent_id": "worker-1"},
            {"hook_event_name": "SubagentStop", "agent_id": "worker-1"},
            {"hook_event_name": "Stop", "background_tasks": []},
        ]
        self.assertTrue(live.terminal_root_stop_before_upstream("claude", terminal, scenario))
        self.assertFalse(live.terminal_root_stop_before_upstream("claude", parked, scenario))
        self.assertFalse(live.terminal_root_stop_before_upstream(
            "claude", parked_by_lifecycle, scenario))
        self.assertFalse(live.terminal_root_stop_before_upstream("claude", completed, scenario))

    def test_claude_scenarios_restrict_the_root_to_the_required_tool(self):
        expected = {
            "root-completes": [],
            "root-question": ["--tools=AskUserQuestion"],
            "root-approval": ["--tools=Bash"],
            "root-elicitation": [],
            "subagent-completes": ["--tools=Agent"],
            "subagent-approval": ["--tools=Agent,Bash"],
            "subagent-elicitation": [
                "--tools=Agent,mcp__live-notification-fixture__live_notification_fixture"
            ],
            "background-parking": ["--tools=Agent,Bash"],
        }
        self.assertEqual({scenario.name: live.claude_scenario_tool_args(scenario)
                          for scenario in live.SCENARIOS}, expected)

    def test_claude_workers_expose_only_the_scenario_tool(self):
        expected = {
            "subagent-completes": [],
            "subagent-approval": ["Bash"],
            "subagent-elicitation": [
                "mcp__live-notification-fixture__live_notification_fixture"
            ],
            "background-parking": ["Bash"],
        }
        scenarios = [scenario for scenario in live.SCENARIOS if scenario.name in expected]
        self.assertEqual({scenario.name: live.claude_worker_tools(scenario)
                          for scenario in scenarios}, expected)

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

    def test_child_cleanup_falls_back_when_process_group_signal_is_denied(self):
        with (mock.patch.object(live.os, "killpg", side_effect=PermissionError),
              mock.patch.object(live.os, "kill") as kill):
            live.signal_child(123, live.signal.SIGTERM)
        kill.assert_called_once_with(123, live.signal.SIGTERM)

    def test_owned_workspace_trust_prompt_is_confirmed(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            output, _ = live.drive_pty(
                [str(SCRIPT), "--fake-child", "claude", "--fake-mode", "trust"],
                os.environ.copy(), root, root / "pty.raw",
                lambda data: bool(live.terminal_sequences(data, "claude")), 2)
            self.assertEqual(len(live.terminal_sequences(output, "claude")), 1)

    def test_codex_workspace_trust_prompt_is_confirmed(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            output, _ = live.drive_pty(
                [str(SCRIPT), "--fake-child", "codex", "--fake-mode", "trust"],
                os.environ.copy(), root, root / "pty.raw",
                lambda data: bool(live.terminal_sequences(data, "codex")), 2)
            self.assertEqual(len(live.terminal_sequences(output, "codex")), 1)

    def test_child_pty_has_usable_terminal_geometry(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            output, status = live.drive_pty(
                [str(SCRIPT), "--fake-child", "codex", "--fake-mode", "geometry"],
                os.environ.copy(), root, root / "pty.raw",
                lambda data: bool(live.terminal_sequences(data, "codex")), 2)
            self.assertIn(status, (None, 0))
            self.assertEqual(len(live.terminal_sequences(output, "codex")), 1)

    def test_hook_synchronization_uses_stable_fields_and_sanitizes_paths(self):
        with tempfile.TemporaryDirectory() as raw:
            log = Path(raw) / "events.jsonl"
            scenario = live.Scenario("fixture", "", "PermissionRequest", True, True)
            live.drive_pty(
                [str(SCRIPT), "--fake-child", "codex", "--fake-mode", "sync",
                 "--fake-log", str(log)],
                os.environ.copy(), Path(raw), Path(raw) / "pty.raw",
                lambda data: (bool(live.sanitized_json_lines(log))
                              and bool(live.terminal_sequences(data, "codex"))), 2)
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
                self.assertFalse(config["features"]["plugins"])
                self.assertFalse(config["features"]["remote_plugin"])
                self.assertTrue(config["features"]["default_mode_request_user_input"])
                with open(fixture / "codex-home/agents/live-worker.toml", "rb") as stream:
                    agent = tomllib.load(stream)
                self.assertEqual(agent["name"], "live-worker")
                self.assertEqual(argv[-2:], ["--model", "configured-model"])
                self.assertEqual((fixture / "codex-home").stat().st_mode & 0o777, 0o700)
                self.assertEqual((fixture / "codex-home/config.toml").stat().st_mode & 0o777, 0o600)
            finally:
                link.unlink(missing_ok=True)

    def test_codex_elicitation_config_preapproves_the_fixture_tool(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "source"
            source.mkdir()
            (source / "auth.json").write_text("{}")
            fixture = root / "fixture"
            fixture.mkdir()
            (fixture / "workspace").mkdir()
            scenario = live.Scenario("root-elicitation", "", "Elicitation", True)
            with mock.patch.dict(os.environ, {"CODEX_HOME": str(source)}, clear=False):
                _, _, link = live.configure_codex(fixture, SCRIPT, scenario)
            try:
                with open(fixture / "codex-home/config.toml", "rb") as stream:
                    config = tomllib.load(stream)
                self.assertEqual(config["approval_policy"], "never")
            finally:
                link.unlink(missing_ok=True)

    def test_claude_config_preapproves_only_the_elicitation_fixture_tool(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "workspace").mkdir()
            live.configure_claude(root, SCRIPT, SCRIPT.parent.parent)
            settings = json.loads((root / "claude-settings.json").read_text())
            self.assertEqual(settings["permissions"]["allow"], [
                "mcp__live-notification-fixture__live_notification_fixture",
                "Bash(sleep:*)",
            ])
            _, argv = live.configure_claude(root, SCRIPT, SCRIPT.parent.parent)
            agents = json.loads(argv[argv.index("--agents") + 1])
            self.assertIn("CLI permission UI", agents["live-worker"]["prompt"])

    def test_contract_failure_retains_artifacts_and_prints_location(self):
        with tempfile.TemporaryDirectory() as raw:
            parent = Path(raw)

            def fail_with_capture(_kind, scenario, suite_root, _script, _repo):
                case = suite_root / scenario.name
                case.mkdir()
                (case / "pty.raw").write_bytes(b"fixture")
                private = case / "codex-home"
                private.mkdir()
                (private / "history.jsonl").write_text("sensitive transcript")
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
            self.assertFalse((artifacts[0] / "failure-case/codex-home").exists())
            self.assertIn(str(artifacts[0]), stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
