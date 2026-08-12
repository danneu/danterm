#!/usr/bin/env python3
"""Claim, stage, and launch one isolated DanTerm development slot.

The launcher prints its JSON handle and exits instead of becoming the app, so
that a caller's `just launch-slot | tail -2` sees end-of-file right away. The
app runs on in its own session with its output in the slot log.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import shutil
import signal
import socket as socket_module
import subprocess
import sys
import tempfile
import time
from typing import Iterable, Mapping


DEVELOPMENT_SLOTS = range(1, 9)
POOL_EXHAUSTED_STATUS = 75
DEFAULT_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
PASSTHROUGH_ENVIRONMENT_VARIABLES = (
    "DANTERM_PTY_RECORDING_DIR",
    "DANTERM_FRAME_RATE_LOG",
    "DANTERM_DELIVERY_SHAPE_LOG",
    "DANTERM_DELIVERY_SHAPE_TRACE",
)


class LaunchFailedError(Exception):
    """Reports a started app that never became usable, separately from build failure."""

    exit_status = 1


class PoolExhaustedError(Exception):
    """Reports fixed-pool exhaustion separately from build or launch failures."""

    exit_status = POOL_EXHAUSTED_STATUS


class SlotStopError(Exception):
    """Reports a slot that killing an app cannot free, such as one still building."""

    exit_status = 1


@dataclass
class SlotClaim:
    """Owns a kernel-released slot lock the launched app inherits and keeps."""

    slot: int
    descriptor: int

    def close(self) -> None:
        if self.descriptor >= 0:
            os.close(self.descriptor)
            self.descriptor = -1


def slot_lock_path(root: Path, slot: int) -> Path:
    """Holds both facts about a slot in one file: the flock says busy, the body says who.

    Agents in separate checkouts share this one pool, so every launcher must be
    able to read an occupancy another launcher wrote. A second file recording the
    owner could disagree with the lock; the same file cannot.
    """

    locks = root / "locks"
    locks.mkdir(parents=True, exist_ok=True)
    return locks / f"slot-{slot}.lock"


def claim_development_slot(root: Path, slots: Iterable[int] = DEVELOPMENT_SLOTS) -> SlotClaim:
    """Claims the first free nonzero slot without any stale-state cleanup."""

    for slot in slots:
        if slot == 0:
            continue
        descriptor = os.open(slot_lock_path(root, slot), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(descriptor)
            continue
        os.set_inheritable(descriptor, True)
        return SlotClaim(slot=slot, descriptor=descriptor)
    raise PoolExhaustedError(
        "all DanTerm development slots are in use; "
        "`./scripts/dev-slot-launcher.py --list` names the occupants"
    )


def describe_occupant(claim: SlotClaim, description: Mapping[str, object]) -> None:
    """Names the occupant while the slot is held, so a busy slot is never anonymous.

    The launcher writes twice: once at the claim, when only the checkout is known,
    and again at launch, when the app has a pid and a socket. Whoever finds the
    slot busy in between still learns which checkout is holding it.
    """

    payload = json.dumps(dict(description), separators=(",", ":")).encode("utf-8")
    os.ftruncate(claim.descriptor, 0)
    os.pwrite(claim.descriptor, payload, 0)


def read_occupant(lock_path: Path) -> dict[str, object] | None:
    """Reads an occupancy record without taking the lock that would prove it stale."""

    try:
        contents = lock_path.read_bytes()
    except OSError:
        return None
    try:
        record = json.loads(contents)
    except ValueError:
        return None
    return record if isinstance(record, dict) else None


def slot_is_claimed(lock_path: Path) -> bool:
    """Asks the kernel who owns a slot, since only the lock survives an unclean death.

    A record left behind by a killed app proves nothing on its own. Taking the
    lock and dropping it again is the one test that cannot go stale.
    """

    if not lock_path.exists():
        return False
    descriptor = os.open(lock_path, os.O_RDWR)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return False
    except BlockingIOError:
        return True
    finally:
        os.close(descriptor)


def survey_slots(root: Path, slots: Iterable[int] = DEVELOPMENT_SLOTS) -> list[dict[str, object]]:
    """Reports the whole shared pool, because no one checkout knows what it holds."""

    rows: list[dict[str, object]] = []
    for slot in slots:
        lock_path = root / "locks" / f"slot-{slot}.lock"
        if not slot_is_claimed(lock_path):
            rows.append({"slot": slot, "free": True})
            continue
        row: dict[str, object] = dict(read_occupant(lock_path) or {})
        row.update({"slot": slot, "free": False})
        rows.append(row)
    return rows


def stop_slot(root: Path, slot: int, timeout: float = 5.0) -> dict[str, object]:
    """Returns one agent's slot to the shared pool without disturbing the others.

    Killing the app's whole session is the only stop available: the app has no
    quit command, and it forks shells that inherit the slot lock. A slot still
    building is refused instead, because the launcher holding it is not a session
    leader, so killing its group would reach the caller's own shell.
    """

    lock_path = root / "locks" / f"slot-{slot}.lock"
    if not slot_is_claimed(lock_path):
        raise SlotStopError(f"slot {slot} is already free")
    # The lock is held, so the recorded pid names a process that is still alive
    # and cannot have been reused by an unrelated one.
    occupant = read_occupant(lock_path) or {}
    pid = occupant.get("pid")
    if not isinstance(pid, int):
        raise SlotStopError(f"slot {slot} holds no running app to stop")
    terminate_session(pid)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not slot_is_claimed(lock_path):
            return dict(occupant)
        time.sleep(0.02)
    raise SlotStopError(f"slot {slot} was still held {timeout:g}s after its app was killed")


@contextmanager
def exclusive_file_lock(path: Path):
    """Serializes a bounded file operation without leaving stale ownership state."""

    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def checkout_build_lock_path(slot_root: Path, repository_root: Path) -> Path:
    """Keeps each checkout's build lock outside build products that cleaning removes."""

    checkout_digest = hashlib.sha256(
        str(repository_root.resolve()).encode("utf-8")
    ).hexdigest()
    return slot_root / "locks" / f"build-{checkout_digest}.lock"


def resolve_slot_identity(
    helper: Path,
    slot: int,
    environment: Mapping[str, str],
) -> dict[str, object]:
    """Delegates every process name and path to DanTermProtocol's identity seam."""

    result = subprocess.run(
        [str(helper), str(slot)],
        check=True,
        capture_output=True,
        text=True,
        env=environment,
    )
    identity = json.loads(result.stdout)
    if identity.get("slot") != slot:
        raise ValueError("identity helper returned a mismatched slot")
    return identity


def stage_slot_bundle(
    source: Path,
    destination: Path,
    identity: Mapping[str, object],
) -> None:
    """Stages and signs a clone only after its global slot has been claimed."""

    slot = int(identity["slot"])
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary_root = Path(tempfile.mkdtemp(prefix=f"slot-{slot}-", dir=destination.parent))
    temporary = temporary_root / destination.name
    try:
        shutil.copytree(source, temporary, copy_function=shutil.copy2)
        contents = temporary / "Contents"
        plist_path = contents / "Info.plist"
        with plist_path.open("rb") as stream:
            info = plistlib.load(stream)
        old_executable = contents / "MacOS" / str(info["CFBundleExecutable"])
        name = str(identity["executableName"])
        new_executable = contents / "MacOS" / name
        old_executable.rename(new_executable)
        info.update({
            "CFBundleIdentifier": str(identity["bundleId"]),
            "CFBundleName": str(identity["displayName"]),
            "CFBundleDisplayName": str(identity["displayName"]),
            "CFBundleExecutable": name,
        })
        with plist_path.open("wb") as stream:
            plistlib.dump(info, stream, sort_keys=False)
        repository_root = source.parent.parent
        subprocess.run([
            "/usr/bin/codesign",
            "--force",
            "--deep",
            "--sign",
            "Apple Development",
            "--entitlements",
            str(repository_root / "dev-entitlements.plist"),
            str(temporary),
        ], check=True, stdout=sys.stderr)
        if destination.exists():
            shutil.rmtree(destination)
        temporary.rename(destination)
    finally:
        if temporary_root.exists():
            shutil.rmtree(temporary_root)


def launch_handle(identity: Mapping[str, object], pid: int) -> dict[str, object]:
    """Emits the complete identity handle clients need to drive the new slot."""

    return {
        "slot": identity["slot"],
        "bundleId": identity["bundleId"],
        "socketPath": identity["socketPath"],
        "pid": pid,
    }


def app_arguments(executable: Path, lock_descriptor: int, *, foreground: bool) -> list[str]:
    """Keeps activation as the only difference between the two launch requests.

    Every slot app starts the same way: detached, on an inherited lock descriptor,
    with no recovery prompt. `--background` withholds activation and the one-time
    notification prompt, so leaving it off is all `--foreground` means.
    """

    arguments = [
        str(executable),
        "--fresh",
        f"--development-slot-lock-fd={lock_descriptor}",
    ]
    if not foreground:
        arguments.append("--background")
    return arguments


def slot_log_path(slot_root: Path, slot: int) -> Path:
    """Gives the detached app a stable place to write once stdout is not a pipe.

    One file per slot, holding only the instance running in it: the launcher
    truncates on each launch, so relaunching a slot cannot grow the file forever.
    """

    logs = slot_root / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    return logs / f"slot-{slot}.log"


def spawn_detached(
    executable: Path,
    arguments: list[str],
    environment: Mapping[str, str],
    log_path: Path,
) -> int:
    """Starts the app in its own session so the launcher can close its own stdout.

    The app must not hold the caller's pipe: a reader such as `tail` waits for
    end-of-file, and a reader such as `head` would break the pipe under the app.
    Its own session also keeps it alive when the caller's shell goes away.
    """

    log_descriptor = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        return os.posix_spawn(
            str(executable),
            arguments,
            dict(environment),
            file_actions=[
                (os.POSIX_SPAWN_OPEN, 0, os.devnull, os.O_RDONLY, 0o600),
                (os.POSIX_SPAWN_DUP2, log_descriptor, 1),
                (os.POSIX_SPAWN_DUP2, log_descriptor, 2),
            ],
            setsid=True,
        )
    finally:
        os.close(log_descriptor)


def accepts_connections(socket_path: Path) -> bool:
    """Answers whether a live server is behind the path, not whether a file is."""

    connection = socket_module.socket(socket_module.AF_UNIX, socket_module.SOCK_STREAM)
    try:
        connection.settimeout(1.0)
        connection.connect(str(socket_path))
        return True
    except OSError:
        return False
    finally:
        connection.close()


def await_control_socket(socket_path: Path, pid: int, timeout: float = 30.0) -> None:
    """Holds the handle back until the caller's next CLI call can actually connect.

    Without this every caller repeats the same poll loop, and the first
    `danterm --socket` after a launch fails with "DanTerm is not running". An app
    that never becomes reachable is killed rather than left holding one of the
    eight slots that no caller has a handle to.
    """

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        # Connect rather than test for the file: a slot killed uncleanly leaves
        # its socket on disk, and that stale path accepts nothing.
        if accepts_connections(socket_path):
            return
        # The app is this process's child, so a dead one is a zombie that still
        # answers kill(pid, 0); only reaping it reports the exit.
        try:
            reaped, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            reaped = pid
        if reaped == pid:
            raise LaunchFailedError("the app exited before its control socket was reachable")
        time.sleep(0.02)
    terminate_session(pid)
    raise LaunchFailedError(
        f"the app did not answer on {socket_path} within {timeout:g}s, so it was killed"
    )


def terminate_session(pid: int) -> None:
    """Frees a claimed slot whose app is running but unreachable.

    The app leads its own session, so this reaches the shells it has forked and
    the kernel releases the slot lock every one of them inherited.
    """

    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass


def gui_launchd_environment(uid: int) -> dict[str, str]:
    """Reads the GUI launchd environment that LaunchServices-launched apps inherit."""

    result = subprocess.run(
        ["/bin/launchctl", "print", f"gui/{uid}"],
        check=True,
        capture_output=True,
        text=True,
    )
    environment: dict[str, str] = {}
    in_environment = False
    for raw_line in result.stdout.splitlines():
        line = raw_line.strip()
        if line == "environment = {":
            in_environment = True
            continue
        if in_environment and line == "}":
            break
        if in_environment and " => " in line:
            key, value = line.split(" => ", 1)
            environment[key] = value
    return environment


def launch_services_environment(
    inherited: Mapping[str, str],
    gui_environment: Mapping[str, str],
    *,
    home: Path,
    user: str,
    shell: str,
    temporary_directory: str,
    passed_environment_names: Iterable[str] = (),
) -> dict[str, str]:
    """Constructs app launch state without forwarding unmanaged agent variables."""

    environment = dict(gui_environment)
    environment.update({
        "HOME": str(home),
        "USER": user,
        "LOGNAME": user,
        "SHELL": shell,
        "TMPDIR": temporary_directory,
    })
    environment.setdefault("PATH", DEFAULT_PATH)
    for name in passed_environment_names:
        if name in inherited:
            environment[name] = inherited[name]
    return environment


def temporary_directory() -> str:
    """Uses Darwin's per-user temporary directory independently of inherited TMPDIR."""

    result = subprocess.run(
        ["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def parse_arguments(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", action="store_true", help="build the optimized dev app")
    parser.add_argument(
        "--foreground",
        action="store_true",
        help="activate the fresh instance and allow its one-time notification prompt",
    )
    parser.add_argument(
        "--pass-env",
        action="append",
        choices=PASSTHROUGH_ENVIRONMENT_VARIABLES,
        default=[],
        metavar="NAME",
        help="forward one allowlisted DanTerm launch variable; may be repeated",
    )
    pool = parser.add_mutually_exclusive_group()
    pool.add_argument(
        "--list",
        action="store_true",
        help="print every slot in the shared pool as JSON and exit, building nothing",
    )
    pool.add_argument(
        "--stop",
        type=int,
        choices=DEVELOPMENT_SLOTS,
        metavar="SLOT",
        help="kill the app holding one slot and exit; this is how you release your own",
    )
    pool.add_argument(
        "--stop-all",
        action="store_true",
        help="kill every slot app, including ones other agents and checkouts launched",
    )
    return parser.parse_args(arguments)


def run_pool_command(options: argparse.Namespace, slot_root: Path) -> int:
    """Answers the pool questions that need no build, so they stay instant and safe.

    Kept out of main()'s launch path because none of it may claim a slot, build,
    or stage a bundle: an agent asks what the pool holds exactly when the pool is
    the problem.
    """

    if options.list:
        print(json.dumps(survey_slots(slot_root), separators=(",", ":")), flush=True)
        return 0
    targets = (
        [row["slot"] for row in survey_slots(slot_root) if not row["free"]]
        if options.stop_all
        else [options.stop]
    )
    stopped: list[dict[str, object]] = []
    failures: list[SlotStopError] = []
    for slot in targets:
        try:
            stopped.append(stop_slot(slot_root, int(slot)))
        except SlotStopError as error:
            failures.append(error)
    print(json.dumps(stopped, separators=(",", ":")), flush=True)
    for error in failures:
        print(f"dev-slot-launcher: {error}", file=sys.stderr)
    return failures[0].exit_status if failures else 0


def main(arguments: list[str]) -> int:
    options = parse_arguments(arguments)
    repository_root = Path(__file__).resolve().parent.parent
    account = pwd.getpwuid(os.getuid())
    home = Path(account.pw_dir)
    slot_root = home / "Library" / "Caches" / "com.danneu.danterm-dev-slots"
    if options.list or options.stop or options.stop_all:
        return run_pool_command(options, slot_root)
    try:
        claim = claim_development_slot(slot_root)
    except PoolExhaustedError as error:
        print(f"dev-slot-launcher: {error}", file=sys.stderr)
        return error.exit_status
    # The claim is held across the build, so name the checkout now: until the app
    # exists, that is all another agent finding this slot busy can be told.
    describe_occupant(claim, {"state": "building", "checkout": str(repository_root)})

    build_arguments = [str(repository_root / "dev-build.sh"), "--no-install"]
    if options.release:
        build_arguments.append("--release")

    gui_environment = gui_launchd_environment(os.getuid())
    environment = launch_services_environment(
        os.environ,
        gui_environment,
        home=home,
        user=account.pw_name,
        shell=account.pw_shell or "/bin/zsh",
        temporary_directory=temporary_directory(),
        passed_environment_names=options.pass_env,
    )

    build_lock_path = checkout_build_lock_path(slot_root, repository_root)
    with exclusive_file_lock(build_lock_path):
        subprocess.run(build_arguments, check=True, stdout=sys.stderr)

        slot = claim.slot
        source_app = repository_root / ".build" / "DanTerm Dev.app"
        identity = resolve_slot_identity(
            source_app / "Contents" / "Helpers" / "danterm-instance-identity",
            slot,
            environment,
        )
        app_name = str(identity["displayName"])
        app_path = slot_root / "apps" / f"{app_name}.app"
        stage_slot_bundle(source_app, app_path, identity)

    executable = app_path / "Contents" / "MacOS" / str(identity["executableName"])
    pid = spawn_detached(
        executable,
        app_arguments(executable, claim.descriptor, foreground=options.foreground),
        environment,
        slot_log_path(slot_root, slot),
    )
    handle = launch_handle(identity, pid)
    describe_occupant(claim, {"state": "running", "checkout": str(repository_root), **handle})
    claim.close()
    try:
        await_control_socket(Path(str(identity["socketPath"])), pid)
    except LaunchFailedError as error:
        print(f"dev-slot-launcher: {error}", file=sys.stderr)
        return error.exit_status
    print(json.dumps(handle, separators=(",", ":")), flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode) from error
