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


@dataclass
class SlotClaim:
    """Owns a kernel-released slot lock the launched app inherits and keeps."""

    slot: int
    descriptor: int

    def close(self) -> None:
        if self.descriptor >= 0:
            os.close(self.descriptor)
            self.descriptor = -1


def claim_development_slot(root: Path, slots: Iterable[int] = DEVELOPMENT_SLOTS) -> SlotClaim:
    """Claims the first free nonzero slot without any stale-state cleanup."""

    locks = root / "locks"
    locks.mkdir(parents=True, exist_ok=True)
    for slot in slots:
        if slot == 0:
            continue
        descriptor = os.open(locks / f"slot-{slot}.lock", os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(descriptor)
            continue
        os.set_inheritable(descriptor, True)
        return SlotClaim(slot=slot, descriptor=descriptor)
    raise PoolExhaustedError("all DanTerm development slots are in use")


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
    return parser.parse_args(arguments)


def main(arguments: list[str]) -> int:
    options = parse_arguments(arguments)
    repository_root = Path(__file__).resolve().parent.parent
    account = pwd.getpwuid(os.getuid())
    home = Path(account.pw_dir)
    slot_root = home / "Library" / "Caches" / "com.danneu.danterm-dev-slots"
    try:
        claim = claim_development_slot(slot_root)
    except PoolExhaustedError as error:
        print(f"dev-slot-launcher: {error}", file=sys.stderr)
        return error.exit_status

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
    claim.close()
    try:
        await_control_socket(Path(str(identity["socketPath"])), pid)
    except LaunchFailedError as error:
        print(f"dev-slot-launcher: {error}", file=sys.stderr)
        return error.exit_status
    print(json.dumps(launch_handle(identity, pid), separators=(",", ":")), flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode) from error
