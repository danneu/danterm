#!/usr/bin/env python3
"""Behavioral contract tests for isolated development-slot launching."""

import contextlib
from collections.abc import Mapping
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
from xml.etree import ElementTree
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
            "iconName": f"AppIcon-dev-{slot}",
            "socketPath": f"/Users/test/Library/Caches/{bundle_id}/control.sock",
        }

    def write_slot_catalog(self, slot: int) -> Path:
        """Stands in for what icon/build-slot-icons.sh leaves under .build/icons.

        It sits inside the real checkout rather than the fixture's temporary tree
        because the staged plan records where each file came from, and the
        verifier rejects a source that escapes the repository root. It gets its
        own directory so it can never stand on a catalog a slot is using.
        """
        directory = Path(tempfile.mkdtemp(prefix="slot-catalog-", dir=ROOT / ".build"))
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        catalog = directory / "Assets.car"
        catalog.write_bytes(f"slot {slot} catalog".encode("utf-8"))
        return catalog

    @staticmethod
    def write_bundle_fixture(root: Path) -> tuple[Path, Path]:
        source = root / "DanTerm Dev.app"
        app = source / "Contents" / "MacOS" / "DanTerm Dev"
        cli = source / "Contents" / "Helpers" / "danterm"
        catalog = source / "Contents" / "Resources" / "Assets.car"
        app.parent.mkdir(parents=True)
        cli.parent.mkdir(parents=True)
        catalog.parent.mkdir(parents=True)
        app.write_bytes(b"gui fixture")
        cli.write_bytes(b"cli fixture")
        catalog.write_bytes(b"slot zero catalog")
        app.chmod(0o755)
        cli.chmod(0o755)
        plist_path = source / "Contents" / "Info.plist"
        info = {
            "CFBundleIdentifier": "com.danneu.danterm-dev",
            "CFBundleName": "DanTerm Dev",
            "CFBundleDisplayName": "DanTerm Dev",
            "CFBundleExecutable": "DanTerm Dev",
            "CFBundleIconName": "AppIcon-dev",
        }
        with plist_path.open("wb") as stream:
            plistlib.dump(info, stream)
        plan = root / "development-layout.json"
        plan.write_text(json.dumps({
            "schemaVersion": 1,
            "variant": "development",
            "identity": {
                "bundleIdentifier": "com.danneu.danterm-dev",
                "name": "DanTerm Dev",
                "displayName": "DanTerm Dev",
                "executableName": "DanTerm Dev",
                "iconName": "AppIcon-dev",
            },
            "exactSetDirectories": ["Contents/MacOS", "Contents/Helpers"],
            "entries": [
                {
                    "id": "appExecutable",
                    "path": "Contents/MacOS/DanTerm Dev",
                    "mode": 0o755,
                    "source": {"kind": "product", "value": "DanTerm"},
                },
                {
                    "id": "commandLineExecutable",
                    "path": "Contents/Helpers/danterm",
                    "mode": 0o755,
                    "source": {"kind": "product", "value": "DanTermCLI"},
                },
                {
                    "id": "infoPlist",
                    "path": "Contents/Info.plist",
                    "mode": 0o644,
                    "source": {"kind": "propertyListTemplate", "value": "app/Info.plist"},
                },
                {
                    "id": "iconAssets",
                    "path": "Contents/Resources/Assets.car",
                    "mode": 0o644,
                    "source": {"kind": "repositoryFile", "value": "icon/AppIcon-dev/Assets.car"},
                },
            ],
        }), encoding="utf-8")
        return source, plan

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

    def test_tailnet_adds_one_argument_and_nothing_else(self) -> None:
        # Intent: asking for a tailnet listener changes exactly one launch argument.
        # Why it exists: the opt-in must not quietly alter recovery or activation, which
        #   every agent's default launch depends on.
        # Scenario: an agent launches a slot with --tailnet to drive the iOS client.
        plain = launcher.app_arguments(Path("/slot/DanTerm Dev (1)"), 7, foreground=False)
        opted = launcher.app_arguments(
            Path("/slot/DanTerm Dev (1)"), 7, foreground=False, tailnet=True
        )

        self.assertEqual(opted, plain + ["--tailnet"])

    def test_tailnet_is_requested_explicitly_or_not_at_all(self) -> None:
        self.assertFalse(launcher.parse_arguments([]).tailnet)
        self.assertTrue(launcher.parse_arguments(["--tailnet"]).tailnet)

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

    def stand_in_app(
        self,
        root: Path,
        socket_path: Path,
        status: Mapping[str, object] | None = None,
        *,
        hello_before_status: bool = False,
    ) -> Path:
        """A bundle executable that reports its arguments and serves its control socket.

        With a status it answers every request line with that JSON-RPC result, the way
        the app answers `tailnet.status`; without one it only listens, which is how an
        app that never answers the query is reproduced. It can also send the server-first
        hello notification that every real DanTerm IPC connection sends.
        """

        reply = (
            None if status is None
            else json.dumps({"jsonrpc": "2.0", "id": 1, "result": dict(status)})
        )
        hello = json.dumps({"jsonrpc": "2.0", "method": "hello", "params": {}})
        wire_reply = (
            None
            if reply is None
            else ((hello + "\n") if hello_before_status else "") + reply + "\n"
        )
        script = root / "DanTerm Dev (1)"
        script.write_text(
            f"#!{sys.executable}\n"
            "import socket, sys, time\n"
            "print('args:', ' '.join(sys.argv[1:]), flush=True)\n"
            f"reply = {wire_reply!r}\n"
            "server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
            f"server.bind({str(socket_path)!r})\n"
            "server.listen(8)\n"
            "if reply is None:\n"
            "    time.sleep(300)\n"
            "deadline = time.monotonic() + 300\n"
            "while time.monotonic() < deadline:\n"
            "    connection, _ = server.accept()\n"
            "    try:\n"
            "        connection.recv(65536)\n"
            "        connection.sendall(reply.encode('utf-8'))\n"
            "    except OSError:\n"
            "        pass\n"
            "    finally:\n"
            "        connection.close()\n",
            encoding="utf-8",
        )
        script.chmod(0o700)
        return script

    def launch(
        self,
        root: Path,
        *,
        foreground: bool,
        tailnet: bool = False,
        status: Mapping[str, object] | None = None,
        hello_before_status: bool = False,
    ) -> tuple[dict[str, object], Path]:
        """Runs the real launch path against a stand-in app, as main() does after staging."""

        identity = self.identity(1)
        socket_path = root / "control.sock"
        identity["socketPath"] = str(socket_path)
        claim = launcher.claim_development_slot(root, range(1, 2))
        handle = launcher.launch_slot_app(
            self.stand_in_app(
                root,
                socket_path,
                status,
                hello_before_status=hello_before_status,
            ),
            identity,
            {"PATH": "/usr/bin:/bin"},
            claim,
            slot_root=root,
            checkout=Path("/Users/test/worktrees/feature"),
            foreground=foreground,
            tailnet=tailnet,
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

    def test_tailnet_launch_carries_the_app_authored_status_verbatim(self) -> None:
        # Intent: a --tailnet launch asks the running app for its listener state and
        #   reports that object unchanged in the handle and in the occupancy row.
        # Why it exists: the app is the sole deriver of endpoints. A launcher that
        #   computed the port itself, or synthesized a state, would disagree with the
        #   app the moment either rule changed.
        # Scenario: an agent launches a slot with --tailnet and reads .tailnet from the
        #   handle to point the iOS client at it.
        status = {
            "state": "waiting",
            "base": "100.99.4.1:24863",
            "offset": 2,
            "endpoint": "100.99.4.1:24865",
            "reason": "the listener is not open yet",
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            handle, log = self.launch(root, foreground=False, tailnet=True, status=status)

            self.assertEqual(handle["tailnet"], status)
            self.assertIn("--tailnet", log.read_text(encoding="utf-8"))
            self.assertEqual(launcher.survey_slots(root, range(1, 2))[0]["tailnet"], status)

    def test_tailnet_launch_ignores_server_first_hello_before_status(self) -> None:
        # Intent: a --tailnet launch correlates the status response by request id after
        #   ignoring notifications, even when both frames arrive in one read.
        # Why it exists: every real IPC connection sends hello before reading requests,
        #   which made the launcher mistake that notification for the status response.
        # Scenario: the dev-slot launcher connects to a real DanTerm control socket.
        status = {"state": "listening", "endpoint": "100.99.4.1:24865"}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            handle, _ = self.launch(
                root,
                foreground=False,
                tailnet=True,
                status=status,
                hello_before_status=True,
            )

            self.assertEqual(handle["tailnet"], status)

    def test_a_launch_without_the_flag_reports_no_tailnet_at_all(self) -> None:
        # Intent: the default launch every agent uses asks nothing about the tailnet and
        #   its handle carries no tailnet field.
        # Why it exists: the status query is one more thing that can fail after spawn, so
        #   it must not sit in the path of launches that never wanted a listener.
        # Scenario: an agent runs `just launch-slot` to drive an ordinary dev app.
        status = {"state": "disabled", "reason": "no tailnet endpoint is configured"}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            handle, log = self.launch(root, foreground=False, status=status)

            self.assertNotIn("tailnet", handle)
            self.assertNotIn("--tailnet", log.read_text(encoding="utf-8"))
            self.assertNotIn("tailnet", launcher.survey_slots(root, range(1, 2))[0])

    def test_an_oversized_status_reaches_the_caller_and_only_the_row_drops_it(self) -> None:
        # Intent: a status too long for the fixed-size occupancy record still launches,
        #   and the caller's handle still carries it in full.
        # Why it exists: the reason text comes from a bind failure, so its length is not
        #   bounded by anything the launcher controls, and the occupancy row is a
        #   courtesy for whoever finds the slot busy, not the answer the caller asked for.
        # Scenario: a slot's bind fails with a long resolver message.
        status = {"state": "waiting", "base": "100.99.4.1:24863", "offset": 2,
                  "endpoint": "100.99.4.1:24865", "reason": "x" * launcher.OCCUPANT_RECORD_SIZE}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            handle, _ = self.launch(root, foreground=False, tailnet=True, status=status)

            self.assertEqual(handle["tailnet"], status)
            row = launcher.survey_slots(root, range(1, 2))[0]
            self.assertNotIn("tailnet", row)
            self.assertEqual(row["pid"], handle["pid"])

    def test_an_unanswered_status_query_fails_the_launch_and_frees_the_slot(self) -> None:
        # Intent: a reachable app that never answers the status query fails the launch
        #   loudly within a bounded time and leaves no app holding the slot.
        # Why it exists: the caller gets no handle in that case, so a surviving app would
        #   strand one of the eight slots with nothing able to address or stop it.
        # Scenario: a slot app serves its control socket but wedges before replying.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            socket_path = root / "control.sock"
            claim = launcher.claim_development_slot(root, range(1, 2))
            pid = launcher.spawn_detached(
                self.stand_in_app(root, socket_path),
                [str(root / "DanTerm Dev (1)")],
                {"PATH": "/usr/bin:/bin"},
                root / "slot.log",
            )
            claim.close()
            launcher.await_control_socket(socket_path, pid, timeout=30)

            # Deliberately short: this deadline is meant to expire, since the stand-in
            # never replies.
            with self.assertRaises(launcher.LaunchFailedError):
                launcher.fetch_tailnet_status(socket_path, pid, timeout=0.3)

            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
            reclaimed = launcher.claim_development_slot(root, range(1, 2))
            self.addCleanup(reclaimed.close)
            self.assertEqual(reclaimed.slot, 1)

    def test_a_reply_with_no_status_fails_the_launch_and_frees_the_slot(self) -> None:
        # Intent: an answer the launcher cannot read as a status fails the launch instead
        #   of producing a handle with a made-up field.
        # Why it exists: the launcher relays the app's status and authors none, so it has
        #   nothing to fall back on when the reply is not one.
        # Scenario: a slot app answers tailnet.status with an error instead of a result.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(launcher.LaunchFailedError):
                self.launch(root, foreground=False, tailnet=True, status={"unexpected": True})

            reclaimed = launcher.claim_development_slot(root, range(1, 2))
            self.addCleanup(reclaimed.close)
            self.assertEqual(reclaimed.slot, 1)

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
            source, plan = self.write_bundle_fixture(root)
            destination = root / "DanTerm Dev (3).app"
            slot_catalog = self.write_slot_catalog(3)

            with mock.patch.object(launcher.subprocess, "run") as run, mock.patch.object(
                launcher, "ensure_slot_icon", return_value=slot_catalog
            ):
                launcher.stage_slot_bundle(
                    source, destination, self.identity(3), plan, ROOT
                )

            with (destination / "Contents" / "Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            self.assertEqual(info["CFBundleIdentifier"], "com.danneu.danterm-dev.3")
            self.assertEqual(info["CFBundleDisplayName"], "DanTerm Dev (3)")
            self.assertEqual(info["CFBundleExecutable"], "DanTerm Dev (3)")
            self.assertTrue((destination / "Contents" / "MacOS" / "DanTerm Dev (3)").exists())
            # The icon is the one part of the clone that is replaced, not restamped:
            # eight slots cloned from one dev app would otherwise share one icon.
            self.assertEqual(info["CFBundleIconName"], "AppIcon-dev-3")
            self.assertEqual(
                (destination / "Contents" / "Resources" / "Assets.car").read_bytes(),
                b"slot 3 catalog",
            )
            self.assertEqual(len(run.call_args_list), 1)
            self.assertIn("sign-app-bundle.sh", run.call_args_list[0].args[0][0])
            self.assertIn("Apple Development", run.call_args_list[0].args[0])

    def test_stage_clone_rejects_post_sign_executable_identity_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, plan = self.write_bundle_fixture(root)
            destination = root / "DanTerm Dev (3).app"
            real_run = subprocess.run

            # Stand in for a signer that rewrites the identity it was given, then
            # run the real verification the signer performs on what it produced.
            def sign_then_verify(arguments, **kwargs):
                if arguments[0].endswith("sign-app-bundle.sh"):
                    bundle, layout_plan, repo_root = arguments[1:4]
                    plist_path = Path(bundle) / "Contents" / "Info.plist"
                    with plist_path.open("rb") as stream:
                        info = plistlib.load(stream)
                    info["CFBundleExecutable"] = "Wrong Executable"
                    with plist_path.open("wb") as stream:
                        plistlib.dump(info, stream)
                    return real_run(
                        [
                            str(ROOT / "scripts" / "verify-bundle-layout.sh"),
                            bundle,
                            layout_plan,
                            repo_root,
                        ],
                        check=True,
                    )
                return real_run(arguments, **kwargs)

            slot_catalog = self.write_slot_catalog(3)

            with mock.patch.object(
                launcher.subprocess, "run", side_effect=sign_then_verify
            ), mock.patch.object(launcher, "ensure_slot_icon", return_value=slot_catalog):
                with self.assertRaises(subprocess.CalledProcessError):
                    launcher.stage_slot_bundle(
                        source, destination, self.identity(3), plan, ROOT
                    )

            self.assertFalse(destination.exists())

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


class SlotIconArtworkTests(unittest.TestCase):
    """Covers the artwork half of slot identity: the plate each slot's icon carries."""

    GENERATOR = ROOT / "icon" / "gen-slot-icon.sh"

    def generate(self, slot: str, directory: Path) -> Path:
        output = directory / f"raw-dev-{slot}.svg"
        subprocess.run(
            [str(self.GENERATOR), slot, str(output)],
            check=True,
            capture_output=True,
            text=True,
        )
        return output

    def test_every_slot_gets_artwork_no_other_slot_has(self) -> None:
        # Intent: each of the eight slots produces well-formed artwork whose plate
        #   nothing else shares, and every one differs from the plain dev icon.
        # Why it exists: the whole point of a per-slot icon is telling two running
        #   slots apart in the Dock and the Cmd-Tab switcher. A generator that
        #   silently emitted the same plate twice would still build, sign, and
        #   launch -- and leave the user right back where they started.
        # Scenario: generate all eight, then compare them to each other and to the
        #   committed raw-dev.svg they are derived from.
        base = (ROOT / "icon" / "raw-dev.svg").read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as directory:
            drawings = {
                slot: self.generate(str(slot), Path(directory)).read_text(encoding="utf-8")
                for slot in range(1, 9)
            }
        palettes = {}
        for slot, drawing in drawings.items():
            tree = ElementTree.fromstring(drawing)
            self.assertNotEqual(drawing, base, f"slot {slot} reuses the plain dev icon")
            palettes[slot] = frozenset(
                element.get("fill") for element in tree.iter() if element.get("fill")
            )
        self.assertEqual(len(set(drawings.values())), 8)
        # Colour is what survives at Dock size, where the digit is a few pixels
        # tall, so two slots sharing a palette are not actually distinguishable.
        self.assertEqual(len(set(palettes.values())), 8)

    def test_a_slot_outside_the_pool_is_refused_rather_than_drawn(self) -> None:
        # Intent: the generator refuses any slot the launcher pool cannot hand out.
        # Why it exists: each plate is drawn by hand, so there is nothing to fall
        #   back on outside 1 through 8 -- silently emitting a plateless or
        #   half-drawn icon would ship a slot that looks like the canonical dev app.
        with tempfile.TemporaryDirectory() as directory:
            for slot in ("0", "9", "dev"):
                with self.assertRaises(subprocess.CalledProcessError):
                    self.generate(slot, Path(directory))


class SlotIconResolutionTests(unittest.TestCase):
    """Covers what the launcher does with the icon build's answer."""

    def test_an_icon_build_that_names_a_missing_catalog_stops_the_launch(self) -> None:
        # Intent: `ensure_slot_icon` refuses a path the icon build did not produce.
        # Why it exists: staging copies whatever this returns into the bundle. A
        #   builder that exits zero having written nothing would otherwise fail
        #   later, inside the copy, with no mention of the icon at all.
        completed = subprocess.CompletedProcess(args=[], returncode=0, stdout="/nonexistent/Assets.car\n")
        with mock.patch.object(launcher.subprocess, "run", return_value=completed):
            with self.assertRaises(ValueError):
                launcher.ensure_slot_icon(ROOT, 3)


if __name__ == "__main__":
    unittest.main()
