#!/usr/bin/env python3
"""Admit, ready, and drive the live `btop-scroll` profiling workload.

`btop-scroll` is the one benchmark workload whose stimulus is a real application
under real keyboard input, so three things the corpus workloads get for free have
to be decided explicitly: which profiling modes may ask for it at all, whether the
host can even produce the stimulus before anything expensive is built, and whether
the process that ended up on the PTY is the one this invocation owns. Those
decisions live here -- separately invocable and hermetically testable -- rather
than inside the profiling shell, where a rejection and a crash look alike.

What belongs here: mode and duration admission, the preflight that must precede
any build or launch, owned-process and live-PTY readiness, and the driver that
holds an arrow key across one profiler run while sampling the host's state. What
does not: the timing rules themselves (`terminal_btop_stimulus`), the artifact
grading (`terminal_btop_artifacts`), and building, launching, or profiling the app
(`terminal-benchmark.sh` and `terminal-benchmark-profile.sh`).

Its own file because the profiling harness is a shell script: everything above is
policy that a shell can only express as a test-hostile pile of `case` arms.
"""
import argparse
import json
import pathlib
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import terminal_btop_artifacts as artifacts  # noqa: E402
import terminal_btop_stimulus as stimulus  # noqa: E402


WORKLOAD_NAME = "btop-scroll"
# The only three modes btop may enter. `memory` is absent on
# purpose, and so is every calibrated comparison: those reach a verdict, and a
# live process list is not a workload any verdict may rest on.
PROFILING_MODES = ("loop", "sample", "trace")
BOUNDED_MODES = ("sample", "trace")
# The bounded interface's 1-20 second window. The floor keeps a recording from
# being shorter than the profiler's own attach cost; the ceiling scopes the
# diagnostic to the reproduced incident.
MIN_DURATION_SECONDS = 1
MAX_DURATION_SECONDS = 20
# The canonical live-PTY geometry, as `stty size` reports it: rows first.
CANONICAL_ROWS = 66
CANONICAL_COLUMNS = 179
LOOP_LEG_SECONDS = 10.0
# Held before and after the profiler's own window so its edges profile a running
# stimulus rather than a key that is still going down or already up.
DEFAULT_LEAD_SECONDS = 1.0
DEFAULT_TRAIL_SECONDS = 1.0
# How long past its requested window a profiler may take to attach, save, and
# exit before the capture is abandoned. `xctrace` spends seconds on each end; the
# bound exists so a wedged one cannot violate the release-on-every-exit guarantee.
PROFILER_OVERHEAD_SECONDS = 180.0
MACHINE_STATE_INTERVAL_SECONDS = 1.0
READINESS_TIMEOUT_SECONDS = 60.0
READINESS_POLL_SECONDS = 0.1

STATE_PROBE_SOURCE = pathlib.Path(__file__).with_name("terminal-benchmark-state-probe.swift")
PREFLIGHT = "btop-preflight.json"
READINESS = "btop-readiness.json"
LIVE_STIMULUS = "btop-stimulus-live.json"


class WorkloadRejected(RuntimeError):
    """This invocation may not run `btop-scroll` -- a decision, never a host failure.

    Distinct from the stimulus and capture errors so a caller can tell "you asked
    for something this workload does not offer" from "the run tried and could not
    prove what it measured".
    """


# --- admission ----------------------------------------------------------------


def admit_mode(mode):
    """Admit `btop-scroll` only to sample, trace, and loop profiling."""
    if mode not in PROFILING_MODES:
        raise WorkloadRejected(
            f"`{WORKLOAD_NAME}` is a profiling-only workload: it is offered to "
            f"{', '.join(PROFILING_MODES)} and never to `{mode}`, because a live "
            "process list cannot carry a decision or a comparison"
        )
    return mode


def admit_duration(mode, raw):
    """Require sample and trace to use 1-20 whole seconds and refuse a duration for loop.

    Returns the whole seconds a bounded capture will record, or `None` for loop --
    which runs until interrupted, so a duration there would describe nothing.
    """
    admit_mode(mode)
    if mode == "loop":
        if raw not in (None, ""):
            raise WorkloadRejected(
                f"`{WORKLOAD_NAME}` loop mode takes no duration: it runs until "
                "interrupted, alternating fixed legs"
            )
        return None
    if raw in (None, ""):
        raise WorkloadRejected(
            f"`{WORKLOAD_NAME}` {mode} mode requires an explicit recording duration "
            f"of {MIN_DURATION_SECONDS}-{MAX_DURATION_SECONDS} whole seconds"
        )
    text = str(raw).strip()
    if not text.isdigit():
        raise WorkloadRejected(
            f"`{WORKLOAD_NAME}` {mode} duration must be whole seconds, not {raw!r}"
        )
    seconds = int(text)
    if not MIN_DURATION_SECONDS <= seconds <= MAX_DURATION_SECONDS:
        raise WorkloadRejected(
            f"`{WORKLOAD_NAME}` {mode} duration must be {MIN_DURATION_SECONDS}-"
            f"{MAX_DURATION_SECONDS} whole seconds, not {seconds}"
        )
    return seconds


# --- owned-process and live-PTY readiness --------------------------------------


def parse_process_table(text):
    """Parse `ps -Ao pid=,ppid=,tty=,comm=` into records, dropping what cannot be read.

    `comm` is the executable's own path, which is what makes the ownership test
    below an identity test rather than a name match: a `btop` on someone else's
    PATH is a different binary and must not answer for this run's.
    """
    entries = []
    for line in text.splitlines():
        fields = line.split(None, 3)
        if len(fields) != 4 or not fields[0].isdigit() or not fields[1].isdigit():
            continue
        entries.append(
            {
                "pid": int(fields[0]),
                "ppid": int(fields[1]),
                "tty": fields[2],
                "command": fields[3].strip(),
            }
        )
    return entries


def descendant_pids(entries, root_pid):
    """Every pid under `root_pid`, so ownership is proved by lineage and not by name."""
    children = {}
    for entry in entries:
        children.setdefault(entry["ppid"], []).append(entry["pid"])
    seen = set()
    pending = [root_pid]
    while pending:
        pid = pending.pop()
        for child in children.get(pid, ()):
            if child not in seen:
                seen.add(child)
                pending.append(child)
    return seen


def select_owned_btop(entries, *, executable, app_pid):
    """Find the one btop this invocation owns, refusing zero and refusing several.

    Ambiguity is rejected rather than resolved: with two candidates there is no
    fact on the table saying which one the profiler's samples came from, and
    picking either would put an unowned process's behavior in the record. The
    operator's own btop, running outside this app's process tree, is never a
    candidate at all.
    """
    owned = descendant_pids(entries, app_pid)
    candidates = [
        entry
        for entry in entries
        if entry["command"] == str(executable) and entry["pid"] in owned
    ]
    if not candidates:
        raise WorkloadRejected(
            f"no `{executable}` process is running under the benchmark app (pid "
            f"{app_pid}), so nothing this run owns is producing the workload"
        )
    if len(candidates) > 1:
        pids = ", ".join(str(entry["pid"]) for entry in candidates)
        raise WorkloadRejected(
            f"the benchmark app owns {len(candidates)} `{executable}` processes "
            f"({pids}); a profile cannot be attributed to an ambiguous workload"
        )
    entry = candidates[0]
    if not entry["tty"] or entry["tty"] in ("?", "??", "-"):
        raise WorkloadRejected(
            f"owned btop pid {entry['pid']} has no controlling terminal, so its PTY "
            "geometry cannot be checked"
        )
    return entry


def parse_stty_size(text):
    """Read `stty size` output as (rows, columns)."""
    fields = text.split()
    if len(fields) != 2 or not all(field.isdigit() for field in fields):
        raise WorkloadRejected(f"could not read a PTY size from {text!r}")
    return int(fields[0]), int(fields[1])


def require_canonical_geometry(rows, columns):
    """Require the owned btop's live PTY to report the canonical 179x66 geometry."""
    if (rows, columns) != (CANONICAL_ROWS, CANONICAL_COLUMNS):
        raise WorkloadRejected(
            f"the owned btop PTY reports {columns}x{rows}, not the canonical "
            f"{CANONICAL_COLUMNS}x{CANONICAL_ROWS}; the workload is only defined at "
            "that geometry"
        )
    return {"rows": rows, "columns": columns}


def read_live_pty_size(tty, *, run_command=subprocess.run):
    """Ask the kernel for the owned PTY's current winsize.

    Read from the device rather than from inside the pane: an in-pane `stty` run
    before btop starts reports the size at that moment, while readiness requires
    the geometry the uniquely owned profiled process is drawing at now.
    """
    device = tty if str(tty).startswith("/dev/") else f"/dev/{tty}"
    result = run_command(
        ["stty", "-f", device, "size"], check=True, capture_output=True, text=True
    )
    return parse_stty_size(result.stdout)


def await_readiness(
    *,
    executable,
    app_pid,
    environment,
    run_command=subprocess.run,
    monotonic=time.monotonic,
    sleep=time.sleep,
    timeout_seconds=READINESS_TIMEOUT_SECONDS,
):
    """Block until one owned btop is drawing at the canonical geometry, then say which.

    Both conditions are polled together because they become true in that order and
    neither is worth reporting alone: an owned btop at the wrong size is not the
    workload, and the right size on an unowned process is not this run's.
    """
    deadline = monotonic() + timeout_seconds
    last = None
    while True:
        try:
            table = run_command(
                ["ps", "-Ao", "pid=,ppid=,tty=,comm="],
                check=True,
                capture_output=True,
                text=True,
            )
            entry = select_owned_btop(
                parse_process_table(table.stdout), executable=executable, app_pid=app_pid
            )
            rows, columns = read_live_pty_size(entry["tty"], run_command=run_command)
            geometry = require_canonical_geometry(rows, columns)
        except WorkloadRejected as error:
            last = error
        else:
            return {
                "executablePath": str(executable),
                "process": {
                    "pid": entry["pid"],
                    "parentPid": entry["ppid"],
                    "tty": entry["tty"],
                    **geometry,
                },
                "config": artifacts.btop_config_identity(environment),
            }
        if monotonic() >= deadline:
            raise WorkloadRejected(
                f"the workload was not ready within {timeout_seconds:g}s: {last}"
            )
        sleep(READINESS_POLL_SECONDS)


# --- machine state -------------------------------------------------------------


def compile_state_probe(output_directory, *, source_path=STATE_PROBE_SOURCE,
                        run_command=subprocess.run):
    """Build the host-state probe up front, so a capture never discovers it cannot sample."""
    output_directory = pathlib.Path(output_directory)
    output_directory.mkdir(parents=True, exist_ok=True)
    binary = output_directory / "terminal-benchmark-state-probe"
    run_command(
        ["xcrun", "swiftc", str(source_path), "-O", "-o", str(binary)],
        check=True,
        capture_output=True,
        text=True,
    )
    return binary


class MachineStateSampler:
    """Samples thermal and power state on its own thread for the length of a capture.

    A thread rather than a poll inside the stimulus pump: the pump's timing is the
    stimulus's cadence, and a `swiftc`-built probe costing tens of milliseconds
    would show up there as skipped repeats. Samples are counted, never latched, so
    an interval nobody sampled is graded as unmeasured (`machine_state_coverage`).
    """

    def __init__(self, probe, *, interval_seconds=MACHINE_STATE_INTERVAL_SECONDS,
                 run_command=subprocess.run):
        self._probe = probe
        self._interval = interval_seconds
        self._run_command = run_command
        self._samples = []
        self._stop = threading.Event()
        self._thread = None

    def _sample_once(self):
        try:
            result = self._run_command(
                [str(self._probe)], check=True, capture_output=True, text=True
            )
            self._samples.append(json.loads(result.stdout))
        except (subprocess.CalledProcessError, OSError, json.JSONDecodeError):
            # A probe that failed contributed no observation; recording a nominal
            # placeholder would be the one thing this whole module refuses to do.
            pass

    def _run(self):
        while not self._stop.is_set():
            self._sample_once()
            self._stop.wait(self._interval)

    def __enter__(self):
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, exc_type, exc, traceback):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=self._interval * 4)
        return False

    def samples(self):
        return list(self._samples)


# --- capture drivers -----------------------------------------------------------


def _write_json(path, value):
    pathlib.Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def _arm_process(arm, app_pid):
    return subprocess.Popen(
        [str(arm), "post", str(app_pid)],
        stdin=subprocess.PIPE,
        text=True,
    )


def _release_arm(arm_process):
    """End the arm, whatever state the run is in.

    Closing stdin is the arm's documented release-and-exit path, so this is what
    guarantees no arrow survives a failure in the driver. It runs from a `finally`,
    so it must not raise over the exception that sent it there: an arm that will
    not exit is killed -- which the arm's own signal handler also turns into a
    key-up -- rather than allowed to replace the run's real error with a timeout.
    """
    if arm_process.stdin is not None:
        try:
            arm_process.stdin.close()
        except OSError:
            pass
    try:
        arm_process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        arm_process.terminate()
        try:
            arm_process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            arm_process.kill()


def drive_bounded_capture(*, arm, app_pid, direction, seconds, profiler_argv,
                          lead_seconds=DEFAULT_LEAD_SECONDS,
                          trail_seconds=DEFAULT_TRAIL_SECONDS,
                          cadence=None, start_profiler=None):
    """Hold one arrow across one profiler run and return what the run can claim.

    Returns `(capture, profiler_status)`. A stimulus the run cannot stand behind --
    a profiler window outside the held key, or one that never exited -- comes back
    as a recorded `contained: false` rather than as an exception, because the
    bundle grader (`terminal_btop_artifacts`) is what turns that into the run's
    verdict, and it can only do so if the reason reaches disk. The key is already
    released by the time either is raised.
    """
    cadence = cadence or stimulus.read_key_repeat_cadence()
    arm_process = _arm_process(arm, app_pid)
    launch = start_profiler or (lambda: subprocess.Popen(list(profiler_argv)))
    try:
        sink = stimulus.ArmSink(arm_process.stdin)
        with stimulus.ArrowStimulus(
            sink, cadence, clock=time.monotonic, sleep=time.sleep
        ) as arrows:
            first_leg = len(arrows.legs())
            try:
                capture = stimulus.run_bounded_capture(
                    arrows,
                    direction,
                    start_profiler=launch,
                    profiler_timeout_seconds=seconds + PROFILER_OVERHEAD_SECONDS,
                    lead_seconds=lead_seconds,
                    trail_seconds=trail_seconds,
                )
            except stimulus.StimulusError as error:
                return (
                    {
                        "direction": direction,
                        "stimulus": arrows.artifact(from_leg=first_leg),
                        "overlap": {"contained": False, "reason": str(error)},
                    },
                    1,
                )
        return capture, capture["profiler"]["exitStatus"]
    finally:
        _release_arm(arm_process)


def drive_loop(*, arm, app_pid, live_path, leg_seconds=LOOP_LEG_SECONDS, cadence=None,
               should_continue=None):
    """Alternate fixed legs until interrupted, publishing the current direction as it goes.

    A loop leg may end in an idle tail, so loop issues no coverage verdict; what it
    owes an attaching agent is the live direction and leg start it would
    otherwise have to guess, so each leg is published before it is held.
    """
    cadence = cadence or stimulus.read_key_repeat_cadence()
    arm_process = _arm_process(arm, app_pid)
    keep_going = should_continue or (lambda: True)
    try:
        sink = stimulus.ArmSink(arm_process.stdin)
        with stimulus.ArrowStimulus(
            sink, cadence, clock=time.monotonic, sleep=time.sleep
        ) as arrows:
            def publish(direction):
                _write_json(
                    live_path,
                    {
                        "workload": WORKLOAD_NAME,
                        "mode": "loop",
                        "direction": direction,
                        "legSeconds": leg_seconds,
                        "legStartedAtSeconds": arrows.now(),
                        "cadence": cadence.artifact(),
                        "coverageVerdict": "none -- loop measures nothing; bracket "
                        "and validate your own profiler window",
                    },
                )

            stimulus.alternate(
                arrows,
                leg_seconds=leg_seconds,
                should_continue=keep_going,
                on_leg=publish,
            )
            return arrows.artifact()
    finally:
        _release_arm(arm_process)


# --- command line --------------------------------------------------------------


def _command_admit(arguments):
    """Decide admission alone, so the cheapest refusal is also the first one.

    Split from `preflight` because preflight compiles two binaries: a mode or
    duration this workload does not offer must be refused before that, not after.
    """
    admit_duration(arguments.mode, arguments.seconds)
    return 0


def _command_preflight(arguments):
    """Prove the host can produce this workload before anything is built or launched."""
    seconds = admit_duration(arguments.mode, arguments.seconds)
    output = pathlib.Path(arguments.output)
    executable = artifacts.resolve_btop_executable()
    version = artifacts.read_btop_version(executable)
    arm = stimulus.compile_stimulus_arm(output)
    permission = stimulus.preflight_input_permission(arm)
    probe = compile_state_probe(output)
    _write_json(
        output / PREFLIGHT,
        {
            "workload": WORKLOAD_NAME,
            "mode": arguments.mode,
            "recordingSeconds": seconds,
            "executablePath": executable,
            "version": version,
            "input": permission,
            "stimulusArm": str(arm),
            "machineStateProbe": str(probe),
        },
    )
    print(str(output / PREFLIGHT))
    return 0


def _command_readiness(arguments):
    readiness = await_readiness(
        executable=arguments.executable,
        app_pid=arguments.app_pid,
        environment={"HOME": arguments.home},
    )
    _write_json(arguments.output, readiness)
    print(
        f"owned btop pid {readiness['process']['pid']} on {readiness['process']['tty']} "
        f"at {readiness['process']['columns']}x{readiness['process']['rows']}"
    )
    return 0


def _command_capture(arguments):
    seconds = admit_duration(arguments.mode, arguments.seconds)
    root = pathlib.Path(arguments.root)
    root.mkdir(parents=True, exist_ok=True)
    sampler = MachineStateSampler(arguments.state_probe)
    capture = None
    try:
        with sampler:
            capture, status = drive_bounded_capture(
                arm=arguments.arm,
                app_pid=arguments.app_pid,
                direction=arguments.direction,
                seconds=seconds,
                profiler_argv=arguments.profiler,
            )
    finally:
        # Written even when the driver failed outright: the plan's rule is that an
        # invalid capture leaves behind everything it did collect, and the samples
        # taken before the failure are how an operator sees whether the host was
        # the reason.
        _write_json(root / artifacts.MACHINE_STATE, sampler.samples())
        if capture is not None:
            _write_json(root / artifacts.STIMULUS_CAPTURE, capture)
    return status


def _command_loop(arguments):
    admit_mode("loop")
    root = pathlib.Path(arguments.root)
    root.mkdir(parents=True, exist_ok=True)
    try:
        drive_loop(arm=arguments.arm, app_pid=arguments.app_pid, live_path=root / LIVE_STIMULUS)
    except KeyboardInterrupt:
        pass
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)

    admit = commands.add_parser("admit", help="accept or refuse a mode and duration")
    admit.add_argument("--mode", required=True)
    admit.add_argument("--seconds", default=None)
    admit.set_defaults(run=_command_admit)

    preflight = commands.add_parser(
        "preflight", help="prove the host can drive the workload before building it"
    )
    preflight.add_argument("--mode", required=True)
    preflight.add_argument("--seconds", default=None)
    preflight.add_argument("--output", required=True, help="where to build and record")
    preflight.set_defaults(run=_command_preflight)

    readiness = commands.add_parser(
        "readiness", help="wait for one owned btop at the canonical PTY geometry"
    )
    readiness.add_argument("--app-pid", type=int, required=True)
    readiness.add_argument("--executable", required=True)
    readiness.add_argument("--home", required=True, help="the run's isolated HOME")
    readiness.add_argument("--output", required=True)
    readiness.set_defaults(run=_command_readiness)

    capture = commands.add_parser(
        "capture", help="hold an arrow across one profiler run and record the overlap"
    )
    capture.add_argument("--mode", required=True)
    capture.add_argument("--seconds", required=True)
    capture.add_argument("--root", required=True, help="the profile bundle directory")
    capture.add_argument("--arm", required=True)
    capture.add_argument("--state-probe", required=True)
    capture.add_argument("--app-pid", type=int, required=True)
    capture.add_argument("--direction", default="down", choices=stimulus.ARROW_DIRECTIONS)
    capture.add_argument("profiler", nargs=argparse.REMAINDER, help="-- profiler argv")
    capture.set_defaults(run=_command_capture)

    loop = commands.add_parser("loop", help="alternate legs until interrupted")
    loop.add_argument("--root", required=True)
    loop.add_argument("--arm", required=True)
    loop.add_argument("--app-pid", type=int, required=True)
    loop.set_defaults(run=_command_loop)

    arguments = parser.parse_args(argv)
    if getattr(arguments, "profiler", None) and arguments.profiler[0] == "--":
        arguments.profiler = arguments.profiler[1:]
    try:
        return arguments.run(arguments)
    except (WorkloadRejected, artifacts.CaptureInvalid, stimulus.StimulusError,
            stimulus.InputPermissionError) as error:
        print(f"{WORKLOAD_NAME}: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
