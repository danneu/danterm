#!/usr/bin/env python3
"""Behavioral tests for the machine-readable profile report.

Covers the two parsers that turn a human-facing profiler artifact into samples
(`xctrace` time-profile XML and `sample` call-graph text) and the aggregation
that both feed. The parsers are the whole risk surface: everything downstream
is arithmetic over their output, and a silently mis-parsed tree still produces
a plausible-looking report.
"""
import collections
import importlib.util
import json
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "terminal_profile_report",
    ROOT / "scripts" / "terminal-profile-report.py",
)
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)


# One `xctrace export --xpath '...table[@schema="time-profile"]'` document, cut to
# three rows. Row 2 exercises the id/ref interning that the real export uses for
# every repeated frame, thread, and weight; row 3 introduces a second thread.
XCTRACE_XML = """<?xml version="1.0"?>
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[13]'>
<schema name="time-profile"/>
<row>
  <sample-time id="1" fmt="00:00.254.775">254775333</sample-time>
  <thread id="2" fmt="Main Thread (0x1) (DanTerm Benchmark, pid: 100)"/>
  <core id="7" fmt="CPU 4 (P Core)">4</core>
  <thread-state id="8" fmt="Running">Running</thread-state>
  <weight id="9" fmt="1.00 ms">1000000</weight>
  <tagged-backtrace id="10" fmt="leafA">
    <backtrace id="11">
      <frame id="12" name="leafA" addr="0x1"><binary id="13" name="DanTerm Benchmark"/></frame>
      <frame id="14" name="middle" addr="0x2"><binary ref="13"/></frame>
      <frame id="15" name="root" addr="0x3"><binary ref="13"/></frame>
    </backtrace>
  </tagged-backtrace>
</row>
<row>
  <sample-time id="16" fmt="00:00.255.775">255775333</sample-time>
  <thread ref="2"/>
  <core ref="7"/>
  <thread-state ref="8"/>
  <weight ref="9"/>
  <tagged-backtrace id="17" fmt="leafB">
    <backtrace id="18">
      <frame id="19" name="leafB" addr="0x4"><binary id="20" name="libsystem_kernel.dylib"/></frame>
      <frame ref="14"/>
      <frame ref="15"/>
    </backtrace>
  </tagged-backtrace>
</row>
<row>
  <sample-time id="21" fmt="00:00.256.775">256775333</sample-time>
  <thread id="22" fmt="PTY Thread (0x2) (DanTerm Benchmark, pid: 100)"/>
  <core ref="7"/>
  <thread-state id="23" fmt="Blocked">Blocked</thread-state>
  <weight id="24" fmt="2.00 ms">2000000</weight>
  <tagged-backtrace id="25" fmt="leafA">
    <backtrace id="26">
      <frame ref="12"/>
      <frame ref="15"/>
    </backtrace>
  </tagged-backtrace>
</row>
</node>
</trace-query-result>
"""


# A `sample` call graph cut to one thread. Counts are inclusive, so `root` holds
# 10 while owning only 1 itself; the tree-drawing characters (+ ! : |) carry the
# depth and must not leak into symbol names.
SAMPLE_TEXT = """Analysis of sampling DanTerm Benchmark (pid 34421) every 1 millisecond
Process:         DanTerm Benchmark [34421]

Call graph:
    10 Thread_38913179: Main Thread   DispatchQueue_<multiple>
    + 10 root  (in DanTerm Benchmark) + 5136  [0x1045eb2dc]  /app/main.swift:120
    + ! 6 middle  (in DanTerm Benchmark) + 368  [0x193be313c]
    + ! : 4 leafA  (in DanTerm Benchmark) + 72  [0x1947855bc]
    + ! : 2 leafB  (in libsystem_kernel.dylib) + 24  [0x18f6c1fc0]
    + ! 3 other  (in AppKit) + 688  [0x1947858b0]
    1 Thread_38913438 DispatchQueue_2: com.apple.libdispatch-manager
      1 start_wqthread  (in libsystem_pthread.dylib) + 8  [0x18f700c10]
        1 _pthread_wqthread  (in libsystem_pthread.dylib) + 348  [0x18f7015a4]
          1 kevent_id  (in libsystem_kernel.dylib) + 8  [0x18f6c3a74]

Binary Images:
       0x1045e8000 -        0x104fa3fff +DanTerm Benchmark (0.0.84)
"""


class XctraceParserTests(unittest.TestCase):
    def test_interned_refs_resolve_to_the_frames_they_point_at(self):
        # Intent: a `<frame ref="14"/>` yields the same frame as the `id="14"`
        #   definition it points back to.
        # Why it exists: xctrace emits each repeated frame, thread, and weight
        #   exactly once and refers to it by id thereafter -- in a real trace the
        #   overwhelming majority of frames are refs. Dropping them would silently
        #   truncate almost every stack to its leaf and still report totals.
        samples = REPORT.parse_xctrace_time_profile(XCTRACE_XML)
        self.assertEqual(len(samples), 3)
        self.assertEqual(
            [frame.symbol for frame in samples[1].stack], ["root", "middle", "leafB"]
        )
        self.assertEqual(samples[1].stack[-1].binary, "libsystem_kernel.dylib")
        self.assertEqual(samples[1].weight, 1000000)
        self.assertEqual(samples[1].thread, samples[0].thread)

    def test_stacks_are_reported_root_first(self):
        # Intent: parsed stacks read outermost-to-innermost, the order folded
        #   stacks and flame graphs require. xctrace stores them leaf-first.
        samples = REPORT.parse_xctrace_time_profile(XCTRACE_XML)
        self.assertEqual(
            [frame.symbol for frame in samples[0].stack], ["root", "middle", "leafA"]
        )

    def test_thread_and_state_travel_with_each_sample(self):
        samples = REPORT.parse_xctrace_time_profile(XCTRACE_XML)
        self.assertIn("PTY Thread", samples[2].thread)
        self.assertEqual(samples[2].state, "Blocked")
        self.assertEqual(samples[2].weight, 2000000)


class SampleParserTests(unittest.TestCase):
    def test_inclusive_counts_become_self_weights(self):
        # Intent: `sample` prints inclusive counts per node; the report needs the
        #   self weight, which is the node's count minus its children's.
        # Why it exists: treating the printed count as self weight would credit
        #   every caller with all of its callees' time, making the deepest common
        #   ancestor look like the hot frame in every profile.
        samples = REPORT.parse_sample_call_graph(SAMPLE_TEXT)
        by_leaf = {sample.stack[-1].symbol: sample.weight for sample in samples}
        self.assertEqual(by_leaf["leafA"], 4)
        self.assertEqual(by_leaf["leafB"], 2)
        self.assertEqual(by_leaf["other"], 3)
        # root holds 10 inclusive over children summing to 9, so it owns 1.
        self.assertEqual(by_leaf["root"], 1)
        # middle's 6 is fully accounted for by leafA + leafB, so it owns nothing.
        self.assertNotIn("middle", by_leaf)

    def test_tree_drawing_characters_do_not_leak_into_symbols(self):
        samples = REPORT.parse_sample_call_graph(SAMPLE_TEXT)
        for sample in samples:
            for frame in sample.stack:
                self.assertNotRegex(frame.symbol, r"[+!:|]")
                self.assertNotIn("(in ", frame.symbol)
                self.assertNotIn("[0x", frame.symbol)

    def test_depth_comes_from_the_prefix_width(self):
        samples = REPORT.parse_sample_call_graph(SAMPLE_TEXT)
        deepest = max(samples, key=lambda sample: len(sample.stack))
        self.assertEqual(
            [frame.symbol for frame in deepest.stack], ["root", "middle", "leafA"]
        )

    def test_thread_header_becomes_the_thread_label_not_a_frame(self):
        samples = REPORT.parse_sample_call_graph(SAMPLE_TEXT)
        main_thread = [s for s in samples if "Main Thread" in s.thread]
        self.assertEqual(len(main_thread), 4)
        self.assertTrue(all(sample.stack[0].symbol == "root" for sample in main_thread))

    def test_a_thread_with_no_branching_still_parses_as_one_stack(self):
        # Intent: a thread whose call graph never forks is indented with plain
        #   spaces -- `sample` only draws + ! : | where a branch exists -- and its
        #   frames are still frames.
        # Why it exists: keying "is this a thread header" off the absence of tree
        #   characters silently reclassified every frame of every single-chain
        #   thread as its own thread. Caught against a real 25-thread capture,
        #   where it dropped four samples and invented six phantom threads.
        samples = REPORT.parse_sample_call_graph(SAMPLE_TEXT)
        libdispatch = [s for s in samples if "libdispatch-manager" in s.thread]
        self.assertEqual(len(libdispatch), 1)
        self.assertEqual(
            [frame.symbol for frame in libdispatch[0].stack],
            ["start_wqthread", "_pthread_wqthread", "kevent_id"],
        )
        self.assertEqual(libdispatch[0].weight, 1)

    def test_every_thread_header_count_is_fully_accounted_for(self):
        # Why it exists: the whole report is a share-of-total, so any sample the
        #   parser drops or double-counts skews every percentage in it. The
        #   header counts are sample's own inclusive totals, so they are the
        #   independent check.
        samples = REPORT.parse_sample_call_graph(SAMPLE_TEXT)
        by_thread = collections.Counter()
        for sample in samples:
            by_thread[sample.thread] += sample.weight
        self.assertEqual(sum(by_thread.values()), 11)
        self.assertEqual(
            [weight for name, weight in by_thread.items() if "Main Thread" in name], [10]
        )

    def test_binary_images_section_is_not_parsed_as_stacks(self):
        # Why it exists: the trailing sections of a real `sample` file contain
        #   lines that superficially resemble call-graph rows.
        samples = REPORT.parse_sample_call_graph(SAMPLE_TEXT)
        self.assertNotIn(
            "Binary Images", [frame.symbol for s in samples for frame in s.stack]
        )


class AggregationTests(unittest.TestCase):
    def test_folded_stacks_are_thread_rooted_and_semicolon_joined(self):
        # Intent: emit the folded format flamegraph.pl and speedscope consume.
        samples = REPORT.parse_sample_call_graph(SAMPLE_TEXT)
        folded = REPORT.fold(samples)
        key = next(k for k in folded if k.endswith("leafA"))
        self.assertTrue(key.startswith("Thread_38913179"))
        self.assertIn(";root;middle;leafA", key)
        self.assertEqual(folded[key], 4)

    def test_identical_stacks_from_different_samples_merge(self):
        samples = REPORT.parse_xctrace_time_profile(XCTRACE_XML)
        # Rows 1 and 3 share the leafA leaf but differ in thread and depth, so
        # folding must keep them apart rather than merging on the leaf.
        folded = REPORT.fold(samples)
        self.assertEqual(len(folded), 3)
        merged = REPORT.fold(samples + samples)
        self.assertEqual(len(merged), 3)
        self.assertEqual(sum(merged.values()), 2 * sum(folded.values()))

    def test_self_weight_ranks_leaves_and_total_weight_ranks_ancestors(self):
        # Intent: the two rankings answer different questions -- "where is time
        #   spent" versus "what is responsible for it".
        # Why it exists: an ancestor appearing twice in one recursive stack must
        #   count once toward its inclusive weight, or recursion inflates it.
        samples = REPORT.parse_xctrace_time_profile(XCTRACE_XML)
        summary = REPORT.summarize(samples, top=10)
        top_self = {entry["frame"]: entry["weight"] for entry in summary["topSelf"]}
        top_total = {entry["frame"]: entry["weight"] for entry in summary["topTotal"]}
        self.assertEqual(top_self["leafA"], 3000000)
        self.assertEqual(top_self["leafB"], 1000000)
        self.assertNotIn("root", top_self)
        self.assertEqual(top_total["root"], 4000000)
        self.assertEqual(top_total["middle"], 2000000)

    def test_recursive_stacks_count_a_frame_once_toward_inclusive_weight(self):
        frame = REPORT.Frame("recurse", "DanTerm Benchmark")
        sample = REPORT.Sample(
            weight=100, thread="T", state="Running", stack=[frame, frame, frame]
        )
        summary = REPORT.summarize([sample], top=10)
        total = {entry["frame"]: entry["weight"] for entry in summary["topTotal"]}
        self.assertEqual(total["recurse"], 100)

    def test_summary_totals_and_shares_are_reported_per_thread(self):
        samples = REPORT.parse_xctrace_time_profile(XCTRACE_XML)
        summary = REPORT.summarize(samples, top=10)
        self.assertEqual(summary["totals"]["samples"], 3)
        self.assertEqual(summary["totals"]["weight"], 4000000)
        threads = {entry["thread"]: entry for entry in summary["threads"]}
        pty = next(entry for name, entry in threads.items() if "PTY" in name)
        self.assertEqual(pty["weight"], 2000000)
        self.assertAlmostEqual(pty["share"], 0.5)

    def test_state_filter_keeps_only_matching_samples(self):
        # Why it exists: a blocked thread's stack is where it parked, not where it
        #   burned CPU; mixing the two is the classic misread of a wall-clock
        #   profile, so the report has to be able to exclude it.
        samples = REPORT.parse_xctrace_time_profile(XCTRACE_XML)
        running = REPORT.filter_samples(samples, states=["Running"])
        self.assertEqual(len(running), 2)
        self.assertTrue(all(sample.state == "Running" for sample in running))

    def test_thread_filter_matches_on_substring(self):
        samples = REPORT.parse_xctrace_time_profile(XCTRACE_XML)
        pty = REPORT.filter_samples(samples, threads=["PTY"])
        self.assertEqual(len(pty), 1)

    def test_empty_input_summarizes_without_dividing_by_zero(self):
        summary = REPORT.summarize([], top=10)
        self.assertEqual(summary["totals"]["samples"], 0)
        self.assertEqual(summary["totals"]["weight"], 0)
        self.assertEqual(summary["topSelf"], [])


class WriteTests(unittest.TestCase):
    def _run(self, directory, *flags):
        source = directory / "sample.txt"
        source.write_text(SAMPLE_TEXT)
        REPORT.main([str(source), "--quiet", *flags])
        return source

    def test_a_run_writes_both_artifacts_beside_its_source(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = pathlib.Path(raw)
            self._run(directory)
            report = json.loads((directory / "profile-report.json").read_text())
            self.assertEqual(report["source"]["weightUnit"], "samples")
            self.assertTrue(report["source"]["profiledTimingsAreDiagnosticOnly"])
            self.assertIn(";root;middle;leafA", (directory / "profile-folded.txt").read_text())

    def test_a_filtered_run_does_not_overwrite_the_unfiltered_report(self):
        # Why it exists: a filtered view answers a narrower question than the
        #   capture did. Clobbering the full report with it would leave a later
        #   reader computing shares against a subset without knowing it.
        with tempfile.TemporaryDirectory() as raw:
            directory = pathlib.Path(raw)
            self._run(directory)
            full = json.loads((directory / "profile-report.json").read_text())
            self._run(directory, "--thread", "libdispatch-manager")
            self.assertEqual(
                json.loads((directory / "profile-report.json").read_text()), full
            )
            filtered = json.loads((directory / "profile-report-filtered.json").read_text())
            self.assertEqual(filtered["source"]["threadFilter"], ["libdispatch-manager"])
            self.assertEqual(filtered["totals"]["weight"], 1)


class EmptyInputTests(unittest.TestCase):
    EMPTY_EXPORT = """<?xml version="1.0"?>
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[1]'><schema name="time-profile"/></node>
</trace-query-result>
"""

    def test_an_export_with_no_rows_fails_instead_of_writing_an_empty_report(self):
        # Intent: a capture that yielded no samples is a failed profiling run, and
        #   the exit status has to say so.
        # Why it exists: recording with a non-Time-Profiler template (Allocations,
        #   Leaks) produces a trace with no time-profile table at all, so the export
        #   comes back empty. The report happily printed "samples: 0" and wrote a
        #   zero-filled JSON -- a caller reading only the artifacts would take that
        #   for a profile of an idle process rather than a capture of nothing.
        with tempfile.TemporaryDirectory() as raw:
            directory = pathlib.Path(raw)
            source = directory / "time-profile.xml"
            source.write_text(self.EMPTY_EXPORT)
            with self.assertRaises(SystemExit) as caught:
                REPORT.main([str(source), "--quiet"])
            self.assertNotEqual(caught.exception.code, 0)
            self.assertFalse((directory / "profile-report.json").exists())

    def test_a_filter_matching_nothing_says_so_rather_than_reporting_zero(self):
        # Why it exists: distinguishing "the capture is empty" from "your filter
        #   excluded everything" is the difference between rerunning the profile
        #   and fixing the argument.
        with tempfile.TemporaryDirectory() as raw:
            directory = pathlib.Path(raw)
            source = directory / "sample.txt"
            source.write_text(SAMPLE_TEXT)
            with self.assertRaises(SystemExit) as caught:
                REPORT.main([str(source), "--quiet", "--thread", "no-such-thread"])
            self.assertIn("no-such-thread", str(caught.exception))
            self.assertFalse((directory / "profile-report-filtered.json").exists())


class FormatDetectionTests(unittest.TestCase):
    def test_xctrace_xml_and_sample_text_are_told_apart_by_content(self):
        # Why it exists: the runner points the report at whichever artifact the
        #   profiling mode produced; misdetecting one as the other yields an empty
        #   report rather than an error.
        self.assertEqual(REPORT.detect_format(XCTRACE_XML), "xctrace")
        self.assertEqual(REPORT.detect_format(SAMPLE_TEXT), "sample")

    def test_unrecognized_text_is_rejected(self):
        with self.assertRaises(ValueError):
            REPORT.detect_format("hello world\n")


if __name__ == "__main__":
    unittest.main()
