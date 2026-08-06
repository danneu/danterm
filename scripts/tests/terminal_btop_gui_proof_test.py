#!/usr/bin/env python3
"""One question: does the live btop proof judge a GUI run, or merely run one?

The proof itself needs a logged-in session, an installed btop, and a minute of
wall clock, so nothing in `just test` can run it. What `just test` can hold is
the part that decides pass from fail: an opt-in proof whose judgment is wrong
reports a green live run over a capture that lost foreground, drew nothing, or
left an arrow key down -- and does it exactly when the diagnostic is broken.
So every rule the proof grades a run by is proved here against fixtures, and
the GUI script is left holding only the driving.
"""
import pathlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import importlib.util  # noqa: E402


def _load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PROOF = _load("terminal_btop_gui_proof", "scripts/terminal-btop-gui-proof.py")


def valid_identity(mode="sample"):
    """A bundle identity from a valid live bounded capture at the owned 179x66 PTY."""
    identity = {
        "capture": {"mode": mode, "valid": True, "invalidReasons": []},
        "coverage": {
            "damageTopology": {"sampleCount": 812, "fullDamageCount": 0},
            "presentation": {
                "sampleCount": 190,
                "foregroundSampleCount": 190,
                "presentedSampleCount": 190,
                "lapsedForegroundSamples": 0,
                "lapsedPresentedSamples": 0,
            },
            "profilerSamples": {"samples": 4211, "weight": 4211},
            "machineState": {"sampleCount": 12, "lowPowerMode": False},
        },
        "overlap": {"contained": True, "leadSeconds": 1.0, "trailSeconds": 1.0},
        "stimulus": {
            "legs": [
                {"direction": "down", "pressedAtSeconds": 1.0,
                 "releasedAtSeconds": 23.0, "repeatCount": 780}
            ],
            "directionChanges": 0,
        },
        "btop": {
            "executablePath": "/opt/homebrew/bin/btop",
            "version": "1.4.7",
            "input": {"granted": True, "mechanism": "CGEventPostToPid"},
            "process": {"pid": 4242, "tty": "ttys012", "rows": 66, "columns": 179},
        },
    }
    if mode == "trace":
        identity["traceExport"] = {"hasTimeProfile": True, "schemas": ["time-profile"]}
    return identity


class BoundedCaptureJudgment(unittest.TestCase):
    def test_a_fully_proved_capture_has_no_failures(self):
        for mode in ("sample", "trace"):
            with self.subTest(mode=mode):
                self.assertEqual(
                    PROOF.judge_bounded_capture(valid_identity(mode), mode=mode, status=0), []
                )

    def test_a_nonzero_exit_fails_even_with_a_clean_identity(self):
        failures = PROOF.judge_bounded_capture(valid_identity(), mode="sample", status=1)
        self.assertTrue(any("exited 1" in failure for failure in failures))

    def test_a_missing_identity_is_reported_rather_than_crashed_on(self):
        # A run that died before grading leaves no identity at all. That is the
        # single most likely live failure, so it must produce a named failure
        # instead of a traceback the operator has to interpret.
        failures = PROOF.judge_bounded_capture(None, mode="sample", status=2)
        self.assertTrue(failures)
        self.assertTrue(any("identity" in failure for failure in failures))

    def test_an_invalid_capture_reports_the_graders_own_reasons(self):
        identity = valid_identity()
        identity["capture"] = {
            "mode": "sample",
            "valid": False,
            "invalidReasons": ["presentation: the app was not frontmost for 3 of 190 samples"],
        }
        failures = PROOF.judge_bounded_capture(identity, mode="sample", status=1)
        self.assertTrue(any("not frontmost" in failure for failure in failures))

    def test_zero_topology_samples_fail_even_when_the_grader_passed_the_bundle(self):
        # Intent: the proof re-reads the coverage numbers rather than trusting
        #   `capture.valid` alone.
        # Why it exists: `capture.valid` and the coverage sections come from the
        #   same module, so a bug that stopped gating topology would make both go
        #   green together. Re-checking the counts here is the independent read.
        identity = valid_identity()
        identity["coverage"]["damageTopology"]["sampleCount"] = 0
        failures = PROOF.judge_bounded_capture(identity, mode="sample", status=0)
        self.assertTrue(any("topology" in failure for failure in failures))

    def test_an_absent_coverage_section_is_not_read_as_a_zero(self):
        identity = valid_identity()
        del identity["coverage"]["presentation"]
        failures = PROOF.judge_bounded_capture(identity, mode="sample", status=0)
        self.assertTrue(any("presentation" in failure for failure in failures))

    def test_a_presentation_lapse_fails(self):
        identity = valid_identity()
        identity["coverage"]["presentation"]["lapsedForegroundSamples"] = 4
        failures = PROOF.judge_bounded_capture(identity, mode="sample", status=0)
        self.assertTrue(any("lapsed" in failure for failure in failures))

    def test_an_empty_profiler_report_fails(self):
        identity = valid_identity()
        identity["coverage"]["profilerSamples"]["samples"] = 0
        failures = PROOF.judge_bounded_capture(identity, mode="sample", status=0)
        self.assertTrue(any("sample" in failure for failure in failures))

    def test_an_uncontained_profiler_window_fails(self):
        identity = valid_identity()
        identity["overlap"] = {"contained": False, "reason": "profiler outlived the stimulus"}
        failures = PROOF.judge_bounded_capture(identity, mode="sample", status=0)
        self.assertTrue(any("contained" in failure for failure in failures))

    def test_a_non_canonical_live_pty_fails(self):
        identity = valid_identity()
        identity["btop"]["process"].update({"rows": 50, "columns": 200})
        failures = PROOF.judge_bounded_capture(identity, mode="sample", status=0)
        self.assertTrue(any("200x50" in failure for failure in failures))

    def test_input_that_was_never_granted_fails(self):
        identity = valid_identity()
        identity["btop"]["input"] = {"granted": False, "mechanism": "CGEventPostToPid"}
        failures = PROOF.judge_bounded_capture(identity, mode="sample", status=0)
        self.assertTrue(any("input" in failure for failure in failures))

    def test_a_trace_without_a_time_profile_table_fails(self):
        # A valid live trace specifically requires a Time Profiler report, and
        # `xctrace` records happily with a template that exports no such table.
        identity = valid_identity("trace")
        identity["traceExport"] = {"hasTimeProfile": False, "schemas": ["allocations"]}
        failures = PROOF.judge_bounded_capture(identity, mode="trace", status=0)
        self.assertTrue(any("time-profile" in failure for failure in failures))

    def test_a_sample_run_is_not_asked_for_a_trace_export(self):
        identity = valid_identity("sample")
        self.assertEqual(PROOF.judge_bounded_capture(identity, mode="sample", status=0), [])


class ForegroundLapseJudgment(unittest.TestCase):
    def lapsed_identity(self):
        identity = valid_identity()
        identity["capture"] = {
            "mode": "sample",
            "valid": False,
            "invalidReasons": [
                "presentation: the app was not frontmost for 6 of 190 samples inside "
                "the measured interval, so the profile is not attributable to it"
            ],
        }
        return identity

    def test_a_stolen_foreground_run_must_fail_loudly_and_say_why(self):
        self.assertEqual(
            PROOF.judge_foreground_lapse(self.lapsed_identity(), status=1), []
        )

    def test_a_run_that_lost_foreground_and_still_exited_zero_is_a_failure(self):
        # Intent: the invalidation has to reach the exit status, not just the JSON.
        # Why it exists: an operator scripting the diagnostic reads `$?`; a
        #   rejected capture that exits 0 is indistinguishable from a good one at
        #   the only place a script looks.
        failures = PROOF.judge_foreground_lapse(self.lapsed_identity(), status=0)
        self.assertTrue(any("exit" in failure for failure in failures))

    def test_a_run_that_stayed_valid_through_a_stolen_foreground_is_a_failure(self):
        failures = PROOF.judge_foreground_lapse(valid_identity(), status=1)
        self.assertTrue(any("valid" in failure for failure in failures))

    def test_an_invalidation_for_some_other_reason_does_not_count(self):
        # Intent: the proof must show the foreground gate fired, not merely that
        #   something rejected the run.
        # Why it exists: a 20-second live capture has several ways to fail at
        #   once. Accepting any reason would let this stay green while the exact
        #   live-proof gate quietly stopped working.
        identity = self.lapsed_identity()
        identity["capture"]["invalidReasons"] = [
            "machineState: the host changed state inside the measured interval: low-power-mode"
        ]
        failures = PROOF.judge_foreground_lapse(identity, status=1)
        self.assertTrue(any("frontmost" in failure for failure in failures))

    def test_a_rejected_run_that_preserved_no_identity_is_a_failure(self):
        # The plan requires an invalidated run to leave its partial bundle behind:
        # the reason is the only thing an operator can act on afterwards.
        failures = PROOF.judge_foreground_lapse(None, status=1)
        self.assertTrue(any("preserve" in failure for failure in failures))


class LoopJudgment(unittest.TestCase):
    def publication(self, direction, started):
        return {
            "workload": "btop-scroll",
            "mode": "loop",
            "direction": direction,
            "legSeconds": 10.0,
            "legStartedAtSeconds": started,
            "coverageVerdict": "none -- loop measures nothing; bracket and validate "
            "your own profiler window",
        }

    def test_two_alternating_legs_pass(self):
        self.assertEqual(
            PROOF.judge_loop_publications(
                [self.publication("down", 1.0), self.publication("up", 11.0)]
            ),
            [],
        )

    def test_a_single_leg_does_not_prove_alternation(self):
        failures = PROOF.judge_loop_publications([self.publication("down", 1.0)])
        self.assertTrue(any("alternat" in failure for failure in failures))

    def test_a_repeated_direction_is_not_an_alternation(self):
        failures = PROOF.judge_loop_publications(
            [self.publication("down", 1.0), self.publication("down", 11.0)]
        )
        self.assertTrue(any("down" in failure for failure in failures))

    def test_loop_must_keep_disclaiming_a_verdict(self):
        # Intent: every published leg still says loop measures nothing.
        # Why it exists: loop's legs can end on an idle tail, so an attaching
        #   agent must bracket its own window. The disclaimer is the only
        #   thing in the live file that tells it so.
        publications = [self.publication("down", 1.0), self.publication("up", 11.0)]
        del publications[1]["coverageVerdict"]
        failures = PROOF.judge_loop_publications(publications)
        self.assertTrue(any("verdict" in failure for failure in failures))

    def test_no_published_leg_at_all_is_a_failure(self):
        failures = PROOF.judge_loop_publications([])
        self.assertTrue(failures)


class TeardownJudgment(unittest.TestCase):
    def test_a_clean_teardown_has_no_failures(self):
        self.assertEqual(
            PROOF.judge_teardown(
                surviving_owned_pids=[], stray_arm_pids=[], bystander_alive=True
            ),
            [],
        )

    def test_a_surviving_owned_process_is_a_failure(self):
        failures = PROOF.judge_teardown(
            surviving_owned_pids=[9001], stray_arm_pids=[], bystander_alive=True
        )
        self.assertTrue(any("9001" in failure for failure in failures))

    def test_a_surviving_stimulus_arm_is_a_stuck_key(self):
        # Intent: an arm process still running after the run is graded as a key
        #   that is still down.
        # Why it exists: the arm holds a real key-down in the operator's live
        #   session. Nothing else in the bundle would show it, because the
        #   artifact records the release the driver *asked* for.
        failures = PROOF.judge_teardown(
            surviving_owned_pids=[], stray_arm_pids=[9100], bystander_alive=True
        )
        self.assertTrue(any("key" in failure for failure in failures))

    def test_killing_an_unrelated_btop_is_a_failure(self):
        # Scenario: the operator had their own btop open. Ownership is decided by
        # lineage, so a run that reached outside its own process tree shows up
        # here as a bystander that stopped.
        failures = PROOF.judge_teardown(
            surviving_owned_pids=[], stray_arm_pids=[], bystander_alive=False
        )
        self.assertTrue(any("unrelated" in failure for failure in failures))


class ForegroundStealTiming(unittest.TestCase):
    """When the deliberately-spoiled phase is allowed to take the foreground away."""

    def test_no_profile_root_yet_is_not_due(self):
        self.assertFalse(PROOF.foreground_steal_is_due(None))

    def test_a_root_without_the_opening_snapshot_is_not_due(self):
        # Intent: a run that has only created its bundle directory is not yet
        #   being measured, so stealing now proves nothing.
        # Why it exists: the first live run of this proof stole the foreground on
        #   a fixed timer a few seconds after the harness started -- during the
        #   release build, tens of seconds before the profiler attached. The
        #   capture came back valid and the phase failed while the diagnostic it
        #   was testing was working correctly.
        with tempfile.TemporaryDirectory() as directory:
            self.assertFalse(PROOF.foreground_steal_is_due(pathlib.Path(directory)))

    def test_the_opening_activity_snapshot_makes_it_due(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / PROOF.ACTIVITY_BEFORE).write_text("{}")
            self.assertTrue(PROOF.foreground_steal_is_due(root))


class ReleasedStimulusJudgment(unittest.TestCase):
    def test_every_recorded_leg_must_carry_its_release(self):
        self.assertEqual(PROOF.judge_stimulus_release(valid_identity()), [])

    def test_a_leg_with_no_release_time_is_a_failure(self):
        identity = valid_identity()
        del identity["stimulus"]["legs"][0]["releasedAtSeconds"]
        failures = PROOF.judge_stimulus_release(identity)
        self.assertTrue(any("release" in failure for failure in failures))

    def test_a_capture_that_recorded_no_leg_is_a_failure(self):
        identity = valid_identity()
        identity["stimulus"]["legs"] = []
        self.assertTrue(PROOF.judge_stimulus_release(identity))


if __name__ == "__main__":
    unittest.main()
