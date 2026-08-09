#!/usr/bin/env python3
"""One question: can a live-btop bundle tell a valid capture from an unproven one?

The btop diagnostic's whole claim is that its numbers came from a measured
interval in which the app was frontmost, presented, drawing, and profiled. Every
part of that claim is an artifact subtraction or a gate, so it is proved here
against hand-built bundles instead of inside a GUI run -- where a missing
counter and a genuinely idle app look identical.

The hardest rule to keep is that missing measurement never renders as zero, so
most of these cases feed a bundle a key it does not have and require the verdict
to say "unmeasured" rather than "clean".
"""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import terminal_btop_artifacts as ARTIFACTS  # noqa: E402


def activity_snapshot(
    *,
    topology_samples=100,
    coverage_samples=50,
    foreground_samples=None,
    presented_samples=None,
    joint=None,
    with_topology=True,
    with_coverage=True,
):
    """One activity snapshot in exactly the shape the app-side publisher writes."""
    snapshot = {"schemaVersion": 2, "clock": "dispatch-uptime-nanoseconds", "drawCount": 0}
    if with_topology:
        snapshot["damageTopology"] = {
            "sampleCount": topology_samples,
            "fullDamageCount": 0,
            "jointHistogram": joint if joint is not None else {"rows=4,spans=2": topology_samples},
            "damagedRowCountHistogram": {"4": topology_samples},
            "maximalContiguousSpanCountHistogram": {"2": topology_samples},
        }
    if with_coverage:
        snapshot["presentationCoverage"] = {
            "sampleCount": coverage_samples,
            "foregroundSampleCount": (
                coverage_samples if foreground_samples is None else foreground_samples
            ),
            "presentedSampleCount": (
                coverage_samples if presented_samples is None else presented_samples
            ),
        }
    return snapshot


def valid_bundle():
    """A bundle in which every gate passes, so a test can spoil exactly one thing."""
    return {
        "identity": {"pid": 4242, "geometry": "179x66"},
        "activityBefore": activity_snapshot(topology_samples=1000, coverage_samples=200),
        "activityAfter": activity_snapshot(topology_samples=3400, coverage_samples=290),
        "profileReport": {
            "totals": {"samples": 812, "weight": 1_200_000_000},
            "source": {"weightUnit": "nanoseconds"},
        },
        "machineStateSamples": [
            {"thermalState": "nominal", "lowPowerMode": False, "powerSource": "ac"},
            {"thermalState": "nominal", "lowPowerMode": False, "powerSource": "ac"},
        ],
        "stimulusCapture": {
            "direction": "down",
            "stimulus": {
                "cadence": {"source": "host"},
                # 600 key events against the 2400 topology samples the bracket
                # above subtracts to: an app drawing four frames per keypress,
                # which is what a driven scroll looks like.
                "legs": [{"direction": "down", "repeatCount": 599, "resyncCount": 0}],
                "directionChanges": 0,
            },
            "profiler": {"startSeconds": 11.0, "stopSeconds": 21.0, "exitStatus": 0},
            # A 10-second profiler window, so the bracket's 90 presentation samples
            # read as 9/s -- the cadence a wall-clock sampler really achieves.
            "overlap": {
                "contained": True,
                "leadSeconds": 1.0,
                "trailSeconds": 1.0,
                "profilerStartSeconds": 11.0,
                "profilerStopSeconds": 21.0,
            },
        },
        "workload": {
            "executablePath": "/opt/homebrew/bin/btop",
            "version": "1.4.7",
            "config": {"path": "/tmp/home/.config/btop/btop.conf", "source": "home", "exists": True},
            "home": {"path": "/tmp/home", "fresh": True},
            "process": {"btopPID": 5150, "pty": {"path": "/dev/ttys009", "rows": 66, "columns": 179}},
            "input": {"mechanism": "CGEventPostToPid", "granted": True},
        },
        "traceToc": '<trace-toc><table schema="time-profile"/></trace-toc>',
    }


class DamageTopologyTests(unittest.TestCase):
    def test_topology_deltas_are_per_bucket(self):
        delta = ARTIFACTS.damage_topology_coverage(
            activity_snapshot(topology_samples=10, joint={"rows=4,spans=2": 10}),
            activity_snapshot(
                topology_samples=25, joint={"rows=4,spans=2": 18, "rows=1,spans=1": 7}
            ),
        )
        self.assertEqual(delta["sampleCount"], 15)
        self.assertEqual(delta["jointHistogram"], {"rows=4,spans=2": 8, "rows=1,spans=1": 7})

    def test_an_unchanged_bucket_is_dropped_rather_than_reported_as_zero(self):
        # Intent: a bucket the interval never hit does not appear in the delta.
        # Why it exists: the delta is read as "what this window drew"; a zero-valued
        #   bucket reads as a measured absence of that shape, which is a claim the
        #   subtraction cannot make about a lifetime counter that simply did not move.
        # Scenario: spec-first -- one shape kept accumulating, the other did not.
        delta = ARTIFACTS.damage_topology_coverage(
            activity_snapshot(topology_samples=10, joint={"rows=4,spans=2": 6, "rows=9,spans=3": 4}),
            activity_snapshot(topology_samples=20, joint={"rows=4,spans=2": 16, "rows=9,spans=3": 4}),
        )
        self.assertEqual(delta["jointHistogram"], {"rows=4,spans=2": 10})

    def test_an_unpublished_topology_is_unmeasured_not_empty(self):
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.damage_topology_coverage(
                activity_snapshot(with_topology=False), activity_snapshot()
            )
        self.assertIn("unmeasured", str(caught.exception))

    def test_an_interval_with_no_topology_samples_is_invalid(self):
        with self.assertRaises(ARTIFACTS.CaptureInvalid):
            ARTIFACTS.damage_topology_coverage(
                activity_snapshot(topology_samples=90), activity_snapshot(topology_samples=90)
            )

    def test_a_counter_that_fell_means_the_snapshots_are_not_one_run(self):
        # Intent: a decrease across the bracket is rejected, not clamped.
        # Why it exists: these counters are cumulative for the app's lifetime, so a
        #   decrease can only mean the two snapshots came from different processes --
        #   a relaunch mid-capture. Clamping to zero would hide a swapped subject.
        # Scenario: spec-first.
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.damage_topology_coverage(
                activity_snapshot(topology_samples=400), activity_snapshot(topology_samples=30)
            )
        self.assertIn("cumulative", str(caught.exception))


class MeasuredIntervalTests(unittest.TestCase):
    def test_the_profiler_window_comes_from_the_recorded_overlap(self):
        self.assertAlmostEqual(
            ARTIFACTS.measured_interval_seconds(
                {"overlap": {"profilerStartSeconds": 11.0, "profilerStopSeconds": 31.5}}
            ),
            20.5,
        )

    def test_a_capture_without_a_profiler_window_is_unmeasured(self):
        # Intent: an overlap block that names no profiler window reports the
        #   interval as unmeasured instead of substituting a default.
        # Why it exists: the interval is the denominator of both density floors, so
        #   a fabricated one would silently decide whether a run passes. "Nobody
        #   recorded the window" has to stay distinguishable from "the window was
        #   long and thinly sampled".
        # Scenario: spec-first -- a capture written by an older harness that
        #   recorded containment but not the endpoints.
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.measured_interval_seconds({"overlap": {"contained": True}})
        self.assertIn("unmeasured", str(caught.exception))

    def test_a_nonpositive_window_is_invalid(self):
        with self.assertRaises(ARTIFACTS.CaptureInvalid):
            ARTIFACTS.measured_interval_seconds(
                {"overlap": {"profilerStartSeconds": 31.0, "profilerStopSeconds": 31.0}}
            )


class PresentationCoverageTests(unittest.TestCase):
    def test_a_fully_covered_interval_counts_its_samples(self):
        delta = ARTIFACTS.presentation_coverage(
            activity_snapshot(coverage_samples=200), activity_snapshot(coverage_samples=290), 10.0
        )
        self.assertEqual(delta["sampleCount"], 90)
        self.assertEqual(delta["lapsedForegroundSamples"], 0)
        self.assertEqual(delta["lapsedPresentedSamples"], 0)
        self.assertEqual(delta["samplesPerSecond"], 9.0)
        self.assertEqual(
            delta["minimumSamplesPerSecond"], ARTIFACTS.MINIMUM_PRESENTATION_SAMPLES_PER_SECOND
        )

    def test_a_foreground_lapse_inside_the_interval_invalidates_it(self):
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.presentation_coverage(
                activity_snapshot(coverage_samples=200, foreground_samples=200),
                activity_snapshot(coverage_samples=290, foreground_samples=275),
                10.0,
            )
        self.assertIn("frontmost", str(caught.exception))

    def test_a_presentation_lapse_inside_the_interval_invalidates_it(self):
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.presentation_coverage(
                activity_snapshot(coverage_samples=200, presented_samples=200),
                activity_snapshot(coverage_samples=290, presented_samples=284),
                10.0,
            )
        self.assertIn("presented", str(caught.exception))

    def test_an_unsampled_interval_is_not_a_clean_one(self):
        # Intent: zero samples across the bracket is rejected outright.
        # Why it exists: with no samples every lapse count is also zero, so the
        #   arithmetic alone would grade an unobserved interval exactly like a
        #   perfectly covered one. This is the gate that separates them.
        # Scenario: spec-first -- the profiler window fit between two publishes.
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.presentation_coverage(
                activity_snapshot(coverage_samples=200),
                activity_snapshot(coverage_samples=200),
                10.0,
            )
        self.assertIn("no foreground", str(caught.exception))

    def test_an_app_that_published_no_coverage_is_unmeasured(self):
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.presentation_coverage(
                activity_snapshot(with_coverage=False), activity_snapshot(), 10.0
            )
        self.assertIn("unmeasured", str(caught.exception))

    def test_a_thinly_sampled_interval_is_rejected_even_with_no_lapse(self):
        # Intent: an interval whose foreground/presentation samples are far below the
        #   publisher's wall-clock cadence is rejected, and the message names the
        #   achieved rate, the floor, and the interval it was measured over.
        # Why it exists: `lapsedForegroundSamples: 0` is only as strong as the
        #   sampling that produced it. When the sample was taken from the draw path,
        #   an app that drew 19 times in 13 seconds certified 13 seconds of continuous
        #   foreground from 19 observations -- a Cmd-Tab shorter than the ~700ms gap
        #   between them would have been invisible while the count still read zero.
        #   The count gate cannot see this: 19 > 0.
        # Scenario: the recorded 2026-08-03-113912 bundle -- 19 presentation samples
        #   across a 13.183s profiler window, 1.44/s.
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.presentation_coverage(
                activity_snapshot(coverage_samples=200),
                activity_snapshot(coverage_samples=219),
                13.183,
            )
        message = str(caught.exception)
        self.assertIn("1.44", message)
        self.assertIn(str(ARTIFACTS.MINIMUM_PRESENTATION_SAMPLES_PER_SECOND), message)
        self.assertIn("19 samples", message)

    def test_an_unmeasured_interval_leaves_the_density_unmeasured(self):
        # Intent: with no measured interval the density is reported as unmeasured
        #   rather than skipped, so a bundle missing its profiler window cannot
        #   collect a clean presentation verdict by default.
        # Why it exists: the same missing-versus-zero rule the rest of this module
        #   keeps -- an ungradable denominator must fail closed, not pass silently.
        # Scenario: spec-first -- a bundle whose stimulus capture never landed.
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.presentation_coverage(
                activity_snapshot(coverage_samples=200),
                activity_snapshot(coverage_samples=290),
                None,
            )
        self.assertIn("unmeasured", str(caught.exception))


class ProfilerCoverageTests(unittest.TestCase):
    def test_a_report_with_samples_carries_its_unit(self):
        coverage = ARTIFACTS.profiler_sample_coverage(
            {"totals": {"samples": 500, "weight": 12}, "source": {"weightUnit": "samples"}}, 10.0
        )
        self.assertEqual(coverage["samples"], 500)
        self.assertEqual(coverage["weight"], 12)
        self.assertEqual(coverage["weightUnit"], "samples")
        self.assertEqual(coverage["samplesPerSecond"], 50.0)

    def test_a_report_with_no_samples_is_invalid(self):
        with self.assertRaises(ARTIFACTS.CaptureInvalid):
            ARTIFACTS.profiler_sample_coverage({"totals": {"samples": 0, "weight": 0}}, 10.0)

    def test_a_report_without_totals_is_invalid(self):
        with self.assertRaises(ARTIFACTS.CaptureInvalid):
            ARTIFACTS.profiler_sample_coverage({"threads": []}, 10.0)

    def test_a_profiler_that_caught_a_handful_of_samples_is_rejected(self):
        # Intent: a profiler whose samples are far too few for the window it claims
        #   to cover is rejected, naming the rate and the floor.
        # Why it exists: `samples > 0` grades a profiler that attached for the last
        #   30ms of a 20-second recording identically to one that covered all of it,
        #   and every downstream percentage is then computed over a window the
        #   profile never saw.
        # Scenario: spec-first -- 3 samples parsed from a 20-second window, against
        #   the 505 and 2231 the two recorded btop bundles parsed.
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.profiler_sample_coverage({"totals": {"samples": 3}}, 20.0)
        message = str(caught.exception)
        self.assertIn("0.15", message)
        self.assertIn(str(ARTIFACTS.MINIMUM_PROFILER_SAMPLES_PER_SECOND), message)

    def test_an_unmeasured_interval_leaves_profiler_density_unmeasured(self):
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.profiler_sample_coverage({"totals": {"samples": 812}}, None)
        self.assertIn("unmeasured", str(caught.exception))


class TraceExportTests(unittest.TestCase):
    def test_a_time_profile_table_is_the_proof_a_trace_recorded_one(self):
        export = ARTIFACTS.validate_trace_export(
            '<trace-toc><table schema="time-profile"/><table schema="thread-state"/></trace-toc>'
        )
        self.assertTrue(export["hasTimeProfile"])
        self.assertEqual(export["schemas"], ["thread-state", "time-profile"])

    def test_a_template_that_exported_no_time_profile_names_what_it_did_export(self):
        # Intent: a trace recorded with a non-CPU template is rejected, and the
        #   rejection names the schemas that were present.
        # Why it exists: `xctrace record` succeeds with a memory template and then
        #   exports an empty time-profile table, which downstream would read as an
        #   idle process rather than as the wrong template.
        # Scenario: spec-first.
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.validate_trace_export('<trace-toc><table schema="vm-op"/></trace-toc>')
        self.assertIn("vm-op", str(caught.exception))


class StimulusOverlapTests(unittest.TestCase):
    def test_a_contained_window_is_accepted(self):
        overlap = ARTIFACTS.validate_stimulus_overlap({"overlap": {"contained": True}})
        self.assertTrue(overlap["contained"])

    def test_a_capture_without_a_recorded_overlap_is_invalid(self):
        with self.assertRaises(ARTIFACTS.CaptureInvalid):
            ARTIFACTS.validate_stimulus_overlap({"direction": "down"})

    def test_an_uncontained_window_is_invalid(self):
        with self.assertRaises(ARTIFACTS.CaptureInvalid):
            ARTIFACTS.validate_stimulus_overlap({"overlap": {"contained": False}})


def stimulus_capture(*, repeats, legs=1):
    """A bounded capture that delivered `repeats` repeats on each of `legs` legs."""
    return {
        "direction": "down",
        "stimulus": {
            "legs": [
                {"direction": "down", "repeatCount": repeats, "resyncCount": 0}
                for _ in range(legs)
            ]
        },
    }


class StimulusResponseTests(unittest.TestCase):
    def test_drawing_in_proportion_to_the_key_events_is_accepted(self):
        coverage = ARTIFACTS.stimulus_response_coverage(
            stimulus_capture(repeats=449), {"sampleCount": 450}
        )
        self.assertEqual(coverage["keyEventCount"], 450)
        self.assertEqual(coverage["damageSampleCount"], 450)
        self.assertEqual(coverage["drawsPerKeyEvent"], 1.0)

    def test_a_press_counts_as_a_key_event_alongside_its_repeats(self):
        # Intent: each leg contributes its press plus its repeats, so a run whose
        #   repeat train never started is still credited with the press it posted.
        # Why it exists: counting repeats alone would make a two-leg capture look
        #   like it delivered two fewer events than it did, and the gate's ratio is
        #   only as honest as its denominator.
        # Scenario: spec-first -- two legs of a loop-style alternation.
        coverage = ARTIFACTS.stimulus_response_coverage(
            stimulus_capture(repeats=9, legs=2), {"sampleCount": 20}
        )
        self.assertEqual(coverage["keyEventCount"], 20)

    def test_an_idle_app_under_a_full_repeat_train_is_invalid(self):
        # Intent: a run that posted a long repeat train and drew at btop's idle
        #   rate is rejected, naming both numbers.
        # Why it exists: this is the regression the gate was built for. Every other
        #   gate passed that run -- input granted and posted, app frontmost and
        #   presented for all 19 samples, profiler parsed 505 samples, host nominal --
        #   because each one grades a single side of the seam. Without this the
        #   harness reports a clean profile of an app nothing was driving.
        # Scenario: the 2026-08-03 silent-input run, whose autorepeat-flagged
        #   CGEvents were filtered before AppKit ever saw them: 449 repeats posted,
        #   19 damage samples observed.
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.stimulus_response_coverage(
                stimulus_capture(repeats=449), {"sampleCount": 19}
            )
        message = str(caught.exception)
        self.assertIn("19 damage samples", message)
        self.assertIn("450 delivered key events", message)

    def test_a_capture_with_no_legs_is_unmeasured_not_unresponsive(self):
        # Intent: a capture that recorded no legs is graded as unmeasured rather
        #   than as a stimulus that delivered zero events.
        # Why it exists: zero key events would make the ratio a division by zero or,
        #   worse, an arbitrary pass; "nobody counted the input" and "the input did
        #   nothing" are different verdicts and only one of them indicts the app.
        # Scenario: spec-first -- a capture aborted before its first leg closed.
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.stimulus_response_coverage({"stimulus": {"legs": []}}, {"sampleCount": 500})
        self.assertIn("unmeasured", str(caught.exception))

    def test_a_leg_without_a_repeat_count_is_unmeasured(self):
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.stimulus_response_coverage(
                {"stimulus": {"legs": [{"direction": "down"}]}}, {"sampleCount": 500}
            )
        self.assertIn("unmeasured", str(caught.exception))

    def test_an_unmeasured_topology_leaves_the_response_unmeasured(self):
        # Intent: when the damage topology itself could not be subtracted, this gate
        #   reports that it has nothing to compare against.
        # Why it exists: the gate's whole job is a comparison, and a missing right
        #   operand must not be read as "the app drew nothing" -- that would turn one
        #   unmeasured section into a second, louder accusation the bundle cannot back.
        # Scenario: spec-first -- an activity snapshot published no damage topology.
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.stimulus_response_coverage(stimulus_capture(repeats=449), None)
        self.assertIn("unmeasured", str(caught.exception))


class MachineStateTests(unittest.TestCase):
    def test_nominal_samples_are_counted(self):
        state = ARTIFACTS.machine_state_coverage(
            [
                {"thermalState": "nominal", "lowPowerMode": False, "powerSource": "ac"},
                {"thermalState": "nominal", "lowPowerMode": False, "powerSource": "ac"},
            ]
        )
        self.assertEqual(state["sampleCount"], 2)
        self.assertEqual(state["powerSources"], ["ac"])

    def test_an_unsampled_interval_is_invalid(self):
        with self.assertRaises(ARTIFACTS.CaptureInvalid):
            ARTIFACTS.machine_state_coverage([])

    def test_thermal_pressure_inside_the_interval_invalidates_it(self):
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.machine_state_coverage(
                [
                    {"thermalState": "nominal", "lowPowerMode": False},
                    {"thermalState": "serious", "lowPowerMode": False},
                ]
            )
        self.assertIn("thermal-pressure-serious", str(caught.exception))

    def test_low_power_mode_inside_the_interval_invalidates_it(self):
        with self.assertRaises(ARTIFACTS.CaptureInvalid) as caught:
            ARTIFACTS.machine_state_coverage([{"thermalState": "nominal", "lowPowerMode": True}])
        self.assertIn("low-power-mode", str(caught.exception))


class BtopIdentityTests(unittest.TestCase):
    def test_xdg_config_home_wins_over_home(self):
        # Intent: config resolution matches btop's own precedence.
        # Why it exists: the harness runs btop under a fresh HOME and a fresh
        #   XDG_CONFIG_HOME, so an identity that guessed the wrong one would hash a
        #   file btop never read and claim two runs matched when they did not.
        # Scenario: spec-first, but the precedence is measured, not assumed -- btop
        #   1.4.7 launched under both wrote btop.conf into $XDG_CONFIG_HOME/btop.
        identity = ARTIFACTS.btop_config_identity({"HOME": "/h", "XDG_CONFIG_HOME": "/x"})
        self.assertEqual(identity["path"], "/x/btop/btop.conf")
        self.assertEqual(identity["source"], "xdg-config-home")

    def test_home_is_the_fallback(self):
        identity = ARTIFACTS.btop_config_identity({"HOME": "/h"})
        self.assertEqual(identity["path"], "/h/.config/btop/btop.conf")
        self.assertEqual(identity["source"], "home")

    def test_an_explicit_config_flag_wins_over_both(self):
        identity = ARTIFACTS.btop_config_identity(
            {"HOME": "/h", "XDG_CONFIG_HOME": "/x"}, config_flag="/c/btop.conf"
        )
        self.assertEqual(identity["source"], "explicit-flag")

    def test_neither_variable_set_is_invalid(self):
        with self.assertRaises(ARTIFACTS.CaptureInvalid):
            ARTIFACTS.btop_config_identity({})

    def test_an_absent_config_is_recorded_without_a_hash(self):
        # Intent: a config file that does not exist yet reports `exists: false` and
        #   carries no `sha256` key at all.
        # Why it exists: btop writes its config on exit, so a fresh HOME has none
        #   while the run is in flight. Hashing empty bytes would give every fresh
        #   run the same digest and make "matching conditions" trivially true.
        # Scenario: spec-first.
        with tempfile.TemporaryDirectory() as directory:
            identity = ARTIFACTS.btop_config_identity({"HOME": directory})
            self.assertFalse(identity["exists"])
            self.assertNotIn("sha256", identity)

    def test_a_written_config_is_hashed(self):
        with tempfile.TemporaryDirectory() as directory:
            config = pathlib.Path(directory) / ".config" / "btop" / "btop.conf"
            config.parent.mkdir(parents=True)
            config.write_text("proc_sorting = cpu direct\n")
            identity = ARTIFACTS.btop_config_identity({"HOME": directory})
            self.assertTrue(identity["exists"])
            self.assertEqual(len(identity["sha256"]), 64)

    def test_the_version_survives_btops_ansi_styling(self):
        # Intent: the recorded version is the bare number.
        # Why it exists: btop 1.4.7 prints `btop version: \x1b[1m1.4.7\x1b[0m`, so a
        #   naive split records escape codes into the provenance record and two
        #   identical versions compare unequal.
        # Scenario: spec-first; the sample string is real `btop --version` output.
        self.assertEqual(
            ARTIFACTS.parse_btop_version("btop version: \x1b[1m1.4.7\x1b[0m\n"), "1.4.7"
        )

    def test_an_unresolvable_btop_is_invalid(self):
        with self.assertRaises(ARTIFACTS.CaptureInvalid):
            ARTIFACTS.resolve_btop_executable(which=lambda _name: None)

    def test_a_resolved_btop_is_absolute(self):
        path = ARTIFACTS.resolve_btop_executable(which=lambda _name: "/opt/homebrew/bin/btop")
        self.assertEqual(path, "/opt/homebrew/bin/btop")


class SummaryTests(unittest.TestCase):
    def test_a_complete_bundle_is_valid_and_stays_diagnostic_only(self):
        identity = ARTIFACTS.summarize_capture(valid_bundle(), mode="trace")
        self.assertTrue(identity["capture"]["valid"])
        self.assertEqual(identity["capture"]["invalidReasons"], [])
        self.assertEqual(identity["coverage"]["damageTopology"]["sampleCount"], 2400)
        self.assertEqual(identity["coverage"]["presentation"]["sampleCount"], 90)
        self.assertEqual(identity["coverage"]["profilerSamples"]["samples"], 812)
        self.assertFalse(identity["decisionEligible"])
        self.assertFalse(identity["historyEligible"])
        self.assertTrue(identity["profiledTimingsAreDiagnosticOnly"])
        self.assertTrue(identity["profilerSamplesAreNotWholeProcessCPU"])

    def test_a_sample_run_is_not_asked_for_a_trace_export(self):
        bundle = valid_bundle()
        bundle["traceToc"] = None
        identity = ARTIFACTS.summarize_capture(bundle, mode="sample")
        self.assertTrue(identity["capture"]["valid"])
        self.assertNotIn("traceExport", identity)

    def test_a_trace_run_without_a_table_of_contents_is_invalid(self):
        bundle = valid_bundle()
        bundle["traceToc"] = None
        identity = ARTIFACTS.summarize_capture(bundle, mode="trace")
        self.assertFalse(identity["capture"]["valid"])
        self.assertTrue(
            any("traceExport" in reason for reason in identity["capture"]["invalidReasons"])
        )

    def test_every_failing_gate_is_reported_not_just_the_first(self):
        # Intent: one summary lists every reason the capture was rejected.
        # Why it exists: an operator re-runs a 20-second GUI capture to learn the next
        #   failure; stopping at the first reason turns one diagnosis into several
        #   launches. The gates are independent, so all of them can be graded.
        # Scenario: spec-first -- a run that lost foreground also profiled nothing.
        bundle = valid_bundle()
        bundle["activityAfter"] = activity_snapshot(
            topology_samples=3400, coverage_samples=290, foreground_samples=250
        )
        bundle["profileReport"] = {"totals": {"samples": 0, "weight": 0}}
        identity = ARTIFACTS.summarize_capture(bundle, mode="sample")
        reasons = " | ".join(identity["capture"]["invalidReasons"])
        self.assertIn("presentation", reasons)
        self.assertIn("profilerSamples", reasons)

    def test_an_unproven_section_is_absent_rather_than_zeroed(self):
        # Intent: a coverage section that could not be measured is left out of the
        #   identity entirely, with the reason carried in `invalidReasons`.
        # Why it exists: this is the plan's missing-versus-zero rule at the report
        #   boundary. A `sampleCount: 0` under `damageTopology` would read as a
        #   measured, idle window rather than as an absent measurement.
        # Scenario: spec-first -- an app build that publishes no topology counters.
        bundle = valid_bundle()
        bundle["activityBefore"] = activity_snapshot(with_topology=False)
        bundle["activityAfter"] = activity_snapshot(with_topology=False)
        identity = ARTIFACTS.summarize_capture(bundle, mode="sample")
        self.assertNotIn("damageTopology", identity["coverage"])
        self.assertFalse(identity["capture"]["valid"])

    def test_a_bundle_whose_stimulus_reached_nothing_is_graded_invalid(self):
        # Intent: a bundle that passes every single-sided gate but drew at an idle
        #   rate under a full repeat train is rejected, with the reason recorded and
        #   the unproven section left out of `coverage`.
        # Why it exists: proves the cross-seam gate is wired into the verdict and not
        #   merely defined. The run this reproduces graded `valid: true` with an empty
        #   `invalidReasons`, which is the exact output an operator cannot act on.
        # Scenario: the 2026-08-03 silent-input run replayed through the summary --
        #   19 damage samples across the bracket against 450 delivered key events.
        bundle = valid_bundle()
        bundle["activityBefore"] = activity_snapshot(topology_samples=1000, coverage_samples=200)
        bundle["activityAfter"] = activity_snapshot(topology_samples=1019, coverage_samples=290)
        identity = ARTIFACTS.summarize_capture(bundle, mode="sample")
        self.assertFalse(identity["capture"]["valid"])
        reasons = " | ".join(identity["capture"]["invalidReasons"])
        self.assertIn("stimulusResponse", reasons)
        self.assertNotIn("stimulusResponse", identity["coverage"])
        # The single-sided gates still pass, which is what made the run look clean.
        self.assertIn("presentation", identity["coverage"])
        self.assertIn("damageTopology", identity["coverage"])

    def test_a_thinly_sampled_bracket_is_graded_invalid_by_the_summary(self):
        # Intent: a bundle whose presentation samples are too sparse for its profiler
        #   window is rejected by the summary, with the section left out of
        #   `coverage` and the reason recorded.
        # Why it exists: proves the density floor is wired into the verdict and not
        #   merely defined. The count gate passes this bundle -- 19 samples, no
        #   lapses -- which is exactly how a 13-second window came to be certified as
        #   continuously frontmost from 19 draw-triggered observations.
        # Scenario: the recorded 2026-08-03-113912 bundle's presentation numbers
        #   replayed through the summary against its own 13.183s profiler window.
        bundle = valid_bundle()
        bundle["activityBefore"] = activity_snapshot(topology_samples=1000, coverage_samples=200)
        bundle["activityAfter"] = activity_snapshot(topology_samples=3400, coverage_samples=219)
        bundle["stimulusCapture"]["overlap"]["profilerStopSeconds"] = 24.183
        identity = ARTIFACTS.summarize_capture(bundle, mode="sample")
        self.assertFalse(identity["capture"]["valid"])
        reasons = " | ".join(identity["capture"]["invalidReasons"])
        self.assertIn("presentation", reasons)
        self.assertNotIn("presentation", identity["coverage"])
        # The gates that grade the app's drawing still pass, which is what made a
        # thinly observed window look like a clean one.
        self.assertIn("damageTopology", identity["coverage"])
        self.assertIn("stimulusResponse", identity["coverage"])

    def test_a_bundle_without_a_measured_interval_grades_both_densities_unmeasured(self):
        # Intent: when no profiler window was recorded, both density-bearing sections
        #   are absent from `coverage` and the missing interval is named once.
        # Why it exists: the two floors share a denominator, so losing it must fail
        #   both sections closed rather than quietly grading them on counts alone.
        # Scenario: spec-first -- a capture whose overlap block recorded containment
        #   but no endpoints.
        bundle = valid_bundle()
        bundle["stimulusCapture"]["overlap"] = {"contained": True}
        identity = ARTIFACTS.summarize_capture(bundle, mode="sample")
        self.assertFalse(identity["capture"]["valid"])
        reasons = " | ".join(identity["capture"]["invalidReasons"])
        self.assertIn("measuredInterval", reasons)
        self.assertNotIn("presentation", identity["coverage"])
        self.assertNotIn("profilerSamples", identity["coverage"])

    def test_a_capture_that_recorded_no_cadence_omits_it_rather_than_nulling_it(self):
        # Intent: a stimulus field the capture never recorded is absent from the
        #   identity, not present as null.
        # Why it exists: the identity is read to answer "did two runs have matching
        #   conditions". A null cadence compares equal to another null cadence, so
        #   two runs that recorded nothing would appear to have matched.
        # Scenario: spec-first -- an older capture file without the stimulus block.
        bundle = valid_bundle()
        del bundle["stimulusCapture"]["stimulus"]
        identity = ARTIFACTS.summarize_capture(bundle, mode="sample")
        self.assertNotIn("stimulus", identity)
        self.assertEqual(identity["stimulusDirection"], "down")

    def test_a_bundle_without_workload_identity_cannot_say_what_it_ran(self):
        bundle = valid_bundle()
        bundle["workload"] = None
        identity = ARTIFACTS.summarize_capture(bundle, mode="sample")
        self.assertFalse(identity["capture"]["valid"])
        self.assertTrue(
            any("workload" in reason for reason in identity["capture"]["invalidReasons"])
        )

    def test_workload_identity_needs_the_owned_process_and_pty(self):
        bundle = valid_bundle()
        del bundle["workload"]["process"]
        identity = ARTIFACTS.summarize_capture(bundle, mode="sample")
        self.assertFalse(identity["capture"]["valid"])


class CommandLineTests(unittest.TestCase):
    def write_bundle(self, root, bundle):
        root = pathlib.Path(root)
        for name, key in (
            (ARTIFACTS.IDENTITY, "identity"),
            (ARTIFACTS.ACTIVITY_BEFORE, "activityBefore"),
            (ARTIFACTS.ACTIVITY_AFTER, "activityAfter"),
            (ARTIFACTS.PROFILE_REPORT, "profileReport"),
            (ARTIFACTS.MACHINE_STATE, "machineStateSamples"),
            (ARTIFACTS.STIMULUS_CAPTURE, "stimulusCapture"),
            (ARTIFACTS.WORKLOAD_IDENTITY, "workload"),
        ):
            if bundle.get(key) is not None:
                (root / name).write_text(json.dumps(bundle[key]))
        if bundle.get("traceToc") is not None:
            (root / ARTIFACTS.TRACE_TOC).write_text(bundle["traceToc"])
        return root

    def test_a_valid_bundle_extends_the_existing_identity_in_place(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.write_bundle(directory, valid_bundle())
            self.assertEqual(ARTIFACTS.main([str(root), "--mode", "trace"]), 0)
            identity = json.loads((root / ARTIFACTS.IDENTITY).read_text())
            # The harness's own fields survive: this extends one provenance record
            # rather than adding a second, competing one.
            self.assertEqual(identity["pid"], 4242)
            self.assertEqual(identity["geometry"], "179x66")
            self.assertEqual(identity["workload"], "btop-scroll")
            self.assertTrue(identity["capture"]["valid"])

    def test_an_invalid_run_exits_nonzero_and_still_writes_what_it_had(self):
        # Intent: a rejected capture leaves a readable identity behind and exits 1.
        # Why it exists: the plan requires every invalidation path to preserve the
        #   partial bundle. Deleting or skipping the identity on failure would leave
        #   an operator with a nonzero exit and no way to see which gate rejected it.
        # Scenario: spec-first -- the profiler never attached, so no report exists.
        with tempfile.TemporaryDirectory() as directory:
            bundle = valid_bundle()
            bundle["profileReport"] = None
            root = self.write_bundle(directory, bundle)
            self.assertEqual(ARTIFACTS.main([str(root), "--mode", "sample"]), 1)
            identity = json.loads((root / ARTIFACTS.IDENTITY).read_text())
            self.assertFalse(identity["capture"]["valid"])
            self.assertEqual(identity["pid"], 4242)
            # The sections that did survive are still there to read.
            self.assertIn("presentation", identity["coverage"])

    def test_a_bundle_with_no_harness_identity_still_produces_one(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = valid_bundle()
            bundle["identity"] = None
            root = self.write_bundle(directory, bundle)
            self.assertEqual(ARTIFACTS.main([str(root), "--mode", "sample"]), 0)
            self.assertTrue((root / ARTIFACTS.IDENTITY).is_file())

    def test_the_script_is_invocable_and_exits_nonzero_on_an_empty_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "terminal_btop_artifacts.py"),
                    directory,
                    "--mode",
                    "sample",
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("invalid", result.stderr.lower())
            self.assertTrue((pathlib.Path(directory) / ARTIFACTS.IDENTITY).is_file())


if __name__ == "__main__":
    unittest.main()
