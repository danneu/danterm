#!/usr/bin/env python3
"""Claim, stage, and launch one isolated DanTerm development slot.

The launcher prints its JSON handle and exits instead of becoming the app, so
that a caller's `just launch-slot | tail -2` sees end-of-file right away. The
app runs on in its own session with its output in the slot log.

Every slot owns its config file as well as its lock, its log, and its bundle, so
nothing a slot does can reach the user's own config. The launcher names that file
on the launch it starts; it never spells the user's, which the bundled launch-facts
tool reports.
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
OCCUPANT_RECORD_SIZE = 1024
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


class TailnetDisabledError(Exception):
    """Reports a --tailnet launch the user's own config parked, before anything spawns."""

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

    return root / "locks" / f"slot-{slot}.lock"


def claim_development_slot(
    root: Path,
    slots: Iterable[int] = DEVELOPMENT_SLOTS,
    patience: float = 1.0,
) -> SlotClaim:
    """Claims the first free nonzero slot without any stale-state cleanup.

    Rescans while a slot may still free up, because reading the pool locks each
    slot for an instant: one `--list` running beside this scan would otherwise
    report a full pool that is not full.
    """

    (root / "locks").mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + patience
    while True:
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
        if time.monotonic() >= deadline:
            raise PoolExhaustedError(
                "all DanTerm development slots are in use; "
                "`./scripts/dev-slot-launcher.py --list` names the occupants"
            )
        time.sleep(0.05)


def describe_occupant(claim: SlotClaim, description: Mapping[str, object]) -> None:
    """Names the occupant while the slot is held, so a busy slot is never anonymous.

    The launcher writes twice: once at the claim, when only the checkout is known,
    and again at launch, when the app has a pid and a socket. Whoever finds the
    slot busy in between still learns which checkout is holding it.

    Readers take no lock, so the record is padded to one fixed size and replaced
    by a single write. Truncating first would let a reader see an empty slot file.
    """

    payload = json.dumps(dict(description), separators=(",", ":")).encode("utf-8")
    if len(payload) > OCCUPANT_RECORD_SIZE:
        raise ValueError("occupancy record does not fit one slot lock file")
    os.pwrite(claim.descriptor, payload.ljust(OCCUPANT_RECORD_SIZE), 0)


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

    try:
        descriptor = os.open(lock_path, os.O_RDWR)
    except FileNotFoundError:
        return False
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
        lock_path = slot_lock_path(root, slot)
        if not slot_is_claimed(lock_path):
            rows.append({"slot": slot, "free": True})
            continue
        row: dict[str, object] = dict(read_occupant(lock_path) or {})
        row.update({"slot": slot, "free": False})
        rows.append(row)
    return rows


def stop_slot(root: Path, slot: int, timeout: float = 5.0) -> dict[str, object] | None:
    """Returns one agent's slot to the shared pool without disturbing the others.

    Killing the app is the only stop available while it has no quit command. That
    is safe to aim at a process group because the app leads its own session and
    its pane shells leave that session at once, so nothing else of the user's can
    be in the group. Returns None when the slot is already free: every agent is
    told to release its slot on the way out, and that has to stay repeatable.

    A slot still building is refused. The launcher holding it is not a session
    leader, so killing its group would reach the caller's own shell.
    """

    lock_path = slot_lock_path(root, slot)
    if not slot_is_claimed(lock_path):
        return None
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


def resolve_slot_launch_facts(
    helper: Path,
    slot: int,
    environment: Mapping[str, str],
) -> dict[str, object]:
    """Delegates every process name and path to the bundled Swift seams.

    The launcher spells no identity and no path of its own: names, the control
    socket, and the standard per-user config path all come back from this one
    helper. A path written here would be a second resolution that no Swift lint
    sweeps and no rename reaches.
    """

    result = subprocess.run(
        [str(helper), str(slot)],
        check=True,
        capture_output=True,
        text=True,
        env=environment,
    )
    facts = json.loads(result.stdout)
    if facts.get("slot") != slot:
        raise ValueError("launch-facts helper returned a mismatched slot")
    return facts


def ensure_slot_icon(repository_root: Path, slot: int) -> Path:
    """Builds the slot's icon on demand and reports where the builder put it.

    Slot icons are derived from the committed dev artwork rather than committed
    themselves, so the path belongs to the icon build, not to this launcher: the
    builder prints it and this reads it back.
    """

    result = subprocess.run(
        [str(repository_root / "icon" / "build-slot-icons.sh"), str(slot)],
        check=True,
        capture_output=True,
        text=True,
    )
    catalog = Path(result.stdout.strip())
    if catalog.is_file() is False:
        raise ValueError(f"icon build reported a missing catalog: {catalog}")
    return catalog


def stage_slot_bundle(
    source: Path,
    destination: Path,
    identity: Mapping[str, object],
    source_layout_plan: Path,
    repository_root: Path,
) -> None:
    """Stages, signs, and verifies a clone only after its slot has been claimed."""

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
        icon_name = str(identity["iconName"])
        info.update({
            "CFBundleIdentifier": str(identity["bundleId"]),
            "CFBundleName": str(identity["displayName"]),
            "CFBundleDisplayName": str(identity["displayName"]),
            "CFBundleExecutable": name,
            "CFBundleIconName": icon_name,
        })
        with plist_path.open("wb") as stream:
            plistlib.dump(info, stream, sort_keys=False)
        with source_layout_plan.open("r", encoding="utf-8") as stream:
            slot_layout = json.load(stream)
        slot_layout["identity"].update({
            "bundleIdentifier": str(identity["bundleId"]),
            "name": str(identity["displayName"]),
            "displayName": str(identity["displayName"]),
            "executableName": name,
            "iconName": icon_name,
        })
        app_entry = next(
            entry for entry in slot_layout["entries"] if entry["id"] == "appExecutable"
        )
        app_entry["path"] = f"Contents/MacOS/{name}"
        # Every slot is cloned from the same dev app, so the icon is the one part
        # of the bundle that has to be replaced rather than restamped.
        icon_catalog = ensure_slot_icon(repository_root, slot)
        icon_entry = next(
            entry for entry in slot_layout["entries"] if entry["id"] == "iconAssets"
        )
        shutil.copyfile(icon_catalog, temporary.joinpath(*Path(icon_entry["path"]).parts))
        icon_entry["source"]["value"] = os.path.relpath(icon_catalog, repository_root)
        slot_layout_plan = temporary_root / "bundle-layout.json"
        slot_layout_plan.write_text(
            json.dumps(slot_layout, separators=(",", ":")),
            encoding="utf-8",
        )
        subprocess.run([
            str(repository_root / "scripts" / "sign-app-bundle.sh"),
            str(temporary),
            str(slot_layout_plan),
            str(repository_root),
            "Apple Development",
            "--entitlements",
            str(repository_root / "dev-entitlements.plist"),
        ], check=True, stdout=sys.stderr)
        if destination.exists():
            shutil.rmtree(destination)
        temporary.rename(destination)
    finally:
        if temporary_root.exists():
            shutil.rmtree(temporary_root)


def launch_handle(facts: Mapping[str, object], pid: int) -> dict[str, object]:
    """Emits the complete identity handle clients need to drive the new slot."""

    return {
        "slot": facts["slot"],
        "bundleId": facts["bundleId"],
        "socketPath": facts["socketPath"],
        "pid": pid,
    }


def app_arguments(
    executable: Path,
    lock_descriptor: int,
    *,
    foreground: bool,
    config_path: Path,
    init_file: Path | None = None,
    recover: bool = False,
) -> list[str]:
    """Keeps each requested launch input explicit while preserving slot isolation.

    Every slot app starts the same way: detached, on an inherited lock descriptor,
    on a session of its own, and on a config file of its own -- `--config` has no
    default here, because a slot that was not told which file it means would fall
    back to the user's. `--background` withholds activation and the one-time
    notification prompt, so leaving it off is all `--foreground` means. A tailnet
    listener needs no argument: the slot opens one when the config it was given
    names an endpoint. `--recover` withholds `--fresh`, which is the one flag that
    makes the app skip the checkpoints its instance left behind -- so it is how the
    crash-restore path is reachable at all from a recipe. An init file remains a
    caller-owned read-only input, so forwarding its path does not move any
    instance-owned state out of the slot.
    """

    arguments = [str(executable)]
    if not recover:
        arguments.append("--fresh")
    arguments.append(f"--development-slot-lock-fd={lock_descriptor}")
    arguments.extend(["--config", str(config_path)])
    if init_file is not None:
        arguments.extend(["--init", str(init_file)])
    if not foreground:
        arguments.append("--background")
    return arguments


def slot_config_path(slot_root: Path, slot: int) -> Path:
    """Gives each slot a config file of its own, beside its locks, logs, and bundles.

    The path is the launcher's, never a caller's: isolation from the user's config
    is what a slot is, not something a launch request may opt out of.
    """

    return slot_root / "config" / f"slot-{slot}.json"


@dataclass(frozen=True)
class ConfigNumber:
    """Holds one config number exactly as its source wrote it.

    Python's json reads `1e400` as a float infinity and writes it back as
    `Infinity`, which the app refuses -- so a launcher that re-encoded a number it
    copied could turn a config the app accepts into one it does not. The launcher is
    not a second author of the config format, so every number it carries travels as
    its own token.
    """

    token: str


def read_config_document(source: Path) -> dict[str, object] | None:
    """Reads one config file if the app would read it, and answers None otherwise.

    The eligibility rule is the app's, not the launcher's: `DanTermConfigDocument.decode`
    accepts a JSON object whose `schemaVersion` is the integer token 1, and judges
    whatever is deeper than that itself -- loudly. Numbers come back as tokens so the
    document written back out is the one that was read.
    """

    try:
        text = source.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    try:
        document = json.loads(
            text,
            parse_int=ConfigNumber,
            parse_float=ConfigNumber,
            parse_constant=ConfigNumber,
        )
    except ValueError:
        return None
    if not isinstance(document, dict) or document.get("schemaVersion") != ConfigNumber("1"):
        return None
    return document


def encode_config_document(value: object) -> str:
    """Writes back a document `read_config_document` returned, number tokens included.

    Everything here came out of a file the launcher read, so the only choices left are
    the ones JSON does not record: this writes the compact form, and keeps every key in
    the order its source had it.
    """

    if isinstance(value, ConfigNumber):
        return value.token
    if isinstance(value, Mapping):
        body = ",".join(
            f"{json.dumps(key)}:{encode_config_document(item)}" for key, item in value.items()
        )
        return "{" + body + "}"
    if isinstance(value, list):
        return "[" + ",".join(encode_config_document(item) for item in value) + "]"
    return json.dumps(value)


class SeedConfigError(Exception):
    """Reports a --seed-config source the app would refuse, before anything is claimed."""

    exit_status = 1


def resolve_seed_config(source: Path | None) -> dict[str, object] | None:
    """Reads the seed a launch named, refusing the launch when the app would refuse it.

    `--tailnet` is a convenience whose ineligible source honestly means "nothing to
    copy". `--seed-config` is an explicit request, and the same silence would send the
    caller off debugging a terminal that never held the settings they named. The read
    happens before the claim and the build, so the refusal costs neither.
    """

    if source is None:
        return None
    document = read_config_document(source)
    if document is None:
        raise SeedConfigError(
            f"{source} is not a config file the app would read; "
            "it must be a JSON object naming schemaVersion 1"
        )
    return document


def seed_document(
    seed_config: Mapping[str, object] | None,
    tailnet_source: Path | None,
) -> dict[str, object] | None:
    """Decides what a slot's config file starts as, from the sources the launch named.

    `--seed-config` contributes the whole document it named, `--tailnet` contributes the
    user's tailnet block, and the two compose: the seed is the base and the block goes on
    top, so an agent can seed appearance settings and still reach the slot from the iOS
    client. With neither contribution there is no seed, and the slot starts from
    defaults -- which an absent file already means.

    `schemaVersion` is carried over from whichever source supplied it rather than written
    from a constant, because the launcher does not author this format.

    A block the user parked with `enable: false` refuses the launch instead of being
    copied: copying it verbatim gives the slot a listener that never binds, and stripping
    the flag would override the user's own off switch. The refusal reads the same
    document that gets copied, so the checked and the copied values cannot diverge.
    """

    document = dict(seed_config) if seed_config is not None else None
    if tailnet_source is None:
        return document
    source = read_config_document(tailnet_source)
    if source is None:
        return document
    block = source.get("tailnet")
    if not isinstance(block, dict):
        return document
    if block.get("enable") is False:
        raise TailnetDisabledError(
            f"{tailnet_source} sets tailnet.enable to false, so --tailnet has no "
            "listener to copy; set tailnet.enable to true or remove the key"
        )
    if document is None:
        document = {"schemaVersion": source["schemaVersion"]}
    document["tailnet"] = block
    return document


def prepare_slot_config(destination: Path, document: Mapping[str, object] | None) -> None:
    """Resets the slot's config file, then writes whatever seed the launch decided on.

    A slot number is an allocation nobody chose, so whatever the last claim left here is
    another agent's settings: every launch clears the file first, and a slot with no seed
    starts from defaults, which an absent file already means. What a seed writes is a
    regular file of the slot's own -- never a link to the file the seed came from, which
    would undo the isolation the separate file exists for. The sources are only ever read.

    This belongs to the launch path, after a claim succeeds. Attached to the lock
    instead, a `--list` survey would delete a running slot's config.
    """

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.unlink(missing_ok=True)
    if document is None:
        return
    destination.write_text(encode_config_document(document) + "\n", encoding="utf-8")


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


def fetch_tailnet_status(socket_path: Path, pid: int, timeout: float = 10.0) -> dict[str, object]:
    """Asks the running app what its tailnet listener is doing, and reports it verbatim.

    The app is the sole deriver of endpoints and the sole author of this status, so
    the launcher only relays it. A `--tailnet` launch that cannot get an answer did
    not deliver what was asked for, so it kills the app the way an unreachable launch
    does rather than printing a handle that hides the question.
    """

    request = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": "tailnet.status"}, separators=(",", ":")
    )
    connection = socket_module.socket(socket_module.AF_UNIX, socket_module.SOCK_STREAM)
    deadline = time.monotonic() + timeout
    buffered = b""
    response: dict[str, object] | None = None
    try:
        connection.settimeout(timeout)
        connection.connect(str(socket_path))
        connection.sendall(request.encode("utf-8") + b"\n")
        while response is None:
            while b"\n" in buffered:
                line, buffered = buffered.split(b"\n", 1)
                try:
                    frame = json.loads(line)
                except (ValueError, TypeError):
                    continue
                if isinstance(frame, dict) and frame.get("id") == 1:
                    response = frame
                    break
            if response is not None:
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError
            connection.settimeout(remaining)
            received = connection.recv(65536)
            if not received:
                raise ConnectionError
            buffered += received
    except OSError:
        terminate_session(pid)
        raise LaunchFailedError(
            f"the app did not answer tailnet.status within {timeout:g}s, so it was killed"
        ) from None
    finally:
        connection.close()
    status = None if response is None else response.get("result")
    if not isinstance(status, dict) or "state" not in status:
        terminate_session(pid)
        raise LaunchFailedError("the app answered tailnet.status with no status, so it was killed")
    return status


def terminate_session(pid: int) -> None:
    """Frees a claimed slot by killing the one process that holds its lock.

    Signals the group rather than the process so that a child which has not yet
    left the app's session dies with it. Refuses any pid that does not lead its
    own group: only the app does, so a pid the kernel has recycled since the
    record was written can never turn this into a kill of unrelated processes.
    """

    try:
        if os.getpgid(pid) != pid:
            return
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
        "--tailnet",
        action="store_true",
        help="copy the user's tailnet endpoint into this slot's config and open the listener",
    )
    parser.add_argument(
        "--seed-config",
        type=Path,
        metavar="PATH",
        help="start this slot's own config file as a copy of the config file at PATH",
    )
    parser.add_argument(
        "--init",
        dest="init_file",
        type=Path,
        metavar="PATH",
        help="start the slot from the app init file at PATH",
    )
    parser.add_argument(
        "--recover",
        action="store_true",
        help="offer the checkpoints this slot's last instance left, instead of starting fresh",
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


def launch_slot_app(
    executable: Path,
    facts: Mapping[str, object],
    environment: Mapping[str, str],
    claim: SlotClaim,
    *,
    slot_root: Path,
    checkout: Path,
    foreground: bool,
    tailnet: bool = False,
    seed: Mapping[str, object] | None = None,
    init_file: Path | None = None,
    recover: bool = False,
) -> dict[str, object]:
    """Turns a staged bundle into a running slot, and is where the handle earns its meaning.

    Holds every step between the build and the caller's handle -- reset the slot's
    config, spawn, record, hand off the claim, wait for the control socket, ask a
    --tailnet launch what its listener is doing -- so every launch request provably
    takes one path and the returned handle always names a reachable app.
    """

    slot = int(facts["slot"])
    config_path = slot_config_path(slot_root, slot)
    try:
        document = seed_document(
            seed, Path(str(facts["standardConfigPath"])) if tailnet else None
        )
    except TailnetDisabledError:
        # Nothing was spawned, so no app is here to inherit the claim's descriptor:
        # release it now, or a refused launch would leave the slot busy with no
        # occupant to address or stop.
        claim.close()
        raise
    prepare_slot_config(config_path, document)
    pid = spawn_detached(
        executable,
        app_arguments(
            executable,
            claim.descriptor,
            foreground=foreground,
            config_path=config_path,
            init_file=init_file,
            recover=recover,
        ),
        environment,
        slot_log_path(slot_root, slot),
    )
    try:
        handle = launch_handle(facts, pid)
        record = {"state": "running", "checkout": str(checkout), **handle}
        describe_occupant(claim, record)
        socket_path = Path(str(facts["socketPath"]))
        await_control_socket(socket_path, pid)
        if tailnet:
            handle["tailnet"] = fetch_tailnet_status(socket_path, pid)
            try:
                describe_occupant(claim, {**record, "tailnet": handle["tailnet"]})
            except ValueError:
                # A bind failure's reason text has no length the launcher controls, and
                # the row is only a courtesy to whoever finds the slot busy. The record
                # written above stands, and the caller's handle carries the status whole.
                pass
    finally:
        # The claim outlives every failure path above only as this process's own
        # copy; the app inherited the descriptor that actually holds the lock.
        claim.close()
    return handle


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
            occupant = stop_slot(slot_root, int(slot))
        except SlotStopError as error:
            failures.append(error)
            continue
        if occupant is not None:
            stopped.append(occupant)
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
    if options.list or options.stop is not None or options.stop_all:
        return run_pool_command(options, slot_root)
    try:
        seed = resolve_seed_config(options.seed_config)
    except SeedConfigError as error:
        print(f"dev-slot-launcher: {error}", file=sys.stderr)
        return error.exit_status
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
        facts = resolve_slot_launch_facts(
            source_app / "Contents" / "Helpers" / "danterm-launch-facts",
            slot,
            environment,
        )
        app_name = str(facts["displayName"])
        app_path = slot_root / "apps" / f"{app_name}.app"
        stage_slot_bundle(
            source_app,
            app_path,
            facts,
            repository_root / ".build" / "bundle-layout-development.json",
            repository_root,
        )

    executable = app_path / "Contents" / "MacOS" / str(facts["executableName"])
    try:
        handle = launch_slot_app(
            executable,
            facts,
            environment,
            claim,
            slot_root=slot_root,
            checkout=repository_root,
            foreground=options.foreground,
            tailnet=options.tailnet,
            seed=seed,
            init_file=options.init_file,
            recover=options.recover,
        )
    except (LaunchFailedError, TailnetDisabledError) as error:
        print(f"dev-slot-launcher: {error}", file=sys.stderr)
        return error.exit_status
    print(json.dumps(handle, separators=(",", ":")), flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode) from error
