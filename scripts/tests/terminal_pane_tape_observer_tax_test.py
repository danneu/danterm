#!/usr/bin/env python3
"""Behavioral tests for the pane-tape observer-tax benchmark."""
import importlib.util
import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "terminal_pane_tape_observer_tax",
    ROOT / "scripts" / "terminal-pane-tape-observer-tax.py",
)
TAX = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TAX)


class ObserverTaxScheduleTests(unittest.TestCase):
    def test_counts_are_deduplicated_and_position_balanced(self):
        schedule = TAX.make_schedule(cap=8)

        self.assertEqual(
            [block["followerCount"] for block in schedule],
            [0, 1, 4, 8, 8, 4, 1, 0],
        )
        self.assertEqual([block["revisionRole"] for block in schedule], [
            "baseline", "candidate", "baseline", "candidate",
            "baseline", "candidate", "baseline", "candidate",
        ])
        self.assertEqual(
            [block["physicalArm"] for block in schedule],
            ["a", "b", "b", "a", "b", "a", "a", "b"],
        )

    def test_each_immutable_app_arm_uses_the_current_shared_harness(self):
        calls = []

        def run_command(command, **options):
            calls.append((command, options))
            return subprocess.CompletedProcess(command, 0, '{"finalDraw": {}}', "")

        TAX.run_arm("/immutable/arm", "b", 0, run_command=run_command)

        command, options = calls[0]
        self.assertEqual(command[0], str(ROOT / "scripts" / "terminal-benchmark.sh"))
        self.assertEqual(options["cwd"], ROOT)
        self.assertEqual(
            options["env"]["DANTERM_TERMINAL_BENCHMARK_SOURCE_ROOT"],
            "/immutable/arm",
        )


class ObserverTaxSummaryTests(unittest.TestCase):
    def _block(self, role, followers, *, drain=100, total=120):
        return {
            "revisionRole": role,
            "followerCount": followers,
            "producerWriteNanoseconds": drain,
            "producerWriteBytes": 1_000,
            "finalDrawNanoseconds": total,
            "followerCompletionNanoseconds": 30 if followers else None,
            "followMetrics": {
                "ownerNanoseconds": 10 * followers,
                "ownerSampleCount": followers,
                "followFenceCount": 2 * followers,
                "pushCount": 3 * followers,
                "synchronizationCount": 0,
                "statePairingCount": 2 * followers,
            },
            "terminalEvent": "final-draw-completed",
            "followerCompletions": followers,
        }

    def test_summary_reports_each_revision_tax_from_its_own_zero_follower_arm(self):
        blocks = [
            self._block("baseline", 0, drain=100, total=120),
            self._block("baseline", 2, drain=130, total=160),
            self._block("candidate", 0, drain=90, total=110),
            self._block("candidate", 2, drain=100, total=125),
        ]

        summary = TAX.summarize(blocks)

        self.assertEqual(summary["baseline"][2]["drainTaxNanoseconds"], 30)
        self.assertEqual(summary["baseline"][2]["blockTaxNanoseconds"], 40)
        self.assertEqual(summary["candidate"][2]["drainTaxNanoseconds"], 10)
        self.assertEqual(summary["candidate"][2]["blockTaxNanoseconds"], 15)
        self.assertEqual(summary["baseline"][2]["ownerNanosecondsPerSubscriberSample"], 10)
        self.assertLess(summary["baseline"][2]["drainRateTaxMegabytesPerSecond"], 0)

    def test_zero_samples_are_absent_instead_of_reported_as_zero(self):
        block = self._block("candidate", 1)
        block["followMetrics"]["ownerSampleCount"] = 0

        summary = TAX.summarize([
            self._block("candidate", 0),
            block,
        ])

        self.assertIsNone(summary["candidate"][1]["ownerNanosecondsPerSubscriberSample"])

    def test_injected_owner_delay_moves_the_owner_cost(self):
        ordinary = self._block("candidate", 1)
        delayed = self._block("baseline", 1)
        delayed["followMetrics"]["ownerNanoseconds"] += 50

        summary = TAX.summarize([
            self._block("candidate", 0), ordinary,
            self._block("baseline", 0), delayed,
        ])

        self.assertEqual(summary["candidate"][1]["ownerNanosecondsPerSubscriberSample"], 10)
        self.assertEqual(summary["baseline"][1]["ownerNanosecondsPerSubscriberSample"], 60)

    def test_mismatched_block_contract_is_rejected(self):
        block = self._block("candidate", 2)
        block["followerCompletions"] = 1

        with self.assertRaisesRegex(ValueError, "follower completion count"):
            TAX.summarize([self._block("candidate", 0), block])


if __name__ == "__main__":
    unittest.main()
