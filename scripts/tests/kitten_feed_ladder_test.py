#!/usr/bin/env python3
"""One question: does each kitten arm really generate and measure its own stream?

Every other test of the kitten arms works on stubs, because the ladder's tables
are the part that has to be pinned without a build. This one is the opposite: it
runs the real `TerminalCoreBenchmark generate` for all four arms, checks the
identity each one produces against the identity frozen in the block contracts, and
feeds the bytes through the real measurement path.

That is what keeps the frozen digests honest. They are constants in
`terminal-benchmark-validation.py` and nothing else in the gate reads the
generator, so an RNG change, a repetition-count change, or a kitty pin bump the
port follows would otherwise leave four stale identities behind that every
collection would then invalidate at run time -- after a snapshot, two builds, and
a series of blocks.
"""
import importlib.util
import json
import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "terminal_benchmark_validation",
    ROOT / "scripts" / "terminal-benchmark-validation.py",
)
VALIDATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATION)

BENCHMARK_PACKAGE = ROOT / "lib" / "TerminalCore"
# The description string kitten prints between repetitions, and the length of the
# framed stream, per arm. Both are transcribed from the reference rather than read
# back from the port: a routing error that mapped one workload to another arm's
# stream would agree with the port about everything and still measure the wrong
# stimulus. `scripts/kitten-benchmark-parity-lint.py` is what holds the
# descriptions themselves to `main.go`.
ARM_CHARACTERISTICS = {
    "kitten-feed-ascii": ("Only ASCII chars", 4_194_646),
    "kitten-feed-unicode": ("Unicode chars", 3_795_254),
    "kitten-feed-unique-unicode": (
        "Unique multi-codepoint Unicode cells", 3_670_372
    ),
    "kitten-feed-csi": ("CSI codes with few chars", 2_097_540),
}


class KittenFeedLadderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Built once here rather than left to the first `swift run`, so a compile
        # failure is reported as one and not as four arms that each "failed to
        # generate".
        subprocess.run(
            [
                "swift", "build",
                "--package-path", str(BENCHMARK_PACKAGE),
                "--product", "TerminalCoreBenchmark",
            ],
            check=True,
            capture_output=True,
        )
        cls.fixtures = {
            workload: VALIDATION.kitten_feed_fixture(workload, ROOT)
            for workload in VALIDATION.KITTEN_FEED_ARMS
        }

    def test_each_arm_generates_the_stimulus_its_frozen_identity_names(self):
        # Intent: the real generator produces, for every arm, exactly the framed
        #   bytes the identity frozen in that arm's block contract was taken from.
        # Why it exists: the identity is what stops a rule frozen for one stimulus
        #   from judging another, and it is a committed constant. A constant that
        #   nothing re-derives from the generator goes stale silently.
        # Scenario: spec-first; the arms land as candidates now and a human freezes
        #   a threshold per arm later, against these exact bytes.
        for workload, (_framed, identity) in self.fixtures.items():
            with self.subTest(workload=workload):
                self.assertEqual(
                    identity,
                    VALIDATION.KITTEN_FEED_FIXTURE_IDENTITIES[workload],
                )

    def test_each_arm_carries_its_own_payload_and_no_other_arms(self):
        # Intent: the bytes generated for a workload are that arm's stream -- its
        #   description string, its length, and no other arm's description.
        # Why it exists: four arms come out of one executable, told apart only by
        #   the argument each is generated with. A routing error there would leave
        #   two workloads measuring one stimulus while reporting two verdicts.
        # Scenario: spec-first; research 39 requires a verdict per arm, so two arms
        #   quietly sharing a stream would be worse than either arm missing.
        for workload, (framed, _identity) in self.fixtures.items():
            description, length = ARM_CHARACTERISTICS[workload]
            with self.subTest(workload=workload):
                self.assertEqual(len(framed), length)
                self.assertIn(f"Running: {description}\r\n".encode(), framed)
                for other, (other_description, _) in ARM_CHARACTERISTICS.items():
                    if other != workload:
                        self.assertNotIn(other_description.encode(), framed)

    def test_the_measurement_path_accepts_every_arm(self):
        # Intent: each arm's three framed portions decode and feed through the same
        #   harness `terminal-feed` blocks are collected with.
        # Why it exists: the arms claim `terminal-feed`'s block contract on the
        #   grounds that only the byte source differs. A stream the harness cannot
        #   decode -- a phase byte it does not know, a length it disagrees with --
        #   would break that claim at collection time rather than here.
        # Scenario: spec-first; one fixed execution per arm, which is the same call
        #   the collector makes for a measured block.
        for workload, (framed, _identity) in self.fixtures.items():
            with self.subTest(workload=workload):
                completed = subprocess.run(
                    [
                        "swift", "run",
                        "--package-path", str(BENCHMARK_PACKAGE),
                        "TerminalCoreBenchmark",
                        "--fixed", "1", "1",
                    ],
                    input=framed,
                    capture_output=True,
                )
                self.assertEqual(
                    completed.returncode,
                    0,
                    completed.stderr.decode(errors="replace"),
                )
                measured = json.loads(completed.stdout)
                self.assertEqual(measured["batchCount"], 1)
                self.assertEqual(len(measured["feedDurationNanoseconds"]), 1)
                self.assertGreater(measured["feedDurationNanoseconds"][0], 0)


if __name__ == "__main__":
    unittest.main()
