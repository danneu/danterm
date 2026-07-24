#!/usr/bin/env python3
"""Behavioral tests for benchmark aggregation and compatible history lookup."""
import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
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
    def make_result(self, workload="scrollback-stream", iterations=3):
        return {
            "schemaVersion": 2,
            "backend": "swift",
            "workload": workload,
            "fixture": {"identity": f"{workload}-v1"},
            "machine": {"model": "model", "chip": "chip"},
            "macOS": "15.5",
            "displayScale": 2.0,
            "toolchain": "Swift 6.1",
            "buildConfiguration": "release",
            "geometry": {"columns": 80, "rows": 24},
            "profilingActive": False,
            "iterations": iterations,
            "summary": {
                "iterations": iterations,
                "producerWriteNanoseconds": {"min": 75, "median": 75, "max": 75},
                "finalDrawNanoseconds": {"available": True, "min": 100, "median": 100, "max": 100},
            },
        }

    def test_corpus_loads_every_provenance_bearing_workload(self):
        corpus = FIXTURES.load_corpus(ROOT)

        self.assertEqual(
            tuple(corpus),
            (
                "scrollback-stream",
                "styled-screen-redraw",
                "unicode-wrapping",
                "incremental-screen-updates",
            ),
        )
        for workload in corpus.values():
            self.assertTrue(workload["identity"])
            self.assertTrue(workload["provenance"]["source"])
            self.assertTrue(workload["provenance"]["license"])

    def test_each_workload_pins_the_major_performance_question_it_answers(self):
        corpus = FIXTURES.load_corpus(ROOT)

        self.assertEqual(
            {name: workload["dominantQuestion"] for name, workload in corpus.items()},
            {
                "scrollback-stream": "How fast can sustained output be consumed, scrolled, and retained?",
                "styled-screen-redraw": "How fast can styled TUI output be consumed when intermediate screen states may coalesce?",
                "unicode-wrapping": "How expensive is complex text flowing and wrapping through the grid?",
                "incremental-screen-updates": "How efficiently can localized TUI updates avoid full-screen work?",
            },
        )

    def test_workload_streams_exercise_their_dominant_behavior(self):
        corpus = FIXTURES.load_corpus(ROOT)
        streams = {
            name: b"".join(FIXTURES.iter_bytes(ROOT, workload))
            for name, workload in corpus.items()
        }

        self.assertGreater(streams["scrollback-stream"].count(b"\n"), 10_000)
        self.assertIn(b"\x1b[H", streams["styled-screen-redraw"])
        self.assertIn(b"\x1b[38;2;", streams["styled-screen-redraw"])
        self.assertIn("\u4f60\u597d\u4e16\u754c".encode(), streams["unicode-wrapping"])
        self.assertIn("cafe\u0301".encode(), streams["unicode-wrapping"])
        self.assertIn(b"\x1b[2;23r", streams["incremental-screen-updates"])
        self.assertIn(b"\x1b[@", streams["incremental-screen-updates"])
        self.assertIn(b"\x1b[P", streams["incremental-screen-updates"])

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
        self.assertEqual(SUITE.parse_backend("backend=swift-core"), "swift-core")

    def test_core_compatibility_omits_app_environment_and_ignores_comment(self):
        current = {
            "schemaVersion": 3,
            "backend": "swift-core",
            "workload": "scrollback-stream",
            "fixture": {"identity": "scrollback-stream-v1"},
            "machine": {"model": "model", "chip": "chip"},
            "toolchain": "Swift 6.3",
            "buildConfiguration": "release",
            "profilingActive": False,
            "iterations": 3,
            "benchmarkMethod": "fresh-terminal-batch-v1",
            "comment": "after damage bitset",
        }
        previous = {**current, "comment": "baseline", "commit": "previous"}
        app = {
            **current,
            "backend": "swift",
            "displayScale": 2,
            "geometry": {"columns": 80, "rows": 24},
            "macOS": "26.5",
            "commit": "app",
        }

        self.assertNotIn("comment", SUITE.compatibility_key(current))
        self.assertEqual(
            SUITE.latest_compatible_lines([json.dumps(previous)], current)["commit"],
            "previous",
        )
        self.assertIsNone(SUITE.latest_compatible_lines([json.dumps(app)], current))

        old_method = {key: value for key, value in previous.items() if key != "benchmarkMethod"}
        self.assertIsNone(SUITE.latest_compatible_lines([json.dumps(old_method)], current))

    def test_core_summary_and_report_use_only_feed_duration(self):
        result = self.make_result()
        result["backend"] = "swift-core"
        result["summary"] = {
            "iterations": 3,
            "feedDurationNanoseconds": {"min": 50, "median": 75, "max": 100},
        }
        baseline = {
            **result,
            "summary": {
                "iterations": 3,
                "feedDurationNanoseconds": {"min": 80, "median": 100, "max": 120},
            },
        }

        with io.StringIO() as output, redirect_stdout(output):
            SUITE.report(result, baseline)
            printed = output.getvalue()

        self.assertIn("delta feedDurationNanoseconds: -25.00%", printed)
        self.assertNotIn("producerWriteNanoseconds", printed.splitlines()[-1])

    def test_core_result_omits_app_only_environment_fields_and_accepts_comment(self):
        with mock.patch.object(SUITE, "command_output", return_value="value"), mock.patch.object(
            SUITE, "machine_identity", return_value={"model": "model", "chip": "chip"}
        ):
            result = SUITE.make_result(
                "scrollback-stream",
                "swift-core",
                {
                    "batchCount": 7,
                    "feedDurationNanoseconds": [30, 10, 20],
                    "sampleDurationNanoseconds": [210, 70, 140],
                },
                comment="dirty baseline",
            )

        self.assertEqual(result["comment"], "dirty baseline")
        self.assertEqual(
            result["summary"],
            {
                "iterations": 3,
                "batchCount": 7,
                "feedDurationNanoseconds": {"min": 10, "median": 20, "max": 30},
            },
        )
        self.assertEqual(result["benchmarkMethod"], "fresh-terminal-batch-v1")
        for field in ("displayScale", "geometry", "macOS"):
            self.assertNotIn(field, result)

    def test_core_runner_length_frames_fixture_chunks_for_the_swift_harness(self):
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=(
                b'{"batchCount":2,"feedDurationNanoseconds":[1000000000,1100000000,1200000000],'
                b'"sampleDurationNanoseconds":[2000000000,2200000000,2400000000]}\n'
            ),
            stderr=b"",
        )
        with mock.patch.object(SUITE, "iter_bytes", return_value=iter((b"abc", b"de"))), mock.patch.object(
            SUITE.subprocess, "run", return_value=completed
        ) as run:
            measurements = SUITE.run_core_workload("scrollback-stream", 3)

        self.assertEqual(measurements["batchCount"], 2)
        self.assertEqual(
            measurements["feedDurationNanoseconds"],
            [1_000_000_000, 1_100_000_000, 1_200_000_000],
        )
        self.assertTrue(all(
            duration >= SUITE.CORE_SAMPLE_TARGET_NANOSECONDS
            for duration in measurements["sampleDurationNanoseconds"]
        ))
        self.assertEqual(
            run.call_args.kwargs["input"],
            (3).to_bytes(8, "big") + b"abc" + (2).to_bytes(8, "big") + b"de",
        )

    def test_comment_is_optional_and_parsed_as_free_text(self):
        self.assertEqual(
            SUITE.parse_arguments(["swift-core", "comment=dirty tree baseline"]),
            ("swift-core", None, None, "dirty tree baseline"),
        )
        self.assertEqual(
            SUITE.parse_arguments(["swift", "save=0"]),
            ("swift", None, False, None),
        )

    def test_arguments_select_save_policy_and_workload(self):
        self.assertEqual(SUITE.parse_arguments(["backend=swift", "save=1"]), ("swift", None, True, None))
        self.assertEqual(
            SUITE.parse_arguments(["save=1", "workload=unicode-wrapping", "backend=ghostty"]),
            ("ghostty", "unicode-wrapping", True, None),
        )
        self.assertEqual(SUITE.parse_arguments(["swift", "save=0"]), ("swift", None, False, None))
        self.assertEqual(
            SUITE.parse_arguments(["unicode-wrapping", "ghostty", "1"]),
            ("ghostty", "unicode-wrapping", True, None),
        )
        self.assertEqual(
            SUITE.parse_arguments(["default-workload=scrollback-stream", "backend=ghostty"]),
            ("ghostty", "scrollback-stream", None, None),
        )
        self.assertEqual(
            SUITE.parse_arguments([
                "default-workload=scrollback-stream",
                "workload=unicode-wrapping",
                "backend=ghostty",
            ]),
            ("ghostty", "unicode-wrapping", None, None),
        )
        self.assertEqual(
            SUITE.parse_arguments(["swift", "workload=scrollback-stream", "save="]),
            ("swift", "scrollback-stream", None, None),
        )
        with self.assertRaisesRegex(ValueError, "save must be 0 or 1"):
            SUITE.parse_arguments(["swift", "save=yes"])
        with self.assertRaisesRegex(ValueError, "unknown benchmark workload"):
            SUITE.parse_arguments(["swift", "workload=not-committed"])
        with self.assertRaisesRegex(ValueError, "backend specified more than once"):
            SUITE.parse_arguments(["backend=swift", "backend=ghostty"])

    def test_prompt_accepts_only_trimmed_yes_answers(self):
        for answer in ("y", "Y", "yes", " YES "):
            with self.subTest(answer=answer), mock.patch("builtins.input", return_value=answer):
                self.assertTrue(SUITE.confirm_save())
        for answer in ("", "n", "maybe"):
            with self.subTest(answer=answer), mock.patch("builtins.input", return_value=answer):
                self.assertFalse(SUITE.confirm_save())
        with mock.patch("builtins.input", side_effect=EOFError):
            self.assertFalse(SUITE.confirm_save())

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
            "workload": "scrollback-stream",
            "fixture": {"identity": "scrollback-stream-v1"},
            "machine": {"model": "MacBookPro18,3", "chip": "Apple M1 Pro"},
            "macOS": "15.5",
            "displayScale": 2.0,
            "toolchain": "Swift 6.1",
            "buildConfiguration": "release",
            "geometry": {"windowWidth": 1000, "windowHeight": 600},
            "profilingActive": False,
            "iterations": 3,
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

    def test_iteration_count_is_required_for_compatibility(self):
        current = self.make_result(iterations=3)
        wrong = self.make_result(iterations=2)
        matching = self.make_result(iterations=3)
        wrong["commit"] = "wrong"
        matching["commit"] = "matching"

        self.assertEqual(
            SUITE.latest_compatible_lines([json.dumps(wrong), json.dumps(matching)], current)["commit"],
            "matching",
        )
        self.assertIsNone(SUITE.latest_compatible_lines([json.dumps(wrong)], current))

    def test_geometry_difference_is_not_compatible_but_identical_geometry_is(self):
        current = self.make_result()
        wrong = {**self.make_result(), "geometry": {"columns": 100, "rows": 30}, "commit": "wrong"}
        matching = {**self.make_result(), "commit": "matching"}

        self.assertEqual(
            SUITE.latest_compatible_lines([json.dumps(wrong), json.dumps(matching)], current)["commit"],
            "matching",
        )
        self.assertIsNone(SUITE.latest_compatible_lines([json.dumps(wrong)], current))

    def test_run_workload_rejects_geometry_other_than_requested_target(self):
        raw = json.dumps({
            "geometry": {"columns": 94, "rows": 35},
            "displayScale": 2,
            "producerWrite": {"elapsedNanoseconds": 1},
            "finalDraw": {"available": False, "reason": "test"},
        })

        with mock.patch.object(SUITE, "command_output", return_value=raw):
            with self.assertRaisesRegex(SystemExit, "required 80x24, reported 94x35"):
                SUITE.run_workload("scrollback-stream", "swift", 1)

    def test_older_schema_record_is_not_a_compatible_baseline(self):
        current = {
            "schemaVersion": 2,
            "backend": "swift",
            "workload": "scrollback-stream",
            "fixture": {"identity": "scrollback-stream-v1"},
            "machine": {"model": "model", "chip": "chip"},
            "macOS": "15.5",
            "displayScale": 2.0,
            "toolchain": "Swift 6.1",
            "buildConfiguration": "release",
            "geometry": {"columns": 80, "rows": 24},
            "profilingActive": False,
            "iterations": 3,
        }

        self.assertIsNone(SUITE.latest_compatible_lines(['{"schemaVersion":1}'], current))

    def test_baseline_is_read_from_committed_history(self):
        current = {
            "schemaVersion": 2,
            "backend": "swift",
            "workload": "scrollback-stream",
            "fixture": {"identity": "scrollback-stream-v1"},
            "machine": {"model": "model", "chip": "chip"},
            "macOS": "15.5",
            "displayScale": 2.0,
            "toolchain": "Swift 6.1",
            "buildConfiguration": "release",
            "geometry": {"columns": 80, "rows": 24},
            "profilingActive": False,
            "iterations": 3,
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

    def test_promote_staged_results_appends_verbatim(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            staged = root / "staged.jsonl"
            history = root / "history.jsonl"
            history.write_text("prior\n", encoding="utf-8")
            staged.write_text("first\nsecond\n", encoding="utf-8")

            SUITE.promote_staged(staged, history)

            self.assertEqual(history.read_text(encoding="utf-8"), "prior\nfirst\nsecond\n")

    def test_report_prints_the_frozen_result_without_reserializing(self):
        result = self.make_result()
        frozen = SUITE.serialize_result(result)

        with io.StringIO() as output, redirect_stdout(output):
            SUITE.report(result, None, serialized=frozen)
            printed = output.getvalue()

        self.assertTrue(printed.startswith(frozen))
        self.assertIn("delta: no compatible committed result", printed)

    def run_main(self, arguments, answer=None, fail_on=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = pathlib.Path(temporary.name)
        history = root / "history.jsonl"
        staging = root / "staged"
        made = []

        def run_workload(workload, backend, iterations):
            if workload == fail_on:
                raise SystemExit("workload failed")
            return [{"workload": workload}]

        def make_result(workload, backend, runs, comment=None):
            result = self.make_result(workload)
            made.append(result)
            return result

        patches = (
            mock.patch.object(SUITE.sys, "argv", ["suite", *arguments]),
            mock.patch.object(SUITE, "HISTORY_PATH", history),
            mock.patch.object(SUITE, "STAGING_ROOT", staging),
            mock.patch.object(SUITE, "run_workload", side_effect=run_workload),
            mock.patch.object(SUITE, "make_result", side_effect=make_result),
            mock.patch.object(SUITE, "latest_committed", return_value=None),
            mock.patch.object(SUITE, "report"),
            mock.patch("builtins.input", return_value=answer),
        )
        error = None
        with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6] as report, patches[7] as prompt:
            try:
                SUITE.main()
            except SystemExit as caught:
                error = caught
        return history, staging, made, report, prompt, error

    def test_prompted_yes_promotes_exact_staged_content(self):
        history, staging, made, _, prompt, error = self.run_main(
            ["swift", "workload=scrollback-stream"], answer="y"
        )

        self.assertIsNone(error)
        self.assertTrue(prompt.called)
        staged = next(staging.glob("*.jsonl"))
        self.assertEqual(history.read_bytes(), staged.read_bytes())
        self.assertEqual(json.loads(history.read_text(encoding="utf-8")), made[0])

    def test_prompted_no_keeps_staged_content_and_history_untouched(self):
        history, staging, _, _, prompt, error = self.run_main(
            ["swift", "workload=scrollback-stream"], answer="n"
        )

        self.assertIsNone(error)
        self.assertTrue(prompt.called)
        self.assertFalse(history.exists())
        self.assertEqual(len(list(staging.glob("*.jsonl"))), 1)

    def test_explicit_save_values_never_prompt(self):
        saved_history, _, _, _, saved_prompt, saved_error = self.run_main(
            ["swift", "workload=scrollback-stream", "save=1"]
        )
        declined_history, _, _, _, declined_prompt, declined_error = self.run_main(
            ["swift", "workload=scrollback-stream", "save=0"]
        )

        self.assertIsNone(saved_error)
        self.assertIsNone(declined_error)
        self.assertTrue(saved_history.exists())
        self.assertFalse(declined_history.exists())
        saved_prompt.assert_not_called()
        declined_prompt.assert_not_called()

    def test_failed_later_workload_does_not_prompt_or_touch_history(self):
        history, staging, _, _, prompt, error = self.run_main(
            ["swift"], answer="y", fail_on="styled-screen-redraw"
        )
        self.assertRegex(str(error), "workload failed")
        self.assertFalse(history.exists())
        prompt.assert_not_called()
        self.assertEqual(len(list(staging.glob("*.jsonl"))), 1)

    def test_profiled_main_exits_before_prompt_run_or_write(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.dict(SUITE.os.environ, {"DANTERM_BENCHMARK_PROFILING": "1"}), mock.patch.object(
                SUITE, "STAGING_ROOT", pathlib.Path(directory) / "staged"
            ), mock.patch.object(SUITE, "run_workload") as run, mock.patch("builtins.input") as prompt:
                with self.assertRaisesRegex(SystemExit, "Profiled runs cannot enter benchmark history"):
                    SUITE.main()
            run.assert_not_called()
            prompt.assert_not_called()
            self.assertFalse((pathlib.Path(directory) / "staged").exists())


if __name__ == "__main__":
    unittest.main()
