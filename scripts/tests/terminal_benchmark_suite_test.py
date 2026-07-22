#!/usr/bin/env python3
"""Behavioral tests for benchmark aggregation and compatible history lookup."""
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location(
    "terminal_benchmark_suite", ROOT / "scripts" / "terminal-benchmark-suite.py"
)
SUITE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(SUITE)

FIXTURE_SPEC = importlib.util.spec_from_file_location(
    "terminal_benchmark_fixtures", ROOT / "scripts" / "terminal_benchmark_fixtures.py"
)
FIXTURES = importlib.util.module_from_spec(FIXTURE_SPEC)
assert FIXTURE_SPEC.loader is not None
FIXTURE_SPEC.loader.exec_module(FIXTURES)


class TerminalBenchmarkSuiteTests(unittest.TestCase):
    def test_corpus_loads_every_provenance_bearing_workload(self):
        corpus = FIXTURES.load_corpus(ROOT)

        self.assertEqual(
            tuple(corpus),
            (
                "plain-scrolling",
                "long-line-wrapping",
                "unicode-mix",
                "styles-truecolor",
                "redraw-scroll-region",
                "vim-recording",
            ),
        )
        for workload in corpus.values():
            self.assertTrue(workload["identity"])
            self.assertTrue(workload["provenance"]["source"])
            self.assertTrue(workload["provenance"]["license"])

    def test_vim_workload_replays_the_existing_committed_recording(self):
        workload = FIXTURES.load_corpus(ROOT)["vim-recording"]

        chunks = list(FIXTURES.iter_bytes(ROOT, workload))

        self.assertGreater(sum(map(len, chunks)), 100_000)
        self.assertIn(b"\x1b[", b"".join(chunks))
        self.assertEqual(workload["provenance"]["pinnedCommit"], "852e971cddfabe222d2d5bcda466e130f53af207")

    def test_write_all_retries_partial_pty_writes(self):
        writes = []

        def partial_writer(file_descriptor, data):
            writes.append((file_descriptor, bytes(data)))
            return min(3, len(data))

        FIXTURES.write_all(1, b"abcdefgh", writer=partial_writer)

        self.assertEqual([data for _, data in writes], [b"abcdefgh", b"defgh", b"gh"])

    def test_suite_fixture_identities_come_from_the_committed_corpus(self):
        corpus = FIXTURES.load_corpus(ROOT)

        self.assertEqual(SUITE.CORPUS, tuple(corpus))
        self.assertEqual(
            SUITE.FIXTURES,
            {name: workload["identity"] for name, workload in corpus.items()},
        )

    def test_profiled_environment_refuses_to_write_history(self):
        with mock.patch.dict(SUITE.os.environ, {"DANTERM_BENCHMARK_PROFILING": "1"}):
            with self.assertRaisesRegex(SystemExit, "Profiled runs cannot enter benchmark history"):
                SUITE.refuse_profiled_history()

    def test_backend_accepts_just_named_argument_spelling(self):
        self.assertEqual(SUITE.parse_backend("backend=swift"), "swift")

    def test_distribution_summarizes_each_available_metric(self):
        runs = [
            {"producerWrite": {"elapsedNanoseconds": 30}, "finalDraw": {"available": True, "elapsedNanoseconds": 90}},
            {"producerWrite": {"elapsedNanoseconds": 10}, "finalDraw": {"available": True, "elapsedNanoseconds": 70}},
            {"producerWrite": {"elapsedNanoseconds": 20}, "finalDraw": {"available": True, "elapsedNanoseconds": 80}},
        ]

        self.assertEqual(
            SUITE.summarize_runs(runs),
            {
                "iterations": 3,
                "producerWriteNanoseconds": {"min": 10, "median": 20, "max": 30},
                "finalDrawNanoseconds": {"available": True, "min": 70, "median": 80, "max": 90},
            },
        )

    def test_ghostty_summary_preserves_unavailable_draw_contract(self):
        runs = [
            {"producerWrite": {"elapsedNanoseconds": 10}, "finalDraw": {"available": False, "reason": "unavailable-for-ghostty-backend"}},
            {"producerWrite": {"elapsedNanoseconds": 20}, "finalDraw": {"available": False, "reason": "unavailable-for-ghostty-backend"}},
        ]

        self.assertEqual(
            SUITE.summarize_runs(runs)["finalDrawNanoseconds"],
            {"available": False, "reason": "unavailable-for-ghostty-backend"},
        )

    def test_latest_baseline_requires_every_compatibility_field(self):
        key = {
            "schemaVersion": 2,
            "backend": "swift",
            "workload": "plain-scrolling",
            "fixture": {"identity": "plain-scrolling-v1"},
            "machine": {"model": "MacBookPro18,3", "chip": "Apple M1 Pro"},
            "macOS": "15.5",
            "displayScale": 2.0,
            "toolchain": "Swift 6.1",
            "buildConfiguration": "release",
            "geometry": {"windowWidth": 1000, "windowHeight": 600},
            "profilingActive": False,
        }
        compatible_old = {**key, "commit": "old", "summary": {"producerWriteNanoseconds": {"median": 100}}}
        wrong_scale = {**key, "displayScale": 1.0, "commit": "wrong"}
        compatible_new = {**key, "commit": "new", "summary": {"producerWriteNanoseconds": {"median": 80}}}

        with tempfile.TemporaryDirectory() as directory:
            history = pathlib.Path(directory) / "history.jsonl"
            SUITE.append_result(history, compatible_old)
            SUITE.append_result(history, wrong_scale)
            SUITE.append_result(history, compatible_new)

            self.assertEqual(SUITE.latest_compatible(history, key)["commit"], "new")

    def test_older_schema_record_is_not_a_compatible_baseline(self):
        current = {
            "schemaVersion": 2,
            "backend": "swift",
            "workload": "plain-scrolling",
            "fixture": {"identity": "plain-scrolling-v1"},
            "machine": {"model": "model", "chip": "chip"},
            "macOS": "15.5",
            "displayScale": 2.0,
            "toolchain": "Swift 6.1",
            "buildConfiguration": "release",
            "geometry": {"columns": 80, "rows": 24},
            "profilingActive": False,
        }

        self.assertIsNone(SUITE.latest_compatible_lines(['{"schemaVersion":1}'], current))

    def test_baseline_is_read_from_committed_history(self):
        current = {
            "schemaVersion": 2,
            "backend": "swift",
            "workload": "plain-scrolling",
            "fixture": {"identity": "plain-scrolling-v1"},
            "machine": {"model": "model", "chip": "chip"},
            "macOS": "15.5",
            "displayScale": 2.0,
            "toolchain": "Swift 6.1",
            "buildConfiguration": "release",
            "geometry": {"columns": 80, "rows": 24},
            "profilingActive": False,
        }
        committed = {**current, "commit": "committed"}
        completed = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=json.dumps(committed) + "\n", stderr=""
        )

        with mock.patch.object(SUITE.subprocess, "run", return_value=completed) as run:
            self.assertEqual(SUITE.latest_committed(current)["commit"], "committed")
            self.assertIn("HEAD:benchmarks/results/terminal-app.jsonl", run.call_args.args[0])

    def test_delta_reports_percentage_from_latest_compatible_median(self):
        current = {"summary": {"producerWriteNanoseconds": {"median": 75}}}
        previous = {"summary": {"producerWriteNanoseconds": {"median": 100}}}

        self.assertEqual(SUITE.delta_percent(current, previous, "producerWriteNanoseconds"), -25.0)


if __name__ == "__main__":
    unittest.main()
