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

    def test_build_lock_survives_build_directory_removal(self) -> None:
        # Intent: launchers sharing one checkout cannot overlap canonical bundle assembly.
        # Why it exists: a lock inside .build guards an unlinked inode after `just clean`,
        #   allowing a second launcher to enter the remove-copy-sign sequence concurrently.
        # Scenario: one agent cleans a checkout while another launcher holds its build lock.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository_root = root / "checkout"
            build_directory = repository_root / ".build"
            build_directory.mkdir(parents=True)
            lock_path = launcher.checkout_build_lock_path(root / "slot-cache", repository_root)
            ready = root / "ready"
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
                build_directory.rmdir()
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

    def test_activation_is_the_only_difference_between_launch_requests(self) -> None:
        # Intent: both launch requests start the app the same way, and --foreground only
        #   withholds the --background flag.
        # Why it exists: --foreground once exec'd the app instead of spawning it, so its
        #   handle promised nothing about readiness and named the launcher's own pid.
        # Scenario: a human runs `just launch-slot-prime` to grant notification permission.
        background = launcher.app_arguments(Path("/slot/DanTerm Dev (1)"), 7, foreground=False)
        foreground = launcher.app_arguments(Path("/slot/DanTerm Dev (1)"), 7, foreground=True)

        self.assertEqual(background, foreground + ["--background"])
        self.assertEqual(foreground, [
            "/slot/DanTerm Dev (1)",
            "--fresh",
            "--development-slot-lock-fd=7",
        ])

    def test_launched_app_releases_the_caller_pipe_and_keeps_the_claim(self) -> None:
        # Intent: the launcher hands the app off instead of becoming it, so a caller's
        #   `just launch-slot | tail -2` reaches end-of-file while the app keeps running.
        # Why it exists: exec'ing the app kept the caller's stdout open for the app's whole
        #   life, so every pipeline hung and read nothing, and `head` broke the app's pipe.
        # Scenario: an agent pipes the launcher into `tail` to read the JSON handle.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "slot.log"
            read_end, write_end = os.pipe()
            child = os.fork()
            if child == 0:
                os.close(read_end)
                os.dup2(write_end, 1)
                os.close(write_end)
                claim = launcher.claim_development_slot(root, range(1, 2))
                pid = launcher.spawn_detached(
                    Path("/bin/sh"),
                    ["sh", "-c", "echo started; sleep 30"],
                    {"PATH": "/usr/bin:/bin"},
                    log,
                )
                claim.close()
                print(pid, flush=True)
                os._exit(0)
            os.close(write_end)
            try:
                # The launcher's own exit is the only thing that closes this pipe.
                with os.fdopen(read_end, "r") as handle:
                    emitted = handle.read()
                os.waitpid(child, 0)
                app = int(emitted.strip())

                deadline = time.monotonic() + 5
                while not log.read_text(encoding="utf-8") and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertEqual(log.read_text(encoding="utf-8").strip(), "started")
                self.assertNotEqual(os.getsid(app), os.getsid(0))
                with self.assertRaises(launcher.PoolExhaustedError):
                    launcher.claim_development_slot(root, range(1, 2))

                # The app owns its session, so this reaches the shells it forked too.
                os.killpg(app, signal.SIGKILL)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    try:
                        reclaimed = launcher.claim_development_slot(root, range(1, 2))
                    except launcher.PoolExhaustedError:
                        time.sleep(0.01)
                        continue
                    self.addCleanup(reclaimed.close)
                    break
                else:
                    self.fail("killing the app did not release its slot")
            finally:
                try:
                    os.kill(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_handle_waits_for_a_connectable_control_socket(self) -> None:
        # Intent: the handle waits for a socket that accepts connections, not for a path.
        # Why it exists: printing at spawn time made the first `danterm --socket` call after
        #   a launch fail with "DanTerm is not running", and a slot killed uncleanly leaves
        #   its socket file behind, so file existence alone reports a dead slot as ready.
        # Scenario: an agent reads the handle and immediately runs a CLI command against it.
        with tempfile.TemporaryDirectory() as directory:
            socket_path = Path(directory) / "control.sock"
            log = Path(directory) / "slot.log"
            socket_path.write_bytes(b"")  # The stale file a killed slot leaves behind.
            listener = f"""
import os, socket, time
os.remove({str(socket_path)!r})
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind({str(socket_path)!r})
server.listen(8)
time.sleep(30)
"""
            pid = launcher.spawn_detached(
                Path(sys.executable),
                [sys.executable, "-c", f"import time; time.sleep(0.3)\n{listener}"],
                {"PATH": "/usr/bin:/bin"},
                log,
            )
            try:
                self.assertFalse(launcher.accepts_connections(socket_path))
                # Returning at all is the contract: it connected to a live server.
                launcher.await_control_socket(socket_path, pid, timeout=10)
            finally:
                os.killpg(pid, signal.SIGKILL)

    def test_unreachable_app_is_killed_so_its_slot_returns_to_the_pool(self) -> None:
        # Intent: a launch that never becomes reachable leaves no app behind holding a slot.
        # Why it exists: the caller gets no handle in that case, so a surviving app would
        #   strand one of the eight slots with nothing able to address or stop it.
        # Scenario: an app starts, hangs before serving its control socket, and times out.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            claim = launcher.claim_development_slot(root, range(1, 2))
            pid = launcher.spawn_detached(
                Path("/bin/sh"),
                ["sh", "-c", "sleep 300"],
                {"PATH": "/usr/bin:/bin"},
                root / "slot.log",
            )
            claim.close()

            with self.assertRaises(launcher.LaunchFailedError):
                launcher.await_control_socket(root / "control.sock", pid, timeout=0.2)

            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
            reclaimed = launcher.claim_development_slot(root, range(1, 2))
            self.addCleanup(reclaimed.close)
            self.assertEqual(reclaimed.slot, 1)

    def test_launch_reports_an_app_that_dies_before_serving(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            socket_path = Path(directory) / "control.sock"
            log = Path(directory) / "slot.log"
            pid = launcher.spawn_detached(
                Path("/bin/sh"),
                ["sh", "-c", "exit 1"],
                {"PATH": "/usr/bin:/bin"},
                log,
            )
            with self.assertRaises(launcher.LaunchFailedError):
                launcher.await_control_socket(socket_path, pid, timeout=10)

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

    def test_pass_env_accepts_only_named_launch_controls(self) -> None:
        options = launcher.parse_arguments([
            "--pass-env",
            "DANTERM_PTY_RECORDING_DIR",
        ])

        self.assertEqual(options.pass_env, ["DANTERM_PTY_RECORDING_DIR"])
        with self.assertRaises(SystemExit):
            launcher.parse_arguments(["--pass-env", "CLAUDE_CODE_CHILD_SESSION"])

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

    def test_launch_environment_preserves_only_explicitly_named_controls(self) -> None:
        inherited = {
            "DANTERM_PTY_RECORDING_DIR": "/tmp/recordings",
            "DANTERM_SOCK": "/tmp/inherited.sock",
            "CLAUDE_CODE_CHILD_SESSION": "leak",
        }

        environment = launcher.launch_services_environment(
            inherited,
            {},
            home=Path("/Users/test"),
            user="test",
            shell="/bin/zsh",
            temporary_directory="/private/tmp/test/",
            passed_environment_names=["DANTERM_PTY_RECORDING_DIR"],
        )

        self.assertEqual(environment["DANTERM_PTY_RECORDING_DIR"], "/tmp/recordings")
        self.assertNotIn("DANTERM_SOCK", environment)
        self.assertNotIn("CLAUDE_CODE_CHILD_SESSION", environment)


if __name__ == "__main__":
    unittest.main()
