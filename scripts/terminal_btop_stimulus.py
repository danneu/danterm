"""Held-arrow keyboard stimulus for the live btop profiling workload.

The btop diagnostic profiles what a user held-scrolling btop's process list
costs, so its stimulus has to be a real held arrow key: a key-down, a repeat
train at the host's own cadence, and a key-up that always happens. Only the
posting of a CGEvent needs macOS; every decision around it -- when a repeat is
due, when a leg turns around, whether the profiler's recording window sits
inside the measured stimulus -- is timing logic, and lives here so it can be
proved against an injected clock instead of inside a GUI run.

What belongs here: cadence, sequencing, measured timestamps, and the
containment rule. What does not: profiler invocation, artifact shape, workload
admission, and anything that reads or writes the profile bundle -- those live
in the profiling harness and in `terminal_btop_artifacts`. The mechanism itself
is `terminal-btop-stimulus-arm.swift`, which this module drives over a line
protocol and never reimplements.
"""
import dataclasses
import json
import pathlib
import subprocess


# kVK_DownArrow / kVK_UpArrow. The arm re-declares them; this side names the
# directions and lets the arm own the key codes.
ARROW_DIRECTIONS = ("down", "up")
# macOS stores both repeat preferences as counts of 1/60 s ticks.
KEY_REPEAT_TICK_SECONDS = 1 / 60
# What the Keyboard pane's sliders sit at on a host that has never moved them.
# `defaults read -g` exits nonzero rather than reporting these, so a run that
# falls back records `source: "system-default"` and never claims it measured
# the host.
SYSTEM_DEFAULT_KEY_REPEAT_TICKS = 6
SYSTEM_DEFAULT_INITIAL_KEY_REPEAT_TICKS = 25
# `defaults write -g KeyRepeat 0` is a real setting, and a zero interval would
# make the repeat train a spin loop that never advances its next due time. One
# tick is the smallest cadence the preference can otherwise express, so it is
# what a zero clamps to; the raw ticks stay in the artifact, so a reader can see
# the clamp happened.
MINIMUM_REPEAT_INTERVAL_SECONDS = KEY_REPEAT_TICK_SECONDS
# How often the driver wakes while nothing is due. Short enough that a repeat
# lands within a tick of its due time, long enough that the driver itself is
# not a measurable share of the profiled process's load.
PUMP_INTERVAL_SECONDS = 0.005
STIMULUS_ARM_SOURCE = pathlib.Path(__file__).with_name("terminal-btop-stimulus-arm.swift")


class StimulusError(RuntimeError):
    """A stimulus was asked for something it cannot prove -- never a host failure."""


class StimulusOverlapError(StimulusError):
    """The profiler recorded outside the measured stimulus, so the capture is invalid."""


class InputPermissionError(RuntimeError):
    """This process may not synthesize input, so no capture can be attributable."""


@dataclasses.dataclass(frozen=True)
class KeyRepeatCadence:
    """The host's own repeat timing, kept whole so a run can record what it used.

    Both the raw ticks and the derived seconds are retained: the ticks are what
    an operator can compare against their own Keyboard settings, and the seconds
    are what the stimulus actually times against.
    """

    initial_delay_seconds: float
    repeat_interval_seconds: float
    initial_key_repeat_ticks: int
    key_repeat_ticks: int
    source: str

    def __post_init__(self):
        # Enforced at construction, not at the pump: a zero interval turns the
        # repeat train into a loop whose next due time never moves, and a hang
        # holding an arrow key down is the worst failure this module has.
        if self.repeat_interval_seconds <= 0:
            raise ValueError("the repeat interval must be positive")
        if self.initial_delay_seconds < 0:
            raise ValueError("the initial repeat delay cannot be negative")

    def artifact(self):
        return {
            "source": self.source,
            "keyRepeatTicks": self.key_repeat_ticks,
            "initialKeyRepeatTicks": self.initial_key_repeat_ticks,
            "repeatIntervalSeconds": self.repeat_interval_seconds,
            "initialDelaySeconds": self.initial_delay_seconds,
            "tickSeconds": KEY_REPEAT_TICK_SECONDS,
            "clampedToMinimumInterval": (
                self.key_repeat_ticks * KEY_REPEAT_TICK_SECONDS
                < MINIMUM_REPEAT_INTERVAL_SECONDS
            ),
        }


def read_key_repeat_cadence(run_command=subprocess.run):
    """Read the host's key repeat settings, falling back to the system defaults.

    The diagnostic follows the host's repeat timing, so event rates may differ
    between machines; every run must record the rate it produced. Every path here
    yields a labelled `source`.
    """
    def read_tick(name, fallback):
        try:
            result = run_command(
                ["defaults", "read", "-g", name],
                check=True,
                capture_output=True,
                text=True,
            )
        except (subprocess.CalledProcessError, FileNotFoundError):
            return fallback, False
        try:
            return int(result.stdout.strip()), True
        except ValueError:
            return fallback, False

    key_repeat, key_repeat_measured = read_tick("KeyRepeat", SYSTEM_DEFAULT_KEY_REPEAT_TICKS)
    initial, initial_measured = read_tick(
        "InitialKeyRepeat", SYSTEM_DEFAULT_INITIAL_KEY_REPEAT_TICKS
    )
    return KeyRepeatCadence(
        initial_delay_seconds=max(0.0, initial * KEY_REPEAT_TICK_SECONDS),
        repeat_interval_seconds=max(
            MINIMUM_REPEAT_INTERVAL_SECONDS, key_repeat * KEY_REPEAT_TICK_SECONDS
        ),
        initial_key_repeat_ticks=initial,
        key_repeat_ticks=key_repeat,
        source="host" if key_repeat_measured and initial_measured else "system-default",
    )


class ArmSink:
    """Turns key events into the arm's line protocol; deliberately holds no policy.

    Every timing decision is made by `ArrowStimulus`, so this stays thin enough
    that the one component needing a real WindowServer contributes nothing that
    a hermetic test would have wanted to cover.
    """

    def __init__(self, stream):
        self._stream = stream

    def _send(self, verb, direction):
        if direction not in ARROW_DIRECTIONS:
            raise ValueError(f"unknown arrow direction: {direction}")
        self._stream.write(f"{verb} {direction}\n")
        self._stream.flush()

    def press(self, direction):
        self._send("press", direction)

    def repeat(self, direction):
        self._send("repeat", direction)

    def release(self, direction):
        self._send("release", direction)


class ArrowStimulus:
    """Holds one arrow key at a time and records exactly when it did.

    At most one key is ever down, every direction change and every exit posts the
    matching key-up, and the resulting press/release times are measured rather
    than inferred from the requested
    duration -- because `validate_profiler_overlap` decides a capture's validity
    from them.
    """

    def __init__(self, sink, cadence, *, clock, sleep):
        self._sink = sink
        self._cadence = cadence
        self._clock = clock
        self._sleep = sleep
        self._legs = []
        self._active = None
        self._current = None
        self._next_repeat_seconds = None

    def now(self):
        """The stimulus's own clock, so a caller times against the same one it does."""
        return self._clock()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        # A release on the way out of a failing block can itself fail -- the arm
        # is usually the thing that died. Let the original exception win in that
        # case, because it is the one that explains the run; a BrokenPipeError
        # raised over it would send the reader after the wrong cause.
        try:
            self.release()
        except Exception:
            if exc_type is None:
                raise
        return False

    def press(self, direction):
        """Hold `direction`, releasing any other key first."""
        if direction not in ARROW_DIRECTIONS:
            raise ValueError(f"unknown arrow direction: {direction}")
        if self._active == direction:
            return
        self.release()
        now = self._clock()
        self._sink.press(direction)
        self._active = direction
        self._current = {
            "direction": direction,
            "pressedAtSeconds": now,
            "repeatCount": 0,
            "resyncCount": 0,
        }
        self._next_repeat_seconds = now + self._cadence.initial_delay_seconds

    def release(self):
        """Post the key-up for whatever is held. Safe to call when nothing is."""
        if self._active is None:
            return
        direction, self._active = self._active, None
        leg, self._current = self._current, None
        self._next_repeat_seconds = None
        # The leg is recorded even when the key-up cannot be posted: the measured
        # window is what decides whether the capture is attributable, and losing
        # it would turn one failed write into an unexplainable run.
        try:
            self._sink.release(direction)
        finally:
            leg["releasedAtSeconds"] = self._clock()
            self._legs.append(leg)

    def pump(self):
        """Emit the repeat now due, if one is, so a caller's wait loop stays the timer.

        At most one per call, and a driver that fell behind resyncs to now rather
        than replaying what it missed. A real held key does not catch up: bursting
        the backlog after a scheduling stall would deliver a scroll rate no user
        can produce, contradicting the local held-key behavior this workload
        reproduces.
        """
        if self._active is None:
            return 0
        now = self._clock()
        if now < self._next_repeat_seconds:
            return 0
        self._sink.repeat(self._active)
        self._current["repeatCount"] += 1
        self._next_repeat_seconds += self._cadence.repeat_interval_seconds
        if self._next_repeat_seconds <= now:
            self._next_repeat_seconds = now + self._cadence.repeat_interval_seconds
            self._current["resyncCount"] += 1
        return 1

    def wait(self, seconds, *, should_continue=None):
        """Keep the held key repeating for `seconds`, pumping as repeats come due."""
        deadline = self._clock() + seconds
        while self._clock() < deadline:
            if should_continue is not None and not should_continue():
                return False
            self.pump()
            self._sleep(min(PUMP_INTERVAL_SECONDS, max(0.0, deadline - self._clock())))
        self.pump()
        return True

    def hold(self, direction, seconds, *, should_continue=None):
        """Press `direction` and keep it held for `seconds`."""
        self.press(direction)
        return self.wait(seconds, should_continue=should_continue)

    def wait_while(self, predicate, *, timeout_seconds):
        """Keep the held key repeating while `predicate` holds, up to `timeout_seconds`.

        Returns whether the predicate went false in time. The bound is not
        optional: the caller is waiting on a profiler subprocess, and one that
        never exits would otherwise spin here forever with an arrow key down --
        a stuck key that outlives the run and poisons the operator's session.
        """
        deadline = self._clock() + timeout_seconds
        while predicate():
            if self._clock() >= deadline:
                self.pump()
                return False
            self.pump()
            self._sleep(PUMP_INTERVAL_SECONDS)
        self.pump()
        return True

    def legs(self):
        """The completed legs, each with its measured press/release times."""
        return list(self._legs)

    def measured_window(self, *, from_leg=0):
        """The press and release bounding legs `from_leg` onward -- what a profiler must fit in.

        `from_leg` exists so a bounded capture measures only the legs it pressed.
        Spanning legs an earlier capture left behind would widen the window until
        containment passed for free, which is the one way this check can fail
        silently rather than loudly.
        """
        if self._active is not None:
            raise StimulusError("the stimulus window is only measurable once the key is released")
        legs = self._legs[from_leg:]
        if not legs:
            raise StimulusError("no arrow key was pressed in this window")
        return (legs[0]["pressedAtSeconds"], legs[-1]["releasedAtSeconds"])

    def artifact(self, *, from_leg=0):
        legs = self._legs[from_leg:]
        return {
            "cadence": self._cadence.artifact(),
            "legs": legs,
            "directionChanges": max(0, len(legs) - 1),
        }


def alternate(stimulus, *, leg_seconds, should_continue, directions=ARROW_DIRECTIONS, on_leg=None):
    """Run fixed-length legs, turning around each time, until `should_continue` goes false.

    Loop mode's whole job. Because a leg may end in an idle tail, it issues no
    coverage verdict: an attaching agent brackets its own window against the
    direction and timing this publishes.
    """
    index = 0
    while should_continue():
        direction = directions[index % len(directions)]
        if on_leg is not None:
            on_leg(direction)
        stimulus.hold(direction, leg_seconds, should_continue=should_continue)
        index += 1
    stimulus.release()


def validate_profiler_overlap(stimulus_window, profiler_window):
    """Require the profiler's window to lie wholly inside the measured stimulus lifetime.

    Raises rather than returning a flag: a capture whose edges profile an
    unstimulated window is not a weaker measurement, it is a different one, and
    reporting it as this workload would be the failure the whole diagnostic is
    built to avoid.
    """
    stimulus_start, stimulus_end = stimulus_window
    profiler_start, profiler_stop = profiler_window
    if profiler_stop < profiler_start:
        raise StimulusOverlapError(
            f"profiler window ends before it starts: {profiler_start} .. {profiler_stop}"
        )
    if profiler_start < stimulus_start or profiler_stop > stimulus_end:
        raise StimulusOverlapError(
            "profiler window "
            f"{profiler_start} .. {profiler_stop} is not contained by the measured stimulus "
            f"{stimulus_start} .. {stimulus_end}"
        )
    return {
        "contained": True,
        "stimulusStartSeconds": stimulus_start,
        "stimulusEndSeconds": stimulus_end,
        "profilerStartSeconds": profiler_start,
        "profilerStopSeconds": profiler_stop,
        "leadSeconds": profiler_start - stimulus_start,
        "trailSeconds": stimulus_end - profiler_stop,
    }


def run_bounded_capture(
    stimulus,
    direction,
    *,
    start_profiler,
    profiler_timeout_seconds,
    lead_seconds=1.0,
    trail_seconds=1.0,
):
    """Hold one direction across a whole profiler run and prove the containment.

    The ordering is the contract: press, hold through `lead_seconds`, start the
    profiler, keep repeating until it exits, hold `trail_seconds` more, release,
    and only then judge containment -- so a rejected capture still leaves no key
    down. A profiler handle that reports its own recording window is believed
    over the harness's clock readings, because for `xctrace` the harness's are
    an outer bound and not the measurement.
    """
    first_leg = len(stimulus.legs())
    stimulus.press(direction)
    stimulus.wait(lead_seconds)
    profiler_start = stimulus.now()
    handle = start_profiler()
    finished = stimulus.wait_while(
        lambda: handle.poll() is None, timeout_seconds=profiler_timeout_seconds
    )
    profiler_stop = stimulus.now()
    stimulus.wait(trail_seconds)
    stimulus.release()
    if not finished:
        raise StimulusError(
            f"the profiler did not exit within {profiler_timeout_seconds}s; "
            "the capture covers an unknown window"
        )

    reporter = getattr(handle, "profiler_window", None)
    reported_window = None if reporter is None else reporter()
    window = reported_window if reported_window is not None else (profiler_start, profiler_stop)
    overlap = validate_profiler_overlap(stimulus.measured_window(from_leg=first_leg), window)
    return {
        "direction": direction,
        "stimulus": stimulus.artifact(from_leg=first_leg),
        "profiler": {
            "startSeconds": window[0],
            "stopSeconds": window[1],
            "harnessStartSeconds": profiler_start,
            "harnessStopSeconds": profiler_stop,
            "windowSource": (
                "profiler-reported" if reported_window is not None else "harness-measured"
            ),
            "exitStatus": handle.returncode,
        },
        "overlap": overlap,
    }


def compile_stimulus_arm(output_directory, *, source_path=STIMULUS_ARM_SOURCE,
                         run_command=subprocess.run):
    """Build the one native component, so the preflight below can use the real mechanism."""
    output_directory = pathlib.Path(output_directory)
    output_directory.mkdir(parents=True, exist_ok=True)
    binary = output_directory / "terminal-btop-stimulus-arm"
    run_command(
        ["xcrun", "swiftc", str(source_path), "-O", "-o", str(binary)],
        check=True,
        capture_output=True,
        text=True,
    )
    return binary


def preflight_input_permission(arm_binary, *, run_command=subprocess.run):
    """Prove this process may post events before build or launch begins.

    Asks the arm rather than a second mechanism: the permission that matters is
    the one the stimulus will actually exercise, and a preflight through some
    other API can pass while `CGEventPostToPid` is still refused.
    """
    result = run_command(
        [str(arm_binary), "preflight"],
        check=True,
        capture_output=True,
        text=True,
    )
    try:
        permission = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise InputPermissionError("stimulus arm returned invalid preflight JSON") from error
    if permission.get("granted") is not True:
        raise InputPermissionError(
            "this process may not synthesize keyboard input "
            f"({permission.get('mechanism', 'unknown mechanism')}). "
            "Grant Accessibility access to the shell running the benchmark and retry."
        )
    return permission
