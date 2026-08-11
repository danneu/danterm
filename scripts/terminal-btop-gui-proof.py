#!/usr/bin/env python3
"""Prove the live `btop-scroll` diagnostic on a real GUI session, opt-in.

`just test-terminal-btop-gui` runs this. Everything the btop workload decides --
admission, duration bounds, stimulus timing, overlap containment, coverage
subtraction, the grader's verdict -- is proved headlessly in `just test`. What no
hermetic suite can reach is the claim those pieces exist to support: that a fresh
optimized app really does put the resolved btop on a live 179x66 PTY, that a
synthesized arrow really does traverse AppKit into it, that a real profiler
attaches and returns parsed samples over a window the held key contains, that
losing the foreground really does invalidate the run, that loop really does turn
around, and that teardown ends this run's processes without leaving a key down or
touching anyone else's btop. Each needs a logged-in session, an installed btop,
and permission to synthesize input, so all of it lives here.

The judgments are separated from the driving on purpose: `judge_*` are pure
functions over artifacts, proved in
`scripts/tests/terminal_btop_gui_proof_test.py`, so an opt-in proof cannot go
green on a broken rule that only a live run would exercise. This file's own job
is only to produce the runs and collect what they left behind.

Nothing here is decision-bearing. It proves the instrument works; it never
reports a performance number.
"""
import argparse
import contextlib
import fcntl
import json
import os
import pathlib
import pty
import signal
import struct
import subprocess
import sys
import termios
import threading
import time


ROOT = pathlib.Path(__file__).resolve().parents[1]
PROFILE_SCRIPT = ROOT / "scripts" / "terminal-benchmark-profile.sh"
PROFILE_ROOTS = ROOT / ".build" / "terminal-benchmark-profiles"
ARM_NAME = "terminal-btop-stimulus-arm"
# The harness copies this into the bundle immediately before the profiler attaches,
# so its arrival is the moment the interval coverage is measured over opens.
ACTIVITY_BEFORE = "activity-before.json"
FOREGROUND_STEAL_POLL_SECONDS = 0.1
# I4's geometry, in the `{columns}x{rows}` spelling the failures below print.
CANONICAL_ROWS = 66
CANONICAL_COLUMNS = 179
# Long enough for two legs plus the app build and btop readiness that precede
# them; the run is interrupted as soon as the second leg publishes.
LOOP_TIMEOUT_SECONDS = 420.0
LOOP_POLL_SECONDS = 0.2


# --- judgments -----------------------------------------------------------------


def _section(identity, *path):
    """Walk into an identity, returning `None` for anything absent along the way.

    Absence is answered with `None` rather than `{}` so every caller below has to
    distinguish "the run did not measure this" from "it measured nothing" -- the
    same rule the grader itself keeps.
    """
    value = identity
    for key in path:
        if not isinstance(value, dict) or key not in value:
            return None
        value = value[key]
    return value


def judge_bounded_capture(identity, *, mode, status):
    """Grade one live bounded capture against everything PO4 asks it to prove.

    Deliberately re-reads the coverage counts rather than resting on the grader's
    own `capture.valid`: both come from `terminal_btop_artifacts`, so a gate that
    stopped firing would take the verdict with it and nothing would notice.
    """
    failures = []
    if status != 0:
        failures.append(f"the bounded {mode} capture exited {status}")
    if identity is None:
        failures.append(f"the {mode} run wrote no graded identity to read")
        return failures

    capture = _section(identity, "capture") or {}
    if capture.get("valid") is not True:
        for reason in capture.get("invalidReasons") or ["no reason recorded"]:
            failures.append(f"the {mode} capture was graded invalid -- {reason}")
    if capture.get("mode") != mode:
        failures.append(f"the graded identity reports mode {capture.get('mode')!r}, not {mode!r}")

    topology = _section(identity, "coverage", "damageTopology")
    if topology is None:
        failures.append("the run measured no damage topology across the profiled window")
    elif not topology.get("sampleCount", 0) > 0:
        failures.append(
            f"the profiled window carries {topology.get('sampleCount')} damage-topology "
            "samples, so the app drew nothing in it"
        )

    presentation = _section(identity, "coverage", "presentation")
    if presentation is None:
        failures.append(
            "the run measured no foreground/presentation coverage, so nothing proves the "
            "app was frontmost and on screen while profiled"
        )
    else:
        if not presentation.get("sampleCount", 0) > 0:
            failures.append("no foreground/presentation sample falls inside the profiled window")
        for key in ("lapsedForegroundSamples", "lapsedPresentedSamples"):
            if presentation.get(key):
                failures.append(f"the profiled window recorded {presentation[key]} {key}")

    profiler_samples = _section(identity, "coverage", "profilerSamples")
    if profiler_samples is None:
        failures.append(f"the {mode} run produced no parsed profiler samples to report")
    elif not profiler_samples.get("samples", 0) > 0:
        failures.append(f"the {mode} report parsed {profiler_samples.get('samples')} samples")

    overlap = _section(identity, "overlap") or {}
    if overlap.get("contained") is not True:
        failures.append(
            "the profiler window was not contained by the held key: "
            + str(overlap.get("reason", "no containment recorded"))
        )

    process = _section(identity, "btop", "process")
    if process is None:
        failures.append("the run recorded no owned btop process, so its live PTY is unknown")
    elif (process.get("rows"), process.get("columns")) != (CANONICAL_ROWS, CANONICAL_COLUMNS):
        failures.append(
            f"the owned btop PTY was {process.get('columns')}x{process.get('rows')}, not the "
            f"canonical {CANONICAL_COLUMNS}x{CANONICAL_ROWS}"
        )

    permission = _section(identity, "btop", "input")
    if permission is None or permission.get("granted") is not True:
        failures.append("the run recorded no granted input permission for the arrow stimulus")
    elif not permission.get("mechanism"):
        failures.append("the run recorded no input mechanism for the arrow stimulus")

    if mode == "trace":
        export = _section(identity, "traceExport")
        if export is None or export.get("hasTimeProfile") is not True:
            schemas = (export or {}).get("schemas") or []
            failures.append(
                "the Time Profiler recording exported no time-profile table; schemas: "
                + (", ".join(schemas) or "none")
            )
    return failures


def foreground_steal_is_due(root):
    """Whether the run has opened the interval its coverage will be measured over.

    The spoiled phase has exactly one window in which taking the foreground away
    means anything: between the harness's two activity snapshots. Earlier -- during
    the release build, the launch, or the wait for btop -- the app is not being
    measured, so the theft leaves no trace and the capture comes back valid.
    """
    return root is not None and (pathlib.Path(root) / ACTIVITY_BEFORE).is_file()


def judge_foreground_lapse(identity, *, status):
    """Grade the deliberately-spoiled run: losing the foreground must reject it, loudly.

    Both halves matter and neither implies the other. The exit status is what a
    script reads, and the preserved reason is what an operator reads; a run that
    fails silently or fails without saying why is a different defect each time.
    """
    failures = []
    if status == 0:
        failures.append(
            "a capture that lost the foreground exited 0, so a script driving the "
            "diagnostic could not tell it apart from a valid run"
        )
    if identity is None:
        failures.append(
            "the rejected run preserved no identity, so its reason for being rejected "
            "did not survive to disk"
        )
        return failures

    capture = _section(identity, "capture") or {}
    if capture.get("valid") is not False:
        failures.append(
            "the capture stayed valid through a stolen foreground, so the presentation "
            "gate did not fire"
        )
    reasons = capture.get("invalidReasons") or []
    if not any("frontmost" in reason for reason in reasons):
        failures.append(
            "no invalidation reason names a `frontmost` lapse, so the run was rejected "
            "for some other reason than the one being proved; reasons recorded: "
            + ("; ".join(reasons) or "none")
        )
    return failures


def judge_loop_publications(publications):
    """Grade loop's live state file: it must turn around, and never claim a verdict."""
    failures = []
    if len(publications) < 2:
        failures.append(
            f"loop published {len(publications)} leg(s); at least two are needed to prove "
            "it alternates direction"
        )
    for index, publication in enumerate(publications):
        if not publication.get("coverageVerdict"):
            failures.append(f"loop leg {index} published no coverage verdict disclaimer")
    for index in range(1, len(publications)):
        previous = publications[index - 1].get("direction")
        current = publications[index].get("direction")
        if previous == current:
            failures.append(
                f"loop published `{current}` twice in a row at legs {index - 1} and {index}"
            )
    return failures


def judge_stimulus_release(identity):
    """Require every recorded leg to carry the key-up that ended it (I5)."""
    legs = _section(identity, "stimulus", "legs")
    if not legs:
        return ["the capture recorded no stimulus leg, so no key-down is accounted for"]
    return [
        f"stimulus leg {index} ({leg.get('direction')}) recorded no release time"
        for index, leg in enumerate(legs)
        if leg.get("releasedAtSeconds") is None
    ]


def judge_teardown(*, surviving_owned_pids, stray_arm_pids, bystander_alive):
    """Require the run to have ended its own processes and nobody else's (I3)."""
    failures = [
        f"benchmark process {pid} survived teardown" for pid in sorted(surviving_owned_pids)
    ]
    failures.extend(
        f"stimulus arm {pid} is still running, so an arrow key may still be held down"
        for pid in sorted(stray_arm_pids)
    )
    if not bystander_alive:
        failures.append(
            "the unrelated bystander btop was terminated by the run, so teardown reached "
            "outside the processes it owns"
        )
    return failures


# --- live drivers ---------------------------------------------------------------


def _read_json(path):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except (OSError, json.JSONDecodeError):
        return None


def _process_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def stray_arm_pids():
    """Every stimulus arm still running anywhere on the host.

    Matched by executable path, not by owner: the failure this guards against is
    an arm the driver lost track of, which by definition is not in any list the
    driver kept.
    """
    result = subprocess.run(
        ["ps", "-Ao", "pid=,comm="], capture_output=True, text=True, check=False
    )
    pids = []
    for line in result.stdout.splitlines():
        fields = line.split(None, 1)
        if len(fields) == 2 and fields[0].isdigit() and fields[1].strip().endswith(ARM_NAME):
            pids.append(int(fields[0]))
    return pids


def _existing_profile_roots():
    if not PROFILE_ROOTS.is_dir():
        return set()
    return {path for path in PROFILE_ROOTS.iterdir() if path.is_dir()}


def _new_profile_root(before):
    created = sorted(_existing_profile_roots() - before, key=lambda path: path.name)
    return created[-1] if created else None


def _drain(descriptor):
    """Read and discard a PTY until it closes, so the process on it never blocks."""
    while True:
        try:
            if not os.read(descriptor, 65536):
                return
        except OSError:
            return


@contextlib.contextmanager
def bystander_btop(executable):
    """Run a btop this invocation must never select, own, or signal.

    It stands in for the operator's own btop: same executable path, outside the
    benchmark app's process tree. Ownership is decided by lineage, so this is the
    process a selection bug would reach for first.
    """
    controller, follower = pty.openpty()
    # btop exits immediately on a zero-sized terminal, and it fills a PTY buffer
    # in seconds -- so the bystander needs a real winsize and a reader, or it dies
    # on its own and the teardown check below reports a killing this run never did.
    fcntl.ioctl(follower, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    process = subprocess.Popen(
        [executable], stdin=follower, stdout=follower, stderr=follower, start_new_session=True
    )
    os.close(follower)
    drain = threading.Thread(target=_drain, args=(controller,), daemon=True)
    drain.start()
    try:
        yield process
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
        os.close(controller)


def _run_profile(mode, *, seconds, template, output, label, on_started=None):
    """Run one profiling invocation end to end and return its root, identity, and status."""
    before = _existing_profile_roots()
    argv = [str(PROFILE_SCRIPT), mode, "btop-scroll", str(seconds)]
    if mode == "trace":
        argv.append(template)
    log_path = output / f"{label}.log"
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(argv, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, text=True)
        if on_started is not None:
            on_started(process, before)
        status = process.wait()
    root = _new_profile_root(before)
    identity = _read_json(root / "identity.json") if root is not None else None
    return root, identity, status


def _owned_pids(identity):
    pids = []
    for path in (("pid",), ("btop", "process", "pid")):
        pid = _section(identity, *path)
        if isinstance(pid, int):
            pids.append(pid)
    return pids


def _steal_foreground_once_measured(process, before_roots, stop):
    """Watch for the measured interval to open, then put another app frontmost.

    Polls for the snapshot rather than sleeping a fixed amount, because the delay
    between launching the harness and its profiler attaching is a release build, an
    app launch, and a wait for btop -- minutes on a cold tree, seconds on a warm
    one. It gives up when the harness exits so a run that never got that far ends
    with the harness's own failure rather than this thread's.
    """
    while not stop.is_set() and process.poll() is None:
        if foreground_steal_is_due(_new_profile_root(before_roots)):
            subprocess.run(
                ["osascript", "-e", 'tell application "Finder" to activate'],
                capture_output=True,
                check=False,
            )
            return
        stop.wait(FOREGROUND_STEAL_POLL_SECONDS)


def prove_bounded(mode, *, seconds, template, output, steal_foreground=False):
    """Drive one bounded capture, optionally spoiling it, and judge what it produced."""
    stop = threading.Event()
    stealer = None
    if steal_foreground:
        def on_started(process, before_roots):
            nonlocal stealer
            stealer = threading.Thread(
                target=_steal_foreground_once_measured,
                args=(process, before_roots, stop),
                daemon=True,
            )
            stealer.start()
    else:
        on_started = None

    label = f"{mode}-foreground-lapse" if steal_foreground else mode
    try:
        root, identity, status = _run_profile(
            mode, seconds=seconds, template=template, output=output, label=label,
            on_started=on_started,
        )
    finally:
        stop.set()
        if stealer is not None:
            stealer.join(timeout=10)

    if steal_foreground:
        failures = judge_foreground_lapse(identity, status=status)
    else:
        failures = judge_bounded_capture(identity, mode=mode, status=status)
    # A rejected capture still had a key held across it, so the release is
    # required either way -- I5 admits no exception for a run that failed.
    if identity is not None:
        failures.extend(judge_stimulus_release(identity))
    return {
        "phase": label,
        "artifactRoot": str(root) if root else None,
        "exitStatus": status,
        "ownedPids": _owned_pids(identity),
        "failures": [f"{label}: {failure}" for failure in failures],
    }


def prove_loop(output):
    """Run loop until it has published two legs, then interrupt it and judge the legs."""
    before = _existing_profile_roots()
    log_path = output / "loop.log"
    publications = []
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            [str(PROFILE_SCRIPT), "loop", "btop-scroll"],
            cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, text=True, start_new_session=True,
        )
        deadline = time.monotonic() + LOOP_TIMEOUT_SECONDS
        try:
            while time.monotonic() < deadline and len(publications) < 2:
                if process.poll() is not None:
                    break
                root = _new_profile_root(before)
                published = (
                    _read_json(root / "btop-stimulus-live.json") if root is not None else None
                )
                if published is not None:
                    key = (published.get("direction"), published.get("legStartedAtSeconds"))
                    if not publications or key != (
                        publications[-1].get("direction"),
                        publications[-1].get("legStartedAtSeconds"),
                    ):
                        publications.append(published)
                time.sleep(LOOP_POLL_SECONDS)
        finally:
            # Ctrl-C is loop's documented stop, and the whole group is what an
            # interactive Ctrl-C would reach: the harness that owns the app is a
            # sibling of the stimulus driver, not its child.
            if process.poll() is None:
                os.killpg(os.getpgid(process.pid), signal.SIGINT)
            try:
                process.wait(timeout=120)
            except subprocess.TimeoutExpired:
                os.killpg(os.getpgid(process.pid), signal.SIGKILL)
                process.wait(timeout=30)

    root = _new_profile_root(before)
    identity = _read_json(root / "identity.json") if root is not None else None
    failures = judge_loop_publications(publications)
    return {
        "phase": "loop",
        "artifactRoot": str(root) if root else None,
        "publishedLegs": publications,
        "ownedPids": _owned_pids(identity),
        "failures": [f"loop: {failure}" for failure in failures],
    }


def run_proof(*, seconds, template, output, phases):
    """Drive every requested phase against one bystander and judge the whole run."""
    output.mkdir(parents=True, exist_ok=True)
    executable = subprocess.run(
        ["/usr/bin/which", "btop"], capture_output=True, text=True, check=False
    ).stdout.strip()
    if not executable:
        return ["btop is not on PATH, so there is nothing for the diagnostic to profile"], []

    results = []
    with bystander_btop(executable) as bystander:
        for phase in phases:
            if phase == "loop":
                results.append(prove_loop(output))
            elif phase == "foreground-lapse":
                results.append(
                    prove_bounded("sample", seconds=seconds, template=template, output=output,
                                  steal_foreground=True)
                )
            else:
                results.append(
                    prove_bounded(phase, seconds=seconds, template=template, output=output)
                )
        # Ask who is still alive only after the harnesses have had their teardown.
        time.sleep(3)
        owned = [pid for result in results for pid in result["ownedPids"]]
        teardown = judge_teardown(
            surviving_owned_pids=[pid for pid in owned if _process_alive(pid)],
            stray_arm_pids=stray_arm_pids(),
            bystander_alive=bystander.poll() is None,
        )

    failures = [failure for result in results for failure in result["failures"]]
    failures.extend(f"teardown: {failure}" for failure in teardown)
    return failures, results


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "phases",
        nargs="*",
        default=None,
        help="phases to prove; defaults to all of sample, trace, foreground-lapse, loop",
    )
    parser.add_argument(
        "--seconds", type=int, default=10, help="recording window for each bounded capture"
    )
    parser.add_argument("--template", default="Time Profiler")
    parser.add_argument(
        "--output", type=pathlib.Path, default=ROOT / ".build" / "terminal-btop-gui-proof"
    )
    arguments = parser.parse_args(argv)
    known = ("sample", "trace", "foreground-lapse", "loop")
    phases = tuple(arguments.phases or known)
    unknown = [phase for phase in phases if phase not in known]
    if unknown:
        print(f"unknown phases: {', '.join(unknown)}", file=sys.stderr)
        return 2

    failures, results = run_proof(
        seconds=arguments.seconds,
        template=arguments.template,
        output=arguments.output,
        phases=phases,
    )
    report = {
        "schemaVersion": 1,
        "decisionEligible": False,
        "historyEligible": False,
        "phases": list(phases),
        "recordingSeconds": arguments.seconds,
        "results": results,
        "failures": failures,
    }
    arguments.output.mkdir(parents=True, exist_ok=True)
    (arguments.output / "btop-gui-proof.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    if failures:
        print(f"live btop diagnostic proof FAILED; evidence: {arguments.output}")
        for failure in failures:
            print(f"  {failure}")
        return 1
    print(f"live btop diagnostic proof: ok; evidence: {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
