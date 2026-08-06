#!/usr/bin/env python3
"""Grade one live-btop profiling bundle and record what produced it.

The btop diagnostic profiles a live, input-driven app, so a report is only worth
reading if the measured interval can be shown to have been the one the operator
asked for: the app frontmost with its window presented, damage actually drawn,
arrow input held across the whole recording, that input visibly driving the
drawing rather than merely coinciding with it, a profiler that parsed samples,
and a host that did not throttle underneath it. Every one of those is a subtraction
between two lifetime counters or a gate over one artifact, so all of it lives
here -- separately invocable, hermetically testable -- rather than inside the
GUI run where a missing counter and a genuinely idle app look identical.

The rule this file exists to keep is that missing measurement never renders as
zero. A section that could not be proved is left out of the identity entirely
and its reason is recorded, because a `sampleCount: 0` would read as a measured,
idle window instead of an absent measurement.

What belongs here: artifact subtraction, validity gates, btop's own identity
(executable, version, effective config), and the assembly of the extended
profile identity. What does not: launching or profiling anything, workload
admission, readiness checks, and the held-key timing logic -- those are the
profiling harness's and `terminal_btop_stimulus`'s.

Loop mode has no verdict to compute here: an attaching agent must bracket and
validate its own window, so this grades only bounded `sample` and `trace`
captures.
"""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys


# The bundle's file names. They are constants because both this module's tests
# and the profiling harness that writes them have to agree on the same spelling.
IDENTITY = "identity.json"
ACTIVITY_BEFORE = "activity-before.json"
ACTIVITY_AFTER = "activity-after.json"
PROFILE_REPORT = "profile-report.json"
TRACE_TOC = "trace-toc.xml"
STIMULUS_CAPTURE = "btop-stimulus.json"
MACHINE_STATE = "btop-machine-state.json"
WORKLOAD_IDENTITY = "btop-workload.json"

WORKLOAD_NAME = "btop-scroll"
# Bumped past the profiling harness's own 2 because this adds the btop workload
# block, the coverage sections, and the capture verdict to the same record.
IDENTITY_SCHEMA_VERSION = 3

TOPOLOGY_COUNTERS = ("sampleCount", "fullDamageCount", "dirtyRectFallbackCount")
TOPOLOGY_HISTOGRAMS = (
    "jointHistogram",
    "damagedRowCountHistogram",
    "maximalContiguousSpanCountHistogram",
)
COVERAGE_COUNTERS = ("sampleCount", "foregroundSampleCount", "presentedSampleCount")
# What a btop workload identity must carry before it can claim to say what ran.
REQUIRED_WORKLOAD_FIELDS = ("executablePath", "version", "config", "process", "input")
# The floor on damage samples per delivered key event, below which the stimulus
# provably did not drive the app. A held arrow scrolling btop redraws once per
# key event, and the host cadence (30/s) is under the display's refresh rate, so
# a working capture sits near 1.0; the silent-input regression this gate was
# built for sat at 0.042 (19 samples against 450 key events -- btop's own ~1.5/s
# idle repaint, and nothing else). A quarter leaves 4x of headroom for frame
# coalescing while still rejecting an idle app by an order of magnitude.
MINIMUM_DRAWS_PER_KEY_EVENT = 0.25
# The floor on foreground/presentation samples per second of measured interval.
# The app samples on a 100ms wall-clock cadence, so a nominal run sits at 10/s and
# the working recorded bundle measured 9.08/s (188 samples over 20.712s) once the
# main thread's own scheduling is paid for. Half the nominal cadence is the floor:
# it tolerates the main thread being unavailable for half the window, leaves the
# working run 1.8x of headroom, and rejects the draw-triggered sampling this gate
# was built for -- the broken bundle's 19 samples over 13.183s, 1.44/s -- by 3.5x.
# It is a floor on *observation*, not on the app's speed: nothing here depends on
# how fast the app drew, which is why a slow-drawing run cannot trip it.
MINIMUM_PRESENTATION_SAMPLES_PER_SECOND = 5.0
# The floor on parsed profiler samples per second of measured interval. The two
# recorded btop bundles parsed 38.3/s (505 over 13.183s) and 107.7/s (2231 over
# 20.712s) -- both legitimately attached, and differing by 2.8x because the count
# depends on thread count and template. The floor therefore sits far under the
# slower of them (7.7x) rather than near either, and still rejects a profiler that
# attached for the tail of a window -- 3 samples over 20s, 0.15/s -- by 33x.
MINIMUM_PROFILER_SAMPLES_PER_SECOND = 5.0

_TOC_SCHEMA = re.compile(r'schema="([A-Za-z0-9._-]+)"')
_ANSI_STYLE = re.compile(r"\x1b\[[0-9;]*m")
_VERSION_NUMBER = re.compile(r"version:\s*(\S+)")


class CaptureInvalid(RuntimeError):
    """A capture cannot be reported as this workload -- never a host or tool failure.

    Raised by every gate below so the caller can name which claim failed. It is
    deliberately distinct from an exception the bundle's IO might raise: a
    missing file is a fact about the run, and this is the verdict on it.
    """


# --- activity snapshot subtraction --------------------------------------------


def _subtract_counters(before, after, names, what):
    delta = {}
    for name in names:
        if name not in before or name not in after:
            raise CaptureInvalid(f"{what} is unmeasured: a snapshot is missing `{name}`")
        change = after[name] - before[name]
        if change < 0:
            raise CaptureInvalid(
                f"{what} counter `{name}` fell by {-change} across the bracket; these "
                "counters are cumulative for one app's lifetime, so the two snapshots "
                "did not come from one continuous run"
            )
        delta[name] = change
    return delta


def _subtract_histogram(before, after, what):
    """Difference two cumulative histograms, keeping only the buckets that moved.

    A bucket that did not move is dropped rather than emitted as zero: the reader
    treats the delta as "the shapes this window drew", and a zero entry there
    would assert a measured absence that a stationary lifetime counter cannot
    support.
    """
    delta = {}
    for bucket, count in after.items():
        change = count - before.get(bucket, 0)
        if change < 0:
            raise CaptureInvalid(
                f"{what} bucket `{bucket}` fell by {-change} across the bracket; these "
                "counters are cumulative, so the snapshots are not one run"
            )
        if change:
            delta[bucket] = change
    for bucket in before:
        if bucket not in after:
            raise CaptureInvalid(
                f"{what} lost bucket `{bucket}` across the bracket; these counters are "
                "cumulative, so the snapshots are not one run"
            )
    return delta


def measured_interval_seconds(capture):
    """Read the profiler window every sample-density floor is normalized by.

    Taken from the recorded overlap rather than from the two activity snapshots'
    own clock readings: the snapshots are file copies of a periodically
    republished counter file, so the span between them is the span between two
    *publishes* and drifts from the profiled window in both directions (measured
    on the recorded bundles: 12.945s counted against 13.183s profiled, and
    22.910s against 20.712s). The profiler window is the interval the report's
    numbers are attributed to, so it is the one a density has to be stated over.

    Raised as unmeasured, never defaulted: this is the denominator of both
    floors, so a substituted value would silently decide a verdict.
    """
    overlap = capture.get("overlap") if isinstance(capture, dict) else None
    if not isinstance(overlap, dict):
        raise CaptureInvalid(
            "the bounded capture recorded no stimulus/profiler overlap, so the length "
            "of the measured interval is unmeasured"
        )
    bounds = {}
    for name in ("profilerStartSeconds", "profilerStopSeconds"):
        value = overlap.get(name)
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            raise CaptureInvalid(
                f"the recorded overlap carries no numeric `{name}`, so the length of the "
                "measured interval is unmeasured"
            )
        bounds[name] = value
    seconds = bounds["profilerStopSeconds"] - bounds["profilerStartSeconds"]
    if seconds <= 0:
        raise CaptureInvalid(
            f"the recorded profiler window is {seconds:.3f}s long, so it spans no "
            "interval any measurement could have been taken over"
        )
    return seconds


def _grade_sample_density(samples, interval_seconds, floor, *, what, consequence):
    """Require `samples` to cover `interval_seconds` densely enough to speak for it.

    Shared by the two count-only gates because they fail the same way: a count
    above zero says an observer existed, and says nothing about whether it
    observed often enough for the interval's verdict to rest on it. An absent
    interval reports as unmeasured rather than skipping the check, so a bundle
    that lost its window fails closed.
    """
    if interval_seconds is None:
        raise CaptureInvalid(
            f"{what} density is unmeasured: the bundle records no profiler window to "
            "state a sample rate over"
        )
    rate = samples / interval_seconds
    if rate < floor:
        raise CaptureInvalid(
            f"{what} carries {samples} samples across the {interval_seconds:.3f}s "
            f"measured interval ({rate:.2f}/s, floor {floor}/s); {consequence}"
        )
    return {
        "measuredIntervalSeconds": round(interval_seconds, 4),
        "samplesPerSecond": round(rate, 4),
        "minimumSamplesPerSecond": floor,
    }


def damage_topology_coverage(before_snapshot, after_snapshot):
    """Subtract the bracketing snapshots' damage topology and require it to be nonempty.

    The positive-sample gate lives here rather than beside it because a zero
    sample delta is not a weaker topology, it is the absence of one: the
    profiler recorded a window in which the app submitted no damage at all, so
    nothing it attributed belongs to this workload.

    Deliberately carries no per-second floor, unlike presentation and profiler
    coverage. Those two count *observations of* the run, so a low rate indicts
    the instrument. This one counts the run's own drawing, so a low rate is a
    finding about the app -- an unqualified wall-clock floor here would reject a
    genuinely slow-drawing DanTerm as an invalid capture, which is precisely the
    result the diagnostic exists to report. The honest normalizer for drawing is
    the stimulus that asked for it, and that is
    `stimulus_response_coverage`'s draws-per-key-event.
    """
    before = before_snapshot.get("damageTopology")
    after = after_snapshot.get("damageTopology")
    if before is None or after is None:
        raise CaptureInvalid(
            "damage topology is unmeasured: an activity snapshot published none, which "
            "is not the same claim as an interval that drew nothing"
        )
    delta = _subtract_counters(before, after, TOPOLOGY_COUNTERS, "damage topology")
    if delta["sampleCount"] <= 0:
        raise CaptureInvalid(
            "no damage-topology samples fall inside the measured interval, so the "
            "profiler recorded a window this app did not draw in"
        )
    for name in TOPOLOGY_HISTOGRAMS:
        delta[name] = _subtract_histogram(before.get(name, {}), after.get(name, {}), name)
    return delta


def presentation_coverage(before_snapshot, after_snapshot, interval_seconds):
    """Subtract the continuous foreground/presentation counters and require full coverage.

    Four separate failures are distinguished, and that is the point: an app that
    never published the counters (unmeasured), an interval no publish landed in
    (unsampled), an interval too thinly sampled for its length to speak for it
    (under-observed), and an interval that was sampled and lapsed (not
    attributable). Only the last one is about the app's behavior; grading them
    the same would let the first three pass as clean runs.

    The density is graded before the lapse counts because it decides what those
    counts mean: `lapsedForegroundSamples: 0` over 19 observations of a 13-second
    window is not a weaker version of the same claim, it is a claim about the 19
    instants that were looked at.
    """
    before = before_snapshot.get("presentationCoverage")
    after = after_snapshot.get("presentationCoverage")
    if before is None or after is None:
        raise CaptureInvalid(
            "presentation coverage is unmeasured: an activity snapshot published none, "
            "so nothing proves this app was frontmost and on screen while profiled"
        )
    delta = _subtract_counters(before, after, COVERAGE_COUNTERS, "presentation coverage")
    if delta["sampleCount"] <= 0:
        raise CaptureInvalid(
            "no foreground/presentation samples fall inside the measured interval, so "
            "every lapse count is zero for want of an observation rather than for want "
            "of a lapse"
        )
    density = _grade_sample_density(
        delta["sampleCount"],
        interval_seconds,
        MINIMUM_PRESENTATION_SAMPLES_PER_SECOND,
        what="presentation coverage",
        consequence=(
            "the interval was sampled too sparsely for its lapse counts to speak for "
            "it, so a lapse shorter than the gap between samples would leave them at "
            "zero"
        ),
    )
    lapses = {}
    for name, noun in (
        ("foregroundSampleCount", "frontmost"),
        ("presentedSampleCount", "fully presented"),
    ):
        lapsed = delta["sampleCount"] - delta[name]
        if lapsed < 0:
            raise CaptureInvalid(
                f"`{name}` exceeds `sampleCount` across the bracket; the published "
                "coverage counters are inconsistent"
            )
        if lapsed > 0:
            raise CaptureInvalid(
                f"the app was not {noun} for {lapsed} of {delta['sampleCount']} samples "
                "inside the measured interval, so the profile is not attributable to it"
            )
        lapses[name] = lapsed
    return {
        **delta,
        **density,
        "lapsedForegroundSamples": lapses["foregroundSampleCount"],
        "lapsedPresentedSamples": lapses["presentedSampleCount"],
    }


# --- profiler artifact gates ---------------------------------------------------


def profiler_sample_coverage(report, interval_seconds):
    """Require the profile report to have sampled the measured interval, not just touched it.

    The count gate alone cannot tell a profiler that covered the window from one
    that attached for its last few milliseconds, and every percentage the report
    prints is then computed over a window the profile never saw. The density
    floor is what separates them; it is set well under the slowest legitimately
    attached run rather than near it, because sample count varies with thread
    count and template and this gate has no business grading either.
    """
    totals = report.get("totals") if isinstance(report, dict) else None
    if not isinstance(totals, dict) or "samples" not in totals:
        raise CaptureInvalid("the profile report carries no sample totals to gate on")
    if totals["samples"] <= 0:
        raise CaptureInvalid(
            "the profiler parsed no samples, so the capture measured nothing regardless "
            "of what the rest of the bundle proves"
        )
    density = _grade_sample_density(
        totals["samples"],
        interval_seconds,
        MINIMUM_PROFILER_SAMPLES_PER_SECOND,
        what="the profile report",
        consequence=(
            "the profiler cannot have covered the interval it is attributed to, so its "
            "percentages describe a window it barely observed"
        ),
    )
    source = report.get("source") or {}
    return {
        "samples": totals["samples"],
        "weight": totals.get("weight"),
        "weightUnit": source.get("weightUnit"),
        **density,
    }


def validate_trace_export(toc_text):
    """Require a trace's own table of contents to contain a time-profile table.

    `xctrace record` succeeds with any template, including the memory ones, and
    then exports an empty time-profile table. Without this the empty export reads
    downstream as an idle process instead of as the wrong template, so the
    rejection names the schemas that were actually recorded.
    """
    schemas = sorted(set(_TOC_SCHEMA.findall(toc_text)))
    if "time-profile" not in schemas:
        raise CaptureInvalid(
            "the recording template exported no time-profile table; schemas present: "
            + (", ".join(schemas) or "none")
        )
    return {"schemas": schemas, "hasTimeProfile": True}


def validate_stimulus_overlap(capture):
    """Require the bounded capture to have proved the profiler ran inside the stimulus.

    The containment itself is decided in `terminal_btop_stimulus` at capture
    time; this re-reads the recorded verdict so a bundle assembled from files --
    the only thing an operator or a later reader has -- is graded on the same
    rule as the live run.
    """
    overlap = capture.get("overlap") if isinstance(capture, dict) else None
    if not isinstance(overlap, dict):
        raise CaptureInvalid(
            "the bounded capture recorded no stimulus/profiler overlap, so nothing "
            "proves an arrow key was held for the whole recording"
        )
    if overlap.get("contained") is not True:
        raise CaptureInvalid(
            "the profiler window is not contained by the measured stimulus, so the "
            "recording's edges profiled an unstimulated app"
        )
    return overlap


def count_delivered_key_events(capture):
    """Count the key-downs the stimulus posted inside the measured window.

    One per leg for the press, plus that leg's repeats. Raised as unmeasured
    rather than returned as zero when a leg cannot say how many repeats it
    posted: "the stimulus delivered nothing" and "nobody counted" are the two
    claims this whole module exists to keep apart.
    """
    stimulus = capture.get("stimulus") if isinstance(capture, dict) else None
    legs = stimulus.get("legs") if isinstance(stimulus, dict) else None
    if not isinstance(legs, list) or not legs:
        raise CaptureInvalid(
            "the bounded capture recorded no stimulus legs, so the number of key "
            "events it delivered is unmeasured"
        )
    total = 0
    for leg in legs:
        repeats = leg.get("repeatCount") if isinstance(leg, dict) else None
        if not isinstance(repeats, int) or isinstance(repeats, bool) or repeats < 0:
            raise CaptureInvalid(
                "a stimulus leg published no `repeatCount`, so the key events it "
                "delivered are unmeasured"
            )
        total += 1 + repeats
    return total


def stimulus_response_coverage(capture, topology):
    """Require the app to have drawn in proportion to the key events it was sent.

    Every other gate here grades one side of the run in isolation: input was
    posted, the app was frontmost, the profiler parsed samples, the app drew
    *something*. A run can satisfy all of them and still have measured nothing,
    because "input was posted" is a claim about this harness and "the app drew"
    is a claim about btop's own idle repaint -- neither one connects the two. The
    silent-input regression that motivated this gate did exactly that: 450 key
    events posted, 19 idle-rate damage samples, and a clean verdict on a profile
    of an app sitting still.

    So this is the one gate that crosses the seam, and it is deliberately
    coarse: it asks only whether the drawing was of the same order as the
    stimulus, which is the most a bundle of counters can honestly support.
    """
    if topology is None:
        raise CaptureInvalid(
            "the stimulus response is unmeasured: the damage topology it must be "
            "compared against was not itself measured"
        )
    samples = topology.get("sampleCount")
    if not isinstance(samples, int) or isinstance(samples, bool):
        raise CaptureInvalid(
            "the damage topology delta carries no `sampleCount`, so the app's "
            "response to the stimulus is unmeasured"
        )
    key_events = count_delivered_key_events(capture)
    ratio = samples / key_events
    if ratio < MINIMUM_DRAWS_PER_KEY_EVENT:
        raise CaptureInvalid(
            f"the app drew {samples} damage samples against {key_events} delivered key "
            f"events ({ratio:.3f} per event, floor {MINIMUM_DRAWS_PER_KEY_EVENT}); the "
            "stimulus reached the recording without reaching the app, so the profile is "
            "of an app that was not being driven"
        )
    return {
        "keyEventCount": key_events,
        "damageSampleCount": samples,
        "drawsPerKeyEvent": round(ratio, 4),
        "minimumDrawsPerKeyEvent": MINIMUM_DRAWS_PER_KEY_EVENT,
    }


def machine_state_coverage(samples):
    """Count the machine-state samples taken during the interval and reject a throttled host.

    Counted, not latched, for the same reason presentation coverage is: an
    interval nobody sampled cannot report a nominal host, and reporting one would
    be the strongest possible claim from the weakest possible evidence.
    """
    if not isinstance(samples, list) or not samples:
        raise CaptureInvalid(
            "no machine-state samples cover the measured interval, so the host's "
            "thermal and power state during it is unmeasured"
        )
    reasons = []
    for sample in samples:
        thermal = sample.get("thermalState")
        if thermal != "nominal":
            reason = f"thermal-pressure-{thermal}"
            if reason not in reasons:
                reasons.append(reason)
        if sample.get("lowPowerMode"):
            if "low-power-mode" not in reasons:
                reasons.append("low-power-mode")
    if reasons:
        raise CaptureInvalid(
            "the host changed state inside the measured interval: " + ", ".join(reasons)
        )
    return {
        "sampleCount": len(samples),
        "thermalStates": sorted({sample.get("thermalState") for sample in samples}),
        "powerSources": sorted(
            {sample["powerSource"] for sample in samples if sample.get("powerSource")}
        ),
        "lowPowerMode": False,
    }


# --- btop's own identity -------------------------------------------------------


def resolve_btop_executable(name="btop", *, which=shutil.which):
    """Resolve btop to one absolute path, so the run records the binary it launched.

    A bare `btop` on the harness's PATH is not provenance: the fresh-HOME shell
    the workload launches may resolve a different one, and two runs that disagree
    about which binary they measured cannot be compared at all.
    """
    resolved = which(name)
    if not resolved:
        raise CaptureInvalid(
            f"`{name}` is not on PATH, so there is no executable to profile; install it "
            "or put it on PATH before starting a run"
        )
    return str(pathlib.Path(resolved).resolve())


def parse_btop_version(text):
    """Pull the bare version number out of `btop --version` output.

    btop styles its own version with SGR escapes, so the raw first line carries
    control bytes into the provenance record and makes two identical versions
    compare unequal.
    """
    plain = _ANSI_STYLE.sub("", text).strip()
    match = _VERSION_NUMBER.search(plain)
    if not match:
        first_line = plain.splitlines()[0] if plain else ""
        raise CaptureInvalid(f"could not read a btop version from: {first_line!r}")
    return match.group(1)


def read_btop_version(executable, *, run_command=subprocess.run):
    """Ask the resolved binary what it is, rather than trusting a package manager."""
    result = run_command(
        [str(executable), "--version"], check=True, capture_output=True, text=True
    )
    return parse_btop_version(result.stdout)


def btop_config_identity(environment, *, config_flag=None):
    """Resolve and digest the config file btop will actually read.

    Precedence matches btop's own, measured against btop 1.4.7 rather than
    assumed: an explicit `--config` wins, then `$XDG_CONFIG_HOME/btop`, then
    `$HOME/.config/btop`; with neither variable set btop refuses to start, and so
    does this.

    A file that does not exist yet -- the normal state under the fresh HOME the
    harness builds, because btop writes its config on exit -- reports
    `exists: false` and carries no digest at all. Hashing nothing would give
    every fresh run the same digest and make "these two runs had matching
    conditions" trivially true.
    """
    if config_flag:
        path, source = pathlib.Path(config_flag), "explicit-flag"
    elif environment.get("XDG_CONFIG_HOME"):
        path = pathlib.Path(environment["XDG_CONFIG_HOME"]) / "btop" / "btop.conf"
        source = "xdg-config-home"
    elif environment.get("HOME"):
        path = pathlib.Path(environment["HOME"]) / ".config" / "btop" / "btop.conf"
        source = "home"
    else:
        raise CaptureInvalid(
            "neither XDG_CONFIG_HOME nor HOME is set, so btop has no config path to "
            "resolve -- the same condition btop itself refuses to start under"
        )
    identity = {"path": str(path), "source": source, "exists": path.is_file()}
    if identity["exists"]:
        identity["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    return identity


def validate_workload_identity(workload):
    """Require the recorded workload identity to say what actually ran."""
    if not isinstance(workload, dict):
        raise CaptureInvalid(
            "the run recorded no btop workload identity, so the bundle cannot say which "
            "binary, configuration, or process it profiled"
        )
    missing = [field for field in REQUIRED_WORKLOAD_FIELDS if not workload.get(field)]
    if missing:
        raise CaptureInvalid(
            "the btop workload identity is missing " + ", ".join(f"`{name}`" for name in missing)
        )
    return workload


# --- assembly ------------------------------------------------------------------


def summarize_capture(bundle, *, mode):
    """Grade every section of one loaded bundle and build the extended profile identity.

    Every gate is graded even after one fails, because they are independent and
    an operator re-runs a 20-second GUI capture to learn the next reason. The
    sections that could not be proved are absent from `coverage` rather than
    zeroed there, and their reasons are the verdict's `invalidReasons`.
    """
    reasons = []
    coverage = {}
    identity = {}

    def section(label, thunk):
        try:
            return thunk()
        except CaptureInvalid as error:
            reasons.append(f"{label}: {error}")
            return None

    def record(container, key, label, thunk):
        value = section(label, thunk)
        if value is not None:
            container[key] = value
        return value

    capture = bundle.get("stimulusCapture")
    # Resolved before any section that needs it, because two of them share it as a
    # denominator. A failure here is recorded once, under its own label, and then
    # reappears as "unmeasured" in each section it denied -- which is the honest
    # reading: one missing fact, and the two verdicts it prevents.
    interval_seconds = None
    try:
        interval_seconds = measured_interval_seconds(capture)
    except CaptureInvalid as error:
        reasons.append(f"measuredInterval: {error}")

    before = bundle.get("activityBefore")
    after = bundle.get("activityAfter")
    # Held across the sections because the stimulus-response gate below is the one
    # that reads two of them together; absent means unmeasured, never zero drawing.
    topology = None
    if before is None or after is None:
        reasons.append(
            "activity: the run did not bracket its profiler window with two activity "
            "snapshots, so neither topology nor presentation coverage exists"
        )
    else:
        topology = record(
            coverage, "damageTopology", "damageTopology",
            lambda: damage_topology_coverage(before, after),
        )
        record(
            coverage, "presentation", "presentation",
            lambda: presentation_coverage(before, after, interval_seconds),
        )

    report = bundle.get("profileReport")
    if report is None:
        reasons.append("profilerSamples: the run produced no profile report")
    else:
        record(
            coverage, "profilerSamples", "profilerSamples",
            lambda: profiler_sample_coverage(report, interval_seconds),
        )

    record(
        coverage, "machineState", "machineState",
        lambda: machine_state_coverage(bundle.get("machineStateSamples")),
    )

    if capture is None:
        reasons.append(
            "overlap: the run recorded no bounded stimulus capture, so no arrow input is "
            "attributable to the recording"
        )
    else:
        # Passed through key by key, and only when the capture recorded them: a
        # `null` here would be one more way for the identity to describe something
        # it never observed.
        for source_key, identity_key in (
            ("stimulus", "stimulus"),
            ("profiler", "profiler"),
            ("direction", "stimulusDirection"),
        ):
            if capture.get(source_key) is not None:
                identity[identity_key] = capture[source_key]
        record(identity, "overlap", "overlap", lambda: validate_stimulus_overlap(capture))

    record(
        coverage, "stimulusResponse", "stimulusResponse",
        lambda: stimulus_response_coverage(capture, topology),
    )

    record(
        identity, "btop", "workloadIdentity",
        lambda: validate_workload_identity(bundle.get("workload")),
    )

    if mode == "trace":
        toc = bundle.get("traceToc")
        if toc is None:
            reasons.append(
                "traceExport: the trace produced no table of contents, so nothing proves "
                "the template recorded a time-profile table"
            )
        else:
            record(identity, "traceExport", "traceExport", lambda: validate_trace_export(toc))

    identity.update(
        {
            "schemaVersion": IDENTITY_SCHEMA_VERSION,
            "workload": WORKLOAD_NAME,
            "coverage": coverage,
            "capture": {"mode": mode, "valid": not reasons, "invalidReasons": reasons},
            "decisionEligible": False,
            "historyEligible": False,
            "profiledTimingsAreDiagnosticOnly": True,
            # `sample` counts running and blocked threads alike and a time profile
            # attributes only what it sampled; neither is this process's CPU use.
            "profilerSamplesAreNotWholeProcessCPU": True,
        }
    )
    return identity


def _read_json(path):
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return None


def load_bundle(root):
    """Read whatever the run left behind, reporting absence as absence.

    A file that is missing or unparseable comes back as `None` rather than as an
    empty default, so the gates above see "unmeasured" and not "measured empty".
    """
    root = pathlib.Path(root)
    toc = root / TRACE_TOC
    return {
        "identity": _read_json(root / IDENTITY),
        "activityBefore": _read_json(root / ACTIVITY_BEFORE),
        "activityAfter": _read_json(root / ACTIVITY_AFTER),
        "profileReport": _read_json(root / PROFILE_REPORT),
        "machineStateSamples": _read_json(root / MACHINE_STATE),
        "stimulusCapture": _read_json(root / STIMULUS_CAPTURE),
        "workload": _read_json(root / WORKLOAD_IDENTITY),
        "traceToc": toc.read_text(errors="replace") if toc.is_file() else None,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("root", help="the profile bundle directory to grade")
    parser.add_argument(
        "--mode",
        required=True,
        choices=("sample", "trace"),
        help="which bounded capture produced the bundle; loop issues no verdict",
    )
    arguments = parser.parse_args(argv)

    root = pathlib.Path(arguments.root)
    bundle = load_bundle(root)
    extension = summarize_capture(bundle, mode=arguments.mode)
    # Extends the harness's own identity rather than writing a second provenance
    # format beside it, so there is exactly one record to read and one to cite.
    identity = dict(bundle.get("identity") or {})
    identity.update(extension)
    # Written before the exit status is decided: an invalidated run must leave the
    # partial bundle behind, because the reason it was rejected is the only thing
    # an operator can act on.
    root.mkdir(parents=True, exist_ok=True)
    (root / IDENTITY).write_text(json.dumps(identity, indent=2, sort_keys=True) + "\n")

    verdict = extension["capture"]
    if verdict["valid"]:
        print(f"btop capture valid; identity: {root / IDENTITY}")
        return 0
    print(f"btop capture invalid; identity preserved at {root / IDENTITY}", file=sys.stderr)
    for reason in verdict["invalidReasons"]:
        print(f"  - {reason}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
