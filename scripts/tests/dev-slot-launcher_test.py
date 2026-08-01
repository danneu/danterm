#!/usr/bin/env python3
"""Behavioral contract tests for isolated development-slot launching."""

import importlib.util
import os
from pathlib import Path
import plistlib
import signal
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
LAUNCHER_PATH = ROOT / "scripts" / "dev-slot-launcher.py"
SPEC = importlib.util.spec_from_file_location("dev_slot_launcher", LAUNCHER_PATH)
assert SPEC is not None and SPEC.loader is not None
launcher = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = launcher
SPEC.loader.exec_module(launcher)


class DevelopmentSlotLauncherTests(unittest.TestCase):
    @staticmethod
    def identity(slot: int) -> dict[str, object]:
        bundle_id = f"com.danneu.danterm-dev.{slot}"
        name = f"DanTerm Dev ({slot})"
        return {
            "slot": slot,
            "bundleId": bundle_id,
            "displayName": name,
            "executableName": name,
            "socketPath": f"/Users/test/Library/Caches/{bundle_id}/control.sock",
        }

    def test_concurrent_claims_use_distinct_nonzero_slots(self) -> None:
        # Intent: overlapping launcher processes can never select slot zero or the same slot.
        # Why it exists: a worktree-local or non-locking claim recreates the identity collision.
        # Scenario: two agents in separate checkouts launch development instances concurrently.
        with tempfile.TemporaryDirectory() as directory:
            first = launcher.claim_development_slot(Path(directory), range(1, 3))
            second = launcher.claim_development_slot(Path(directory), range(1, 3))
            self.addCleanup(first.close)
            self.addCleanup(second.close)

            self.assertEqual((first.slot, second.slot), (1, 2))

    def test_exhaustion_has_distinct_status_without_starting_process(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            held = launcher.claim_development_slot(Path(directory), range(1, 2))
            self.addCleanup(held.close)

            with self.assertRaises(launcher.PoolExhaustedError) as raised:
                launcher.claim_development_slot(Path(directory), range(1, 2))

            self.assertEqual(raised.exception.exit_status, 75)

    def test_build_lock_prevents_overlap_in_one_checkout(self) -> None:
        # Intent: launchers sharing one checkout cannot overlap canonical bundle assembly.
        # Why it exists: SwiftPM serializes compilation, but the dev bundle's remove-copy-sign
        #   sequence is outside SwiftPM and would otherwise race before either slot clone exists.
        # Scenario: two agents in one checkout launch different slots at the same time.
        with tempfile.TemporaryDirectory() as directory:
            lock_path = Path(directory) / "build.lock"
            ready = Path(directory) / "ready"
            child = os.fork()
            if child == 0:
                with launcher.exclusive_file_lock(lock_path):
                    ready.write_text("ready", encoding="utf-8")
                    signal.pause()
                os._exit(0)
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists())
                contender = os.open(lock_path, os.O_RDWR)
                try:
                    with self.assertRaises(BlockingIOError):
                        launcher.fcntl.flock(
                            contender,
                            launcher.fcntl.LOCK_EX | launcher.fcntl.LOCK_NB,
                        )
                finally:
                    os.close(contender)
                os.kill(child, signal.SIGTERM)
                os.waitpid(child, 0)
                with launcher.exclusive_file_lock(lock_path):
                    pass
            finally:
                try:
                    os.kill(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    os.waitpid(child, 0)
                except ChildProcessError:
                    pass

    def test_exec_inherits_claim_and_kill_makes_slot_immediately_reclaimable(self) -> None:
        # Intent: the app inherits the claim across exec and the kernel releases it on death.
        # Why it exists: closing on exec would reopen a launch race, while pidfiles and stale
        #   markers would strand capacity after SIGKILL.
        # Scenario: an agent launcher becomes DanTerm, then the app is killed uncleanly.
        with tempfile.TemporaryDirectory() as directory:
            ready = Path(directory) / "ready"
            child = os.fork()
            if child == 0:
                claim = launcher.claim_development_slot(Path(directory), range(1, 2))
                ready.write_text(str(claim.slot), encoding="utf-8")
                os.execve("/bin/sleep", ["sleep", "30"], {})
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists())
                time.sleep(0.05)
                with self.assertRaises(launcher.PoolExhaustedError):
                    launcher.claim_development_slot(Path(directory), range(1, 2))
                os.kill(child, signal.SIGKILL)
                os.waitpid(child, 0)
                reclaimed = launcher.claim_development_slot(Path(directory), range(1, 2))
                self.addCleanup(reclaimed.close)
                self.assertEqual(reclaimed.slot, 1)
            finally:
                try:
                    os.kill(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    os.waitpid(child, 0)
                except ChildProcessError:
                    pass

    def test_stage_clone_applies_slot_identity_and_signs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "DanTerm Dev.app"
            executable = source / "Contents" / "MacOS" / "DanTerm Dev"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"fixture")
            plist_path = source / "Contents" / "Info.plist"
            with plist_path.open("wb") as stream:
                plistlib.dump({
                    "CFBundleIdentifier": "com.danneu.danterm-dev",
                    "CFBundleName": "DanTerm Dev",
                    "CFBundleDisplayName": "DanTerm Dev",
                    "CFBundleExecutable": "DanTerm Dev",
                }, stream)
            destination = root / "DanTerm Dev (3).app"

            with mock.patch.object(launcher.subprocess, "run") as run:
                launcher.stage_slot_bundle(source, destination, self.identity(3))

            with (destination / "Contents" / "Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            self.assertEqual(info["CFBundleIdentifier"], "com.danneu.danterm-dev.3")
            self.assertEqual(info["CFBundleDisplayName"], "DanTerm Dev (3)")
            self.assertEqual(info["CFBundleExecutable"], "DanTerm Dev (3)")
            self.assertTrue((destination / "Contents" / "MacOS" / "DanTerm Dev (3)").exists())
            run.assert_called_once()
            self.assertIn("Apple Development", run.call_args.args[0])

    def test_identity_resolution_uses_the_app_launch_environment(self) -> None:
        app_environment = {"HOME": "/Users/test", "SSH_AUTH_SOCK": "/gui/socket"}
        completed = mock.Mock(stdout='{"slot":3,"bundleId":"example"}')

        with mock.patch.object(launcher.subprocess, "run", return_value=completed) as run:
            identity = launcher.resolve_slot_identity(
                Path("/fixture/identity-tool"),
                3,
                app_environment,
            )

        self.assertEqual(identity["bundleId"], "example")
        self.assertEqual(run.call_args.kwargs["env"], app_environment)

    def test_handle_fields_follow_one_identity(self) -> None:
        handle = launcher.launch_handle(self.identity(4), 12345)

        self.assertEqual(handle["slot"], 4)
        self.assertEqual(handle["bundleId"], "com.danneu.danterm-dev.4")
        self.assertEqual(
            handle["socketPath"],
            "/Users/test/Library/Caches/com.danneu.danterm-dev.4/control.sock",
        )
        self.assertEqual(handle["pid"], 12345)

    def test_launch_environment_uses_gui_session_not_agent_state(self) -> None:
        inherited = {
            "PATH": "/agent/bin:/usr/bin",
            "SSH_AUTH_SOCK": "/agent/socket",
            "CLAUDE_CODE_CHILD_SESSION": "leak",
            "DANTERM": "1",
            "DANTERM_SOCK": "/wrong/socket",
            "DANTERM_PANE": "wrong-pane",
        }
        gui = {"SSH_AUTH_SOCK": "/gui/socket", "LANG": "en_US.UTF-8"}

        environment = launcher.launch_services_environment(
            inherited,
            gui,
            home=Path("/Users/test"),
            user="test",
            shell="/bin/zsh",
            temporary_directory="/private/tmp/test/",
        )

        self.assertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        self.assertEqual(environment["SSH_AUTH_SOCK"], "/gui/socket")
        self.assertEqual(environment["LANG"], "en_US.UTF-8")
        self.assertNotIn("CLAUDE_CODE_CHILD_SESSION", environment)
        self.assertNotIn("DANTERM", environment)
        self.assertNotIn("DANTERM_SOCK", environment)
        self.assertNotIn("DANTERM_PANE", environment)


if __name__ == "__main__":
    unittest.main()
