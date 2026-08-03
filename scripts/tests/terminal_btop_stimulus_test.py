#!/usr/bin/env python3
"""One question: does the held-arrow stimulus stay attributable to a profiler window?

The live btop diagnostic is only worth reading if the arrow input it profiles
provably ran for the whole recording: pressed before the profiler attached,
still held when it detached, released on every exit, and repeating at a cadence
the run recorded rather than assumed. Those are timing facts, so they are proved
here against an injected clock and injected profiler boundaries instead of
inside a GUI run where a failure is indistinguishable from a flaky host.
"""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import terminal_btop_stimulus as STIMULUS  # noqa: E402


class ManualClock:
    """A monotonic clock the test advances, so cadence is asserted and never waited on.

    Time is held in whole nanoseconds for two reasons: repeat counts then come
    out the same on every run instead of depending on which side of a due time
    float drift lands, and a sleep always advances, so a wait whose remaining
    duration rounds to nothing cannot spin forever.
    """

    def __init__(self, start=1000.0):
        self._nanoseconds = round(start * 1_000_000_000)

    def now(self):
        return self._nanoseconds / 1_000_000_000

    def sleep(self, duration):
        self._nanoseconds += max(1, round(duration * 1_000_000_000))


class RecordingSink:
    """Captures the exact key-event sequence the stimulus asked the arm to post."""

    def __init__(self, clock=None):
        self.events = []
        self._clock = clock

    def _record(self, kind, direction):
        stamp = None if self._clock is None else self._clock.now()
        self.events.append((kind, direction) if stamp is None else (kind, direction, stamp))

    def press(self, direction):
        self._record("press", direction)

    def repeat(self, direction):
        self._record("repeat", direction)

    def release(self, direction):
        self._record("release", direction)


class FakeProfiler:
    """A profiler handle that finishes after a fixed run and can report its own window."""

    def __init__(self, clock, run_seconds, reported_window=None):
        self._clock = clock
        self._deadline = None
        self._run_seconds = run_seconds
        self._reported_window = reported_window
        self.returncode = None

    def start(self):
        self._deadline = self._clock.now() + self._run_seconds
        return self

    def poll(self):
        if self._clock.now() >= self._deadline:
            self.returncode = 0
            return 0
        return None

    def profiler_window(self):
        return self._reported_window


# Exact binary fractions, so a due time is never one float ulp away from the
# comparison that decides whether its repeat fired.
CADENCE = STIMULUS.KeyRepeatCadence(
    initial_delay_seconds=0.25,
    repeat_interval_seconds=0.0625,
    initial_key_repeat_ticks=15,
    key_repeat_ticks=3,
    source="host",
)


def make_stimulus(clock, sink, cadence=CADENCE):
    return STIMULUS.ArrowStimulus(sink, cadence, clock=clock.now, sleep=clock.sleep)


class KeyRepeatCadenceTests(unittest.TestCase):
    def test_host_repeat_ticks_convert_to_seconds(self):
        # Intent: the cadence comes from the host's own `defaults` values, converted
        #   through the 60 Hz tick the preference is stored in.
        # Why it exists: AR1 accepts that hosts differ, which is only tolerable if
        #   each run records the cadence it actually used; a hardcoded interval
        #   would make two machines' artifacts silently incomparable.
        # Scenario: spec-first -- an operator whose key repeat is set fast.
        def run_command(command, **kwargs):
            values = {"KeyRepeat": "2\n", "InitialKeyRepeat": "15\n"}
            return subprocess.CompletedProcess(command, 0, stdout=values[command[-1]])

        cadence = STIMULUS.read_key_repeat_cadence(run_command=run_command)
        self.assertEqual(cadence.source, "host")
        self.assertEqual(cadence.key_repeat_ticks, 2)
        self.assertEqual(cadence.initial_key_repeat_ticks, 15)
        self.assertAlmostEqual(cadence.repeat_interval_seconds, 2 / 60)
        self.assertAlmostEqual(cadence.initial_delay_seconds, 15 / 60)

    def test_unset_preferences_fall_back_to_recorded_system_defaults(self):
        # Intent: a host that never moved the Key Repeat sliders still yields a
        #   cadence, labelled as the system default rather than as a host setting.
        # Why it exists: `defaults read -g KeyRepeat` exits nonzero when unset. If
        #   that aborted the run, the diagnostic would be unavailable on a stock
        #   machine; if it silently reported "host", the identity would claim a
        #   measurement it never made.
        # Scenario: spec-first -- a freshly installed macOS host.
        def run_command(command, **kwargs):
            raise subprocess.CalledProcessError(1, command)

        cadence = STIMULUS.read_key_repeat_cadence(run_command=run_command)
        self.assertEqual(cadence.source, "system-default")
        self.assertEqual(cadence.key_repeat_ticks, STIMULUS.SYSTEM_DEFAULT_KEY_REPEAT_TICKS)
        self.assertEqual(
            cadence.initial_key_repeat_ticks,
            STIMULUS.SYSTEM_DEFAULT_INITIAL_KEY_REPEAT_TICKS,
        )

    def test_a_zero_key_repeat_setting_clamps_to_one_tick(self):
        # Intent: a host with `KeyRepeat` set to 0 still produces a positive repeat
        #   interval, and the artifact says the value was clamped.
        # Why it exists: 0 is a settable value, and a zero interval makes the repeat
        #   train a loop whose next due time never advances -- a hang holding an
        #   arrow key down, which outlives the run in a live GUI session.
        # Scenario: spec-first -- an operator who set the fastest possible repeat.
        def run_command(command, **kwargs):
            values = {"KeyRepeat": "0\n", "InitialKeyRepeat": "10\n"}
            return subprocess.CompletedProcess(command, 0, stdout=values[command[-1]])

        cadence = STIMULUS.read_key_repeat_cadence(run_command=run_command)
        self.assertEqual(cadence.key_repeat_ticks, 0)
        self.assertAlmostEqual(
            cadence.repeat_interval_seconds, STIMULUS.MINIMUM_REPEAT_INTERVAL_SECONDS
        )
        self.assertTrue(cadence.artifact()["clampedToMinimumInterval"])

    def test_a_non_positive_repeat_interval_cannot_be_constructed(self):
        with self.assertRaises(ValueError):
            STIMULUS.KeyRepeatCadence(
                initial_delay_seconds=0.25,
                repeat_interval_seconds=0.0,
                initial_key_repeat_ticks=15,
                key_repeat_ticks=0,
                source="host",
            )

    def test_cadence_artifact_names_both_the_ticks_and_the_seconds(self):
        artifact = CADENCE.artifact()
        self.assertEqual(artifact["source"], "host")
        self.assertEqual(artifact["keyRepeatTicks"], 3)
        self.assertEqual(artifact["initialKeyRepeatTicks"], 15)
        self.assertAlmostEqual(artifact["repeatIntervalSeconds"], 0.0625)
        self.assertAlmostEqual(artifact["initialDelaySeconds"], 0.25)


class ArrowStimulusTests(unittest.TestCase):
    def test_a_held_key_repeats_at_the_host_cadence_after_the_initial_delay(self):
        # Intent: holding one arrow emits a single press, then repeats spaced by the
        #   host cadence, the first only after the host's initial delay.
        # Why it exists: a synthetic CGEvent key-down does not auto-repeat the way
        #   real HID input does, so the stimulus has to reproduce the repeat train
        #   itself. Emitting it at the wrong spacing would exercise a scroll rate no
        #   user can produce, which is the one thing this workload exists to avoid.
        # Scenario: spec-first -- the user holding Down in btop's process list.
        clock = ManualClock(start=0.0)
        sink = RecordingSink()
        stimulus = make_stimulus(clock, sink)
        stimulus.hold("down", 0.5)
        stimulus.release()

        self.assertEqual(sink.events[0], ("press", "down"))
        self.assertEqual(sink.events[-1], ("release", "down"))
        repeats = [event for event in sink.events if event[0] == "repeat"]
        # 0.25 s initial delay, then 0.0625 s apart: due at .25 .3125 .375 .4375 .5
        self.assertEqual(len(repeats), 5)

    def test_a_stalled_driver_resyncs_instead_of_bursting_the_repeats_it_missed(self):
        # Intent: after a long gap, the next pump emits one repeat and schedules the
        #   following one a full interval from now -- it does not replay the backlog.
        # Why it exists: AR1 says this workload reproduces local held-key behavior,
        #   and a real held key does not catch up after the system deschedules the
        #   driver. Bursting 150 queued repeats would scroll btop at a rate no user
        #   can produce and attribute the resulting draws to a cadence the run
        #   claims it used.
        # Scenario: spec-first -- the driver loses the CPU for a second mid-capture.
        clock = ManualClock(start=0.0)
        sink = RecordingSink()
        stimulus = make_stimulus(clock, sink)
        stimulus.press("down")
        clock.sleep(5.0)
        self.assertEqual(stimulus.pump(), 1)
        self.assertEqual(stimulus.pump(), 0)
        stimulus.release()

        self.assertEqual([event[0] for event in sink.events].count("repeat"), 1)
        self.assertEqual(stimulus.legs()[0]["resyncCount"], 1)

    def test_changing_direction_releases_the_held_key_before_pressing_the_next(self):
        # Intent: a direction change emits release(down) strictly before press(up).
        # Why it exists: I5 requires every transition to release the active key.
        #   Posting the second key-down first leaves both arrows down as far as the
        #   app is concerned, which scrolls in a direction no leg claims and
        #   corrupts the topology the capture attributes to that leg.
        # Scenario: spec-first -- loop mode turning around at a leg boundary.
        clock = ManualClock()
        sink = RecordingSink()
        stimulus = make_stimulus(clock, sink)
        stimulus.press("down")
        stimulus.press("up")
        stimulus.release()

        kinds = [(event[0], event[1]) for event in sink.events]
        self.assertEqual(
            kinds, [("press", "down"), ("release", "down"), ("press", "up"), ("release", "up")]
        )

    def test_pressing_the_already_held_direction_does_not_restart_the_leg(self):
        clock = ManualClock()
        sink = RecordingSink()
        stimulus = make_stimulus(clock, sink)
        stimulus.press("down")
        stimulus.press("down")
        stimulus.release()
        self.assertEqual(
            [(event[0], event[1]) for event in sink.events],
            [("press", "down"), ("release", "down")],
        )

    def test_the_active_key_is_released_when_the_body_raises(self):
        # Intent: leaving the stimulus by any path -- including an exception -- posts
        #   the key-up for whatever was held.
        # Why it exists: I5's "every exit releases the active key". A stimulus that
        #   dies holding Down leaves the key stuck down in a live GUI session, which
        #   outlives the run and silently poisons whatever the operator does next.
        # Scenario: spec-first -- the profiler subprocess fails mid-capture.
        clock = ManualClock()
        sink = RecordingSink()
        with self.assertRaises(RuntimeError):
            with make_stimulus(clock, sink) as stimulus:
                stimulus.press("down")
                raise RuntimeError("profiler died")
        self.assertEqual(sink.events[-1], ("release", "down"))

    def test_a_release_that_cannot_be_posted_does_not_hide_the_original_failure(self):
        # Intent: when the body raised and the key-up then fails too, the body's
        #   exception is what escapes -- and the leg is still recorded.
        # Why it exists: the arm dying is the usual reason a release fails, so the
        #   release error is a symptom of the exception already in flight. Letting
        #   it win would point every future reader at the wrong cause, and dropping
        #   the leg would erase the measured window that explains the run.
        # Scenario: spec-first -- the stimulus arm exits mid-capture, so the next
        #   write hits a closed pipe.
        class BrokenSink(RecordingSink):
            def release(self, direction):
                raise BrokenPipeError("arm is gone")

        clock = ManualClock()
        sink = BrokenSink()
        with self.assertRaises(RuntimeError) as raised:
            with make_stimulus(clock, sink) as stimulus:
                stimulus.press("down")
                raise RuntimeError("profiler died")
        self.assertEqual(str(raised.exception), "profiler died")
        self.assertEqual(len(stimulus.legs()), 1)

    def test_a_release_failure_on_a_clean_exit_is_reported(self):
        class BrokenSink(RecordingSink):
            def release(self, direction):
                raise BrokenPipeError("arm is gone")

        clock = ManualClock()
        with self.assertRaises(BrokenPipeError):
            with make_stimulus(clock, BrokenSink()) as stimulus:
                stimulus.press("down")

    def test_releasing_twice_posts_one_key_up(self):
        clock = ManualClock()
        sink = RecordingSink()
        with make_stimulus(clock, sink) as stimulus:
            stimulus.press("down")
            stimulus.release()
            stimulus.release()
        self.assertEqual([event[0] for event in sink.events].count("release"), 1)

    def test_each_leg_records_its_measured_press_and_release_times(self):
        # Intent: every leg carries the clock readings it was pressed and released
        #   at, plus the repeats it emitted.
        # Why it exists: I7 asks the run to explain itself; the overlap check in
        #   `validate_profiler_overlap` is only meaningful if the stimulus window it
        #   compares against was measured rather than assumed from the requested
        #   duration.
        # Scenario: spec-first -- reading the identity of a finished capture.
        clock = ManualClock()
        sink = RecordingSink()
        with make_stimulus(clock, sink) as stimulus:
            stimulus.hold("down", 1.0)
            stimulus.hold("up", 1.0)

        legs = stimulus.legs()
        self.assertEqual([leg["direction"] for leg in legs], ["down", "up"])
        self.assertAlmostEqual(legs[0]["pressedAtSeconds"], 1000.0)
        self.assertAlmostEqual(legs[1]["releasedAtSeconds"], 1002.0)
        self.assertGreater(legs[0]["repeatCount"], 0)
        self.assertEqual(stimulus.measured_window(), (1000.0, 1002.0))

    def test_the_measured_window_is_unavailable_while_a_key_is_still_held(self):
        clock = ManualClock()
        stimulus = make_stimulus(clock, RecordingSink())
        stimulus.press("down")
        with self.assertRaises(STIMULUS.StimulusError):
            stimulus.measured_window()

    def test_a_loop_alternates_direction_on_every_leg_boundary(self):
        # Intent: loop mode alternates Down and Up in fixed legs and stops only when
        #   the caller's continuation predicate goes false.
        # Why it exists: AR2 accepts an idle tail at the end of a leg, but not a
        #   direction that never turns around -- a one-way loop parks btop at the end
        #   of its process list and profiles an idle window.
        # Scenario: spec-first -- `just benchmark-loop btop-scroll` until interrupted.
        clock = ManualClock()
        sink = RecordingSink()
        legs_run = []
        with make_stimulus(clock, sink) as stimulus:
            STIMULUS.alternate(
                stimulus,
                leg_seconds=10.0,
                should_continue=lambda: len(legs_run) < 3,
                on_leg=legs_run.append,
            )
        self.assertEqual(legs_run, ["down", "up", "down"])
        self.assertEqual([leg["direction"] for leg in stimulus.legs()], ["down", "up", "down"])


class ProfilerOverlapTests(unittest.TestCase):
    def test_a_contained_profiler_window_reports_its_lead_and_trail(self):
        overlap = STIMULUS.validate_profiler_overlap((100.0, 130.0), (102.0, 122.0))
        self.assertTrue(overlap["contained"])
        self.assertAlmostEqual(overlap["leadSeconds"], 2.0)
        self.assertAlmostEqual(overlap["trailSeconds"], 8.0)

    def test_a_profiler_window_starting_before_the_stimulus_is_rejected(self):
        # Intent: recording that began before the first key-down invalidates the
        #   capture.
        # Why it exists: I5 requires the profiler window to lie wholly inside the
        #   measured stimulus lifetime. Samples taken before any arrow was pressed
        #   are idle-window samples, and averaging them into the report understates
        #   exactly the cost the diagnostic exists to attribute.
        # Scenario: spec-first -- a profiler that attached faster than the stimulus
        #   could reach its first press.
        with self.assertRaises(STIMULUS.StimulusOverlapError):
            STIMULUS.validate_profiler_overlap((100.0, 130.0), (99.5, 120.0))

    def test_a_profiler_window_ending_after_the_release_is_rejected(self):
        with self.assertRaises(STIMULUS.StimulusOverlapError):
            STIMULUS.validate_profiler_overlap((100.0, 130.0), (101.0, 130.5))

    def test_an_inverted_profiler_window_is_rejected(self):
        with self.assertRaises(STIMULUS.StimulusOverlapError):
            STIMULUS.validate_profiler_overlap((100.0, 130.0), (120.0, 110.0))


class BoundedCaptureTests(unittest.TestCase):
    def test_the_stimulus_brackets_the_whole_profiler_run(self):
        # Intent: a bounded capture presses first, keeps repeating for the profiler's
        #   entire run, and releases only afterwards -- and says so with measured
        #   times.
        # Why it exists: this is the composed shape I5 names, and the one a caller
        #   cannot get right by hand: starting the profiler first, or releasing at
        #   the profiler's time limit rather than after it exits, both produce a
        #   report whose edges profile an unstimulated window.
        # Scenario: spec-first -- `just benchmark-sample btop-scroll 20`.
        clock = ManualClock()
        sink = RecordingSink(clock)
        profiler = FakeProfiler(clock, run_seconds=20.0)
        with make_stimulus(clock, sink) as stimulus:
            record = STIMULUS.run_bounded_capture(
                stimulus,
                "down",
                start_profiler=profiler.start,
                profiler_timeout_seconds=60.0,
                lead_seconds=1.0,
                trail_seconds=1.0,
            )

        press_at = next(event[2] for event in sink.events if event[0] == "press")
        release_at = next(event[2] for event in sink.events if event[0] == "release")
        self.assertLess(press_at, record["profiler"]["startSeconds"])
        self.assertGreater(release_at, record["profiler"]["stopSeconds"])
        self.assertTrue(record["overlap"]["contained"])
        self.assertEqual(record["direction"], "down")
        self.assertEqual(record["profiler"]["exitStatus"], 0)
        repeats_during = [
            event
            for event in sink.events
            if event[0] == "repeat"
            and record["profiler"]["startSeconds"] <= event[2] <= record["profiler"]["stopSeconds"]
        ]
        self.assertGreater(len(repeats_during), 0)

    def test_a_profiler_reporting_a_window_outside_the_stimulus_invalidates_the_capture(self):
        # Intent: when the profiler reports its own recording boundaries, those --
        #   not the harness's wall-clock guesses -- decide containment, and a window
        #   outside the stimulus fails the capture after the key is released.
        # Why it exists: `xctrace` records on its own schedule, so its reported
        #   window is the authority. Trusting the harness's own timestamps would let
        #   a capture claim containment it cannot prove, and failing before the
        #   release would leave the arrow key stuck down.
        # Scenario: spec-first -- a trace whose recording ran past its time limit.
        clock = ManualClock()
        sink = RecordingSink(clock)
        profiler = FakeProfiler(clock, run_seconds=5.0, reported_window=(900.0, 950.0))
        with make_stimulus(clock, sink) as stimulus:
            with self.assertRaises(STIMULUS.StimulusOverlapError):
                STIMULUS.run_bounded_capture(
                    stimulus,
                    "down",
                    start_profiler=profiler.start,
                profiler_timeout_seconds=60.0,
                    lead_seconds=1.0,
                    trail_seconds=1.0,
                )
        self.assertEqual(sink.events[-1][0], "release")

    def test_containment_is_judged_against_this_capture_alone(self):
        # Intent: a capture run on a stimulus that already has legs behind it
        #   validates against the window it pressed, not against every leg ever.
        # Why it exists: this is the one way the containment check can fail
        #   silently. A window widened by an earlier leg makes any profiler window
        #   look contained, so the capture would be blessed without proving the
        #   thing I5 asks for.
        # Scenario: spec-first -- a driver that warms btop up before profiling it.
        clock = ManualClock()
        sink = RecordingSink(clock)
        profiler = FakeProfiler(clock, run_seconds=5.0, reported_window=(1000.5, 1002.0))
        with make_stimulus(clock, sink) as stimulus:
            stimulus.hold("down", 3.0)
            stimulus.release()
            # The warm-up leg spans 1000.0 .. 1003.0, which would contain the
            # profiler's reported window if the capture measured from leg zero.
            with self.assertRaises(STIMULUS.StimulusOverlapError):
                STIMULUS.run_bounded_capture(
                    stimulus,
                    "up",
                    start_profiler=profiler.start,
                    profiler_timeout_seconds=60.0,
                    lead_seconds=1.0,
                    trail_seconds=1.0,
                )

    def test_a_profiler_that_never_exits_releases_the_key_and_fails_the_capture(self):
        # Intent: the wait on the profiler is bounded, and overrunning the bound
        #   releases the arrow key before failing the capture.
        # Why it exists: I5's "every exit releases the active key" has to hold for
        #   the exit nobody plans -- a profiler that hangs. An unbounded wait is not
        #   an exit at all: it leaves Down held indefinitely in a live GUI session,
        #   long after the operator has given up on the run.
        # Scenario: spec-first -- `xctrace` wedged while attaching.
        clock = ManualClock()
        sink = RecordingSink(clock)

        class HangingProfiler:
            returncode = None

            def start(self):
                return self

            def poll(self):
                return None

        with make_stimulus(clock, sink) as stimulus:
            with self.assertRaises(STIMULUS.StimulusError):
                STIMULUS.run_bounded_capture(
                    stimulus,
                    "down",
                    start_profiler=HangingProfiler().start,
                    profiler_timeout_seconds=30.0,
                    lead_seconds=1.0,
                    trail_seconds=1.0,
                )
        self.assertEqual(sink.events[-1][0], "release")

    def test_a_failed_profiler_still_releases_and_reports_its_exit_status(self):
        clock = ManualClock()
        sink = RecordingSink(clock)

        class FailingProfiler(FakeProfiler):
            def poll(self):
                if self._clock.now() >= self._deadline:
                    self.returncode = 3
                    return 3
                return None

        profiler = FailingProfiler(clock, run_seconds=2.0)
        with make_stimulus(clock, sink) as stimulus:
            record = STIMULUS.run_bounded_capture(
                stimulus,
                "down",
                start_profiler=profiler.start,
                profiler_timeout_seconds=60.0,
                lead_seconds=0.5,
                trail_seconds=0.5,
            )
        self.assertEqual(record["profiler"]["exitStatus"], 3)
        self.assertEqual(sink.events[-1][0], "release")


class InputPermissionTests(unittest.TestCase):
    def test_a_granted_preflight_records_the_mechanism_it_proved(self):
        # Intent: the preflight returns the mechanism name the run will actually use
        #   to synthesize input.
        # Why it exists: I7 requires the identity to record the input mechanism and
        #   permission result together. A bare boolean cannot distinguish "allowed to
        #   post CGEvents" from "allowed to drive System Events", which are different
        #   privileges with different failure modes.
        # Scenario: spec-first -- a host that has already granted Accessibility.
        def run_command(command, **kwargs):
            return subprocess.CompletedProcess(
                command,
                0,
                stdout='{"granted":true,"mechanism":"CGEventPostToPid"}\n',
            )

        permission = STIMULUS.preflight_input_permission("/tmp/arm", run_command=run_command)
        self.assertTrue(permission["granted"])
        self.assertEqual(permission["mechanism"], "CGEventPostToPid")

    def test_a_denied_preflight_raises_before_anything_is_built(self):
        # Intent: a host that cannot post events fails the preflight outright.
        # Why it exists: PO1 requires rejection before build or launch. Discovering
        #   the denial after a release build and a GUI launch wastes minutes and
        #   leaves a half-configured app on screen.
        # Scenario: spec-first -- a shell without Accessibility permission.
        def run_command(command, **kwargs):
            return subprocess.CompletedProcess(
                command,
                0,
                stdout='{"granted":false,"mechanism":"CGEventPostToPid"}\n',
            )

        with self.assertRaises(STIMULUS.InputPermissionError):
            STIMULUS.preflight_input_permission("/tmp/arm", run_command=run_command)


class ArmSinkTests(unittest.TestCase):
    def test_the_arm_sink_writes_one_command_line_per_key_event(self):
        # Intent: the sink's whole job is to turn press/repeat/release into the
        #   arm's line protocol against the owned pid.
        # Why it exists: the arm is the only component that can post a real CGEvent,
        #   so it cannot be exercised hermetically; keeping the sink this thin is
        #   what lets every timing decision above be proved without it.
        # Scenario: spec-first -- the stimulus driving the compiled arm.
        class FakeStream:
            def __init__(self):
                self.lines = []
                self.flushed = 0

            def write(self, text):
                self.lines.append(text)

            def flush(self):
                self.flushed += 1

        stream = FakeStream()
        sink = STIMULUS.ArmSink(stream)
        sink.press("down")
        sink.repeat("down")
        sink.release("down")
        self.assertEqual(stream.lines, ["press down\n", "repeat down\n", "release down\n"])
        self.assertEqual(stream.flushed, 3)

    def test_an_unknown_direction_is_refused(self):
        sink = STIMULUS.ArmSink(None)
        with self.assertRaises(ValueError):
            sink.press("left")


class StimulusArmTests(unittest.TestCase):
    """Compiled once for the class: the build is the slow part, and both cases share it."""

    @classmethod
    def setUpClass(cls):
        cls._directory = tempfile.TemporaryDirectory()
        cls.binary = STIMULUS.compile_stimulus_arm(cls._directory.name)

    @classmethod
    def tearDownClass(cls):
        cls._directory.cleanup()

    def test_the_arm_compiles_and_reports_its_permission_as_json(self):
        # Intent: the native arm builds from this checkout and answers `preflight`
        #   with the JSON shape `preflight_input_permission` parses.
        # Why it exists: the arm is the only component `just test` cannot exercise
        #   through its real path, so without this a typo in it stays invisible until
        #   an opt-in GUI run -- minutes of build and launch away from the mistake.
        # Scenario: spec-first; `granted` is deliberately unasserted because it
        #   reports the host's Accessibility state, which is not this suite's subject.
        result = subprocess.run(
            [str(self.binary), "preflight"], capture_output=True, text=True, check=True
        )
        permission = json.loads(result.stdout)
        self.assertEqual(permission["mechanism"], "CGEventPostToPid")
        self.assertIsInstance(permission["granted"], bool)

    def test_the_arm_refuses_an_unusable_invocation(self):
        result = subprocess.run([str(self.binary), "post"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
