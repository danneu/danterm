#!/usr/bin/env python3
"""Behavioral contract tests for isolated development-slot launching."""

import contextlib
import importlib.util
import io
import json
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

    def test_survey_names_the_checkout_holding_each_busy_slot(self) -> None:
        # Intent: a busy slot reports which checkout holds it and what it is doing.
        # Why it exists: agents in separate worktrees share one eight-slot pool, so
        #   "all slots are in use" is unactionable unless the occupants can be named.
        # Scenario: an agent hits pool exhaustion and asks what is holding the pool.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            claim = launcher.claim_development_slot(root, range(1, 3))
            self.addCleanup(claim.close)
            launcher.describe_occupant(claim, {
                "state": "running",
                "checkout": "/Users/test/worktrees/feature",
                "pid": 4242,
            })

            rows = launcher.survey_slots(root, range(1, 3))

            self.assertEqual(rows[0], {
                "slot": 1,
                "free": False,
                "state": "running",
                "checkout": "/Users/test/worktrees/feature",
                "pid": 4242,
            })
            self.assertEqual(rows[1], {"slot": 2, "free": True})

    def test_survey_ignores_the_record_of_a_slot_the_kernel_has_released(self) -> None:
        # Intent: only the lock decides occupancy; a leftover record never does.
        # Why it exists: an app killed uncleanly leaves its record on disk, and
        #   trusting that record would hide a free slot from every other checkout.
        # Scenario: an agent's machine sleeps or its slot app is force-quit.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            claim = launcher.claim_development_slot(root, range(1, 2))
            launcher.describe_occupant(claim, {"state": "running", "pid": 4242})
            claim.close()

            self.assertEqual(launcher.survey_slots(root, range(1, 2)), [{"slot": 1, "free": True}])

    def test_stopping_a_slot_kills_its_app_and_leaves_the_others_alone(self) -> None:
        # Intent: --stop frees exactly the named slot and returns it to the pool.
        # Why it exists: with no way to release a slot, abandoned apps fill all eight
        #   and the next agent cannot launch; a broad kill would take working slots too.
        # Scenario: an agent finishes testing its change and releases the slot it holds.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pids = []
            for expected_slot in (1, 2):
                # One claim open at a time, as in a launcher process: an app started
                # while a second claim is open would inherit that slot's lock too.
                claim = launcher.claim_development_slot(root, range(1, 3))
                self.assertEqual(claim.slot, expected_slot)
                pid = launcher.spawn_detached(
                    Path("/bin/sh"),
                    ["sh", "-c", "sleep 300"],
                    {"PATH": "/usr/bin:/bin"},
                    root / f"slot-{claim.slot}.log",
                )
                pids.append(pid)
                launcher.describe_occupant(claim, {"state": "running", "pid": pid})
                claim.close()
            self.addCleanup(launcher.terminate_session, pids[1])

            stopped = launcher.stop_slot(root, 1)

            self.assertEqual(stopped["pid"], pids[0])
            self.assertEqual(
                [row["free"] for row in launcher.survey_slots(root, range(1, 3))],
                [True, False],
            )

    def test_stopping_an_already_free_slot_does_nothing_and_succeeds(self) -> None:
        # Intent: releasing a slot is repeatable, so a slot that is already free reports
        #   no occupant rather than an error.
        # Why it exists: every agent is told to release its slot on the way out, and one
        #   whose app already crashed would otherwise end its run on a failure.
        # Scenario: an agent runs `just stop-slot 3` after its app has already died.
        with tempfile.TemporaryDirectory() as directory:
            self.assertIsNone(launcher.stop_slot(Path(directory), 1))

    def test_stopping_refuses_a_slot_that_is_still_building(self) -> None:
        # Intent: a stop that cannot name a running app kills nothing.
        # Why it exists: a launcher holding a slot through its build is not a session
        #   leader, so killing its process group would reach the caller's own shell.
        # Scenario: an agent stops a slot another checkout is still building into.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            claim = launcher.claim_development_slot(root, range(1, 2))
            self.addCleanup(claim.close)
            launcher.describe_occupant(claim, {"state": "building", "checkout": "/checkout"})

            with self.assertRaises(launcher.SlotStopError):
                launcher.stop_slot(root, 1)

    def stand_in_app(self, root: Path, socket_path: Path) -> Path:
        """A bundle executable that reports its arguments and serves its control socket."""

        script = root / "DanTerm Dev (1)"
        script.write_text(
            f"#!{sys.executable}\n"
            "import socket, sys, time\n"
            "print('args:', ' '.join(sys.argv[1:]), flush=True)\n"
            "server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
            f"server.bind({str(socket_path)!r})\n"
            "server.listen(8)\n"
            "time.sleep(300)\n",
            encoding="utf-8",
        )
        script.chmod(0o700)
        return script

    def launch(self, root: Path, *, foreground: bool) -> tuple[dict[str, object], Path]:
        """Runs the real launch path against a stand-in app, as main() does after staging."""

        identity = self.identity(1)
        socket_path = root / "control.sock"
        identity["socketPath"] = str(socket_path)
        claim = launcher.claim_development_slot(root, range(1, 2))
        handle = launcher.launch_slot_app(
            self.stand_in_app(root, socket_path),
            identity,
            {"PATH": "/usr/bin:/bin"},
            claim,
            slot_root=root,
            checkout=Path("/Users/test/worktrees/feature"),
            foreground=foreground,
        )
        self.addCleanup(launcher.terminate_session, int(handle["pid"]))
        return handle, launcher.slot_log_path(root, 1)

    def test_both_launch_requests_spawn_a_detached_app_and_report_it_ready(self) -> None:
        # Intent: --foreground and the default reach the same running app, and the handle
        #   they return names a control socket that already accepts connections.
        # Why it exists: --foreground used to exec the app, so its handle promised nothing
        #   about readiness and named the launcher's own pid.
        # Scenario: a human runs `just launch-slot-prime` to grant notification permission.
        for foreground in (False, True):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                handle, log = self.launch(root, foreground=foreground)

                self.assertTrue(launcher.accepts_connections(root / "control.sock"))
                self.assertNotEqual(os.getsid(int(handle["pid"])), os.getsid(0))
                arguments = log.read_text(encoding="utf-8").strip()
                self.assertIn("--fresh", arguments)
                self.assertEqual("--background" in arguments, not foreground)

    def test_launched_app_releases_the_caller_pipe_and_keeps_the_claim(self) -> None:
        # Intent: the launcher hands the app off instead of becoming it, so a caller's
        #   `just launch-slot | tail -2` reaches end-of-file while the app keeps running.
        # Why it exists: exec'ing the app kept the caller's stdout open for the app's whole
        #   life, so every pipeline hung and read nothing, and `head` broke the app's pipe.
        # Scenario: an agent pipes the launcher into `tail` to read the JSON handle.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            read_end, write_end = os.pipe()
            child = os.fork()
            if child == 0:
                os.close(read_end)
                os.dup2(write_end, 1)
                os.close(write_end)
                handle, _ = self.launch(root, foreground=False)
                print(handle["pid"], flush=True)
                os._exit(0)
            os.close(write_end)
            try:
                # The launcher's own exit is the only thing that closes this pipe.
                with os.fdopen(read_end, "r") as reader:
                    emitted = reader.read()
                os.waitpid(child, 0)
                app = int(emitted.strip())

                self.assertEqual(
                    launcher.survey_slots(root, range(1, 2))[0]["pid"],
                    app,
                )
                launcher.terminate_session(app)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if launcher.survey_slots(root, range(1, 2)) == [{"slot": 1, "free": True}]:
                        break
                    time.sleep(0.01)
                else:
                    self.fail("killing the app did not release its slot")
            finally:
                try:
                    os.kill(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_pool_commands_answer_without_building_or_claiming(self) -> None:
        # Intent: --list and --stop-all report and free the pool without a build, and
        #   without claiming a slot of their own.
        # Why it exists: an agent asks what the pool holds exactly when the pool is full,
        #   so a pool command that fell through to the launch path would claim a ninth
        #   slot to free the eighth, and would take minutes to answer.
        # Scenario: an agent hits pool exhaustion, lists the pool, then empties it.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            account = mock.Mock(pw_dir=directory, pw_name="test", pw_shell="/bin/zsh")
            slot_root = Path(directory) / "Library" / "Caches" / "com.danneu.danterm-dev-slots"
            slot_root.mkdir(parents=True)
            claim = launcher.claim_development_slot(slot_root, range(1, 2))
            pid = launcher.spawn_detached(
                Path("/bin/sh"),
                ["sh", "-c", "sleep 300"],
                {"PATH": "/usr/bin:/bin"},
                root / "slot.log",
            )
            self.addCleanup(launcher.terminate_session, pid)
            launcher.describe_occupant(claim, {"state": "running", "pid": pid})
            claim.close()

            listed = io.StringIO()
            with mock.patch.object(launcher.pwd, "getpwuid", return_value=account), \
                    mock.patch.object(launcher.subprocess, "run") as run:
                with contextlib.redirect_stdout(listed):
                    self.assertEqual(launcher.main(["--list"]), 0)
                    self.assertEqual(launcher.main(["--stop-all"]), 0)

            run.assert_not_called()
            pool, stopped = (json.loads(line) for line in listed.getvalue().splitlines())
            self.assertEqual(pool[0], {"slot": 1, "free": False, "state": "running", "pid": pid})
            self.assertEqual(stopped, [{"state": "running", "pid": pid}])
            self.assertEqual(
                launcher.survey_slots(slot_root, range(1, 2)),
                [{"slot": 1, "free": True}],
            )

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
