#!/usr/bin/env python3
"""One question: can only an owned, canonical, profiling-only btop run reach a profiler?

`btop-scroll` is the only workload whose stimulus is a live application, so the
ways it can go wrong are ways no corpus workload can: a decision path could ask
for it, a recording window could be any length at all, a build could burn two
minutes before the host turns out to forbid synthetic input, and the process on
the PTY could be the operator's own btop rather than this run's. Each of those is
a decision, so each is proved here rather than inside a GUI run.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import terminal_btop_workload as WORKLOAD  # noqa: E402

PROFILE_SCRIPT = ROOT / "scripts" / "terminal-benchmark-profile.sh"
HARNESS_SCRIPT = ROOT / "scripts" / "terminal-benchmark.sh"

# A stand-in for the stimulus arm's line protocol: it records what it was asked to
# post and nothing else. Using a real subprocess rather than a stubbed object is
# what makes the release-on-exit path below a real assertion -- the driver closes
# a pipe, and this proves the pipe carried the key-up first.
FAKE_ARM = """#!/usr/bin/env python3
import sys

log = open(sys.argv[2], "a")
for line in sys.stdin:
    log.write(line)
    log.flush()
"""

FAKE_STATE_PROBE = """#!/usr/bin/env python3
print('{"thermalState": "nominal", "lowPowerMode": false}')
"""


def write_executable(directory, name, source):
    path = pathlib.Path(directory) / name
    path.write_text(source)
    path.chmod(0o755)
    return path


class FakeProfiler:
    """A profiler handle that reports whichever recording window a test needs.

    `run_bounded_capture` believes a profiler that reports its own window over the
    harness's clock readings, so this is how a window outside the stimulus is
    produced without depending on scheduling luck.
    """

    def __init__(self, window=None, returncode=0):
        self._window = window
        self.returncode = returncode
        self._polls = 0

    def poll(self):
        self._polls += 1
        return None if self._polls < 3 else self.returncode

    def profiler_window(self):
        return self._window


class AdmissionTests(unittest.TestCase):
    def test_btop_is_offered_to_the_profiling_modes_and_to_nothing_else(self):
        # Intent: `btop-scroll` is admitted to sample, trace, and loop, and refused
        #   by memory profiling and by every other named mode.
        # Why it exists: I1. The workload is an attribution instrument over a live
        #   process list; any path that reaches a verdict, a comparison, or a
        #   memory number would be resting it on a workload with no fixed content.
        for mode in ("sample", "trace", "loop"):
            with self.subTest(mode=mode):
                self.assertEqual(WORKLOAD.admit_mode(mode), mode)
        for mode in ("memory", "quick", "confirm", "calibrate", "measure"):
            with self.subTest(mode=mode):
                with self.assertRaises(WORKLOAD.WorkloadRejected):
                    WORKLOAD.admit_mode(mode)

    def test_bounded_modes_take_one_to_twenty_whole_seconds_and_loop_takes_none(self):
        # Intent: sample and trace require an explicit whole-number duration in
        #   1-20; loop accepts no duration at all.
        # Why it exists: I2. An unbounded or fractional recording is a window the
        #   held-key stimulus cannot promise to contain, and a duration handed to
        #   loop would describe a run that stops only when interrupted.
        for mode in ("sample", "trace"):
            for seconds in ("1", "20", 7):
                with self.subTest(mode=mode, seconds=seconds):
                    self.assertEqual(WORKLOAD.admit_duration(mode, seconds), int(seconds))
            for rejected in (None, "", "0", "21", "1.5", "-3", "ten"):
                with self.subTest(mode=mode, rejected=rejected):
                    with self.assertRaises(WORKLOAD.WorkloadRejected):
                        WORKLOAD.admit_duration(mode, rejected)
        self.assertIsNone(WORKLOAD.admit_duration("loop", None))
        with self.assertRaises(WORKLOAD.WorkloadRejected):
            WORKLOAD.admit_duration("loop", "10")


class ProfilingCommandAdmissionTests(unittest.TestCase):
    """The operator-facing surface, exercised by running the scripts themselves."""

    def run_profile(self, *arguments):
        return subprocess.run(
            [str(PROFILE_SCRIPT), *arguments],
            capture_output=True,
            text=True,
            cwd=ROOT,
        )

    def test_memory_profiling_refuses_the_live_workload(self):
        # Intent: `benchmark-memory btop-scroll` is rejected outright.
        # Why it exists: I1 has to hold at the command an operator actually types,
        #   not only in the admission table. Memory profiling produces a footprint
        #   number, which is a claim this workload may not support.
        result = self.run_profile("memory", "btop-scroll", "swift", "90", "15")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("btop-scroll", result.stderr)

    def test_a_bounded_recording_window_outside_one_to_twenty_is_refused(self):
        # Intent: sample and trace reject a 0-, 21-, or fractional-second window
        #   for `btop-scroll` before anything is built or launched.
        # Why it exists: I2, at the command surface. The generic profiling
        #   duration check accepts any positive whole number, so without a
        #   workload-specific bound a 600-second btop recording would build an
        #   app and launch btop before failing -- or worse, not fail at all.
        for seconds in ("0", "21", "45"):
            with self.subTest(seconds=seconds):
                result = self.run_profile("sample", "btop-scroll", "swift", seconds)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("btop-scroll", result.stderr)

    def test_the_measuring_harness_refuses_the_live_workload(self):
        # Intent: `terminal-benchmark.sh btop-scroll` in its default measuring mode
        #   is rejected.
        # Why it exists: I1's other reachable door. The harness's measure mode is
        #   what every paired comparison collects blocks through, so admitting the
        #   workload there for the profiling modes must not admit it for the
        #   decision-bearing one.
        result = subprocess.run(
            [str(HARNESS_SCRIPT), "btop-scroll", "swift"],
            capture_output=True,
            text=True,
            cwd=ROOT,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("btop-scroll", result.stderr)

    def test_no_calibrated_comparison_can_name_the_workload(self):
        # Intent: the paired comparison ladder neither contains `btop-scroll` nor
        #   accepts it as a selected workload.
        # Why it exists: I1's decision-bearing half. `quick` takes a workload name
        #   straight from the operator, so the rejection has to come from the
        #   ladder's own closed set rather than from documentation.
        import importlib.util

        def load(name, filename):
            spec = importlib.util.spec_from_file_location(
                name, ROOT / "scripts" / filename
            )
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module

        validation = load("terminal_benchmark_validation", "terminal-benchmark-validation.py")
        compare = load("terminal_benchmark_compare", "terminal-benchmark-compare.py")
        self.assertNotIn(WORKLOAD.WORKLOAD_NAME, validation.WORKLOADS)
        self.assertNotIn(WORKLOAD.WORKLOAD_NAME, validation.CANDIDATE_WORKLOADS)
        with self.assertRaises(ValueError):
            compare.resolve_workloads("quick", WORKLOAD.WORKLOAD_NAME)


class PreflightTests(unittest.TestCase):
    def test_a_missing_btop_is_refused_before_anything_is_compiled(self):
        # Intent: preflight with no btop on PATH exits nonzero and leaves its
        #   output directory empty.
        # Why it exists: PO1. The preflight's whole reason to exist is to fail
        #   before a release build and a GUI launch, so "it eventually failed" is
        #   not the property -- "it failed having built nothing" is.
        with tempfile.TemporaryDirectory() as directory:
            empty_path = pathlib.Path(directory) / "bin"
            empty_path.mkdir()
            output = pathlib.Path(directory) / "out"
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "terminal_btop_workload.py"),
                    "preflight",
                    "--mode",
                    "sample",
                    "--seconds",
                    "20",
                    "--output",
                    str(output),
                ],
                capture_output=True,
                text=True,
                env={**os.environ, "PATH": str(empty_path)},
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("btop", result.stderr)
            self.assertFalse(output.exists() and any(output.iterdir()))

    def test_an_inadmissible_mode_is_refused_before_btop_is_even_resolved(self):
        # Intent: preflight rejects `memory` without touching PATH or the compiler.
        # Why it exists: PO1's ordering claim. Admission is cheaper than every
        #   other check, and a host that happens to lack btop must not be told the
        #   mode was the acceptable part.
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "out"
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "terminal_btop_workload.py"),
                    "preflight",
                    "--mode",
                    "memory",
                    "--seconds",
                    "20",
                    "--output",
                    str(output),
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("profiling-only", result.stderr)
            self.assertFalse(output.exists())


class OwnedProcessTests(unittest.TestCase):
    TABLE = (
        "  100     1 ??       /Applications/DanTerm.app/Contents/MacOS/DanTerm\n"
        "  200     1 ??       /run/DanTerm Benchmark.app/Contents/MacOS/DanTerm Benchmark\n"
        "  201   200 ttys004  /run/DanTerm Benchmark.app/Contents/Helpers/PTYSessionBootstrap\n"
        "  202   201 ttys004  /opt/homebrew/bin/btop\n"
        "  300   100 ttys009  /opt/homebrew/bin/btop\n"
    )

    def test_only_a_btop_inside_the_owned_process_tree_is_the_workload(self):
        # Intent: the owned btop is selected by lineage from the benchmark app,
        #   and an identical binary running under another app is not a candidate.
        # Why it exists: I3. The operator very plausibly has their own btop open
        #   while running this; profiling theirs, or tearing it down at cleanup,
        #   is the exact failure `RI2` rejected targeting a user pane to avoid.
        entries = WORKLOAD.parse_process_table(self.TABLE)
        owned = WORKLOAD.select_owned_btop(
            entries, executable="/opt/homebrew/bin/btop", app_pid=200
        )
        self.assertEqual(owned["pid"], 202)
        self.assertEqual(owned["tty"], "ttys004")

    def test_an_ambiguous_or_absent_owned_btop_is_refused(self):
        # Intent: zero owned btop processes and two owned btop processes are both
        #   rejected, rather than one being picked.
        # Why it exists: I3 again. With two candidates nothing on the table says
        #   which one the profiler sampled, so choosing either would put an
        #   unattributable process's behavior into the record as if it were this
        #   workload's.
        entries = WORKLOAD.parse_process_table(self.TABLE)
        with self.assertRaises(WORKLOAD.WorkloadRejected):
            WORKLOAD.select_owned_btop(
                entries, executable="/usr/local/bin/btop", app_pid=200
            )
        doubled = entries + [
            {"pid": 203, "ppid": 201, "tty": "ttys005", "command": "/opt/homebrew/bin/btop"}
        ]
        with self.assertRaises(WORKLOAD.WorkloadRejected):
            WORKLOAD.select_owned_btop(
                doubled, executable="/opt/homebrew/bin/btop", app_pid=200
            )

    def test_readiness_requires_the_live_pty_to_be_canonical(self):
        # Intent: readiness returns the owned process only once the live PTY
        #   reports 179x66, and reports the geometry it saw when it never does.
        # Why it exists: I4. btop lays its process list out from the terminal size
        #   it is given, so a profile taken at another geometry is a different
        #   workload wearing this one's name.
        sizes = iter(["24 80\n", "24 80\n", "66 179\n"])

        def run_command(argv, **_):
            if argv[0] == "ps":
                return subprocess.CompletedProcess(argv, 0, stdout=self.TABLE, stderr="")
            return subprocess.CompletedProcess(argv, 0, stdout=next(sizes), stderr="")

        readiness = WORKLOAD.await_readiness(
            executable="/opt/homebrew/bin/btop",
            app_pid=200,
            environment={"HOME": "/run/home"},
            run_command=run_command,
            monotonic=lambda: 0.0,
            sleep=lambda _: None,
        )
        self.assertEqual(readiness["process"]["pid"], 202)
        self.assertEqual(readiness["process"]["rows"], 66)
        self.assertEqual(readiness["process"]["columns"], 179)
        self.assertEqual(readiness["config"]["source"], "home")

        clock = iter([0.0, 99.0])

        def stuck(argv, **_):
            if argv[0] == "ps":
                return subprocess.CompletedProcess(argv, 0, stdout=self.TABLE, stderr="")
            return subprocess.CompletedProcess(argv, 0, stdout="24 80\n", stderr="")

        with self.assertRaises(WORKLOAD.WorkloadRejected) as rejection:
            WORKLOAD.await_readiness(
                executable="/opt/homebrew/bin/btop",
                app_pid=200,
                environment={"HOME": "/run/home"},
                run_command=stuck,
                monotonic=lambda: next(clock),
                sleep=lambda _: None,
                timeout_seconds=1.0,
            )
        self.assertIn("80x24", str(rejection.exception))


class MachineStateTests(unittest.TestCase):
    def test_a_probe_that_cannot_run_contributes_no_samples(self):
        # Intent: a failing host-state probe yields an empty sample list.
        # Why it exists: the artifact grader rejects a zero-sample interval as
        #   unmeasured, and that only works if a broken probe stays silent. A
        #   nominal placeholder would turn "we could not look" into "the host was
        #   fine", which is the strongest claim from the weakest evidence.
        with tempfile.TemporaryDirectory() as directory:
            good = write_executable(directory, "probe", FAKE_STATE_PROBE)
            with WORKLOAD.MachineStateSampler(good, interval_seconds=0.01) as sampler:
                deadline = time.monotonic() + 10.0
                while not sampler.samples() and time.monotonic() < deadline:
                    time.sleep(0.01)
            self.assertTrue(sampler.samples())
            self.assertEqual(sampler.samples()[0]["thermalState"], "nominal")

            missing = pathlib.Path(directory) / "absent-probe"
            with WORKLOAD.MachineStateSampler(missing, interval_seconds=0.01) as sampler:
                time.sleep(0.2)
            self.assertEqual(sampler.samples(), [])


class CaptureDriverTests(unittest.TestCase):
    def cadence(self):
        return WORKLOAD.stimulus.KeyRepeatCadence(
            initial_delay_seconds=0.01,
            repeat_interval_seconds=0.01,
            initial_key_repeat_ticks=1,
            key_repeat_ticks=1,
            source="test",
        )

    def arm(self, directory):
        log = pathlib.Path(directory) / "arm.log"
        binary = write_executable(directory, "arm", FAKE_ARM)
        # The driver invokes `<arm> post <pid>`, so the pid position doubles as the
        # log path here: the fake needs no argument the real arm does not take.
        return binary, log

    def test_a_contained_profiler_window_is_recorded_as_the_capture(self):
        # Intent: a profiler that ran wholly inside the held key produces a capture
        #   whose overlap is contained and whose exit status is the profiler's.
        # Why it exists: PO2's success case at the driver level -- the seam that
        #   turns the stimulus module's timing rules into an artifact on disk.
        with tempfile.TemporaryDirectory() as directory:
            arm, log = self.arm(directory)
            capture, status = WORKLOAD.drive_bounded_capture(
                arm=arm,
                app_pid=str(log),
                direction="down",
                seconds=1,
                profiler_argv=[],
                lead_seconds=0.02,
                trail_seconds=0.02,
                cadence=self.cadence(),
                start_profiler=FakeProfiler,
            )
            self.assertEqual(status, 0)
            self.assertTrue(capture["overlap"]["contained"])
            self.assertEqual(capture["direction"], "down")
            events = log.read_text().split()
            self.assertEqual(events[0], "press")
            self.assertEqual(log.read_text().splitlines()[-1], "release down")

    def test_a_profiler_window_outside_the_stimulus_is_recorded_not_raised(self):
        # Intent: a profiler whose reported window falls outside the measured
        #   stimulus comes back as `contained: false` with a reason and a nonzero
        #   status -- and the arrow key is still released.
        # Why it exists: I5 plus the plan's preservation rule. The bundle grader
        #   is what issues the verdict, so the reason has to survive to disk; an
        #   exception here would abandon the run before the grader could name why.
        with tempfile.TemporaryDirectory() as directory:
            arm, log = self.arm(directory)
            capture, status = WORKLOAD.drive_bounded_capture(
                arm=arm,
                app_pid=str(log),
                direction="up",
                seconds=1,
                profiler_argv=[],
                lead_seconds=0.02,
                trail_seconds=0.02,
                cadence=self.cadence(),
                start_profiler=lambda: FakeProfiler(window=(0.0, 1.0)),
            )
            self.assertNotEqual(status, 0)
            self.assertFalse(capture["overlap"]["contained"])
            self.assertIn("not contained", capture["overlap"]["reason"])
            self.assertEqual(log.read_text().splitlines()[-1], "release up")

    def test_loop_alternates_directions_and_publishes_the_live_leg(self):
        # Intent: loop holds alternating legs, publishes the direction it is
        #   currently holding, and releases the key when it stops.
        # Why it exists: AR2. Loop issues no verdict, so the live direction and
        #   leg start are the entire contract an attaching agent has to bracket
        #   its own profiler window against.
        with tempfile.TemporaryDirectory() as directory:
            arm, log = self.arm(directory)
            live = pathlib.Path(directory) / "live.json"
            deadline = time.monotonic() + 0.2
            artifact = WORKLOAD.drive_loop(
                arm=arm,
                app_pid=str(log),
                live_path=live,
                leg_seconds=0.05,
                cadence=self.cadence(),
                should_continue=lambda: time.monotonic() < deadline,
            )
            directions = [leg["direction"] for leg in artifact["legs"]]
            self.assertGreaterEqual(len(directions), 2)
            self.assertEqual(directions[0], "down")
            for earlier, later in zip(directions, directions[1:]):
                self.assertNotEqual(earlier, later)
            published = json.loads(live.read_text())
            self.assertEqual(published["direction"], directions[-1])
            self.assertEqual(published["legSeconds"], 0.05)
            self.assertEqual(log.read_text().splitlines()[-1], f"release {directions[-1]}")


if __name__ == "__main__":
    unittest.main()
