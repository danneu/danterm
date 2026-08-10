#!/usr/bin/env python3
"""Behavioral tests for the sustained memory profile.

Covers reading `footprint -j` and turning a series of those snapshots into a
growth measurement. The arithmetic is the risk: a growth number computed across
the warmup, or against the wrong process in a multi-process document, is wrong
in the direction that invents a leak.
"""
import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "terminal_memory_profile",
    ROOT / "scripts" / "terminal-memory-profile.py",
)
MEMORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MEMORY)


def footprint_document(pid, footprint, categories, other_processes=()):
    """One `footprint -j` document, trimmed to the fields the report reads."""
    processes = [
        {
            "name": "DanTerm Benchmark",
            "pid": pid,
            "page size": 16384,
            "footprint": footprint,
            "categories": {
                name: {"dirty": dirty, "swapped": swapped, "clean": 4096, "regions": 1}
                for name, (dirty, swapped) in categories.items()
            },
        }
    ]
    for other_pid, other_footprint in other_processes:
        processes.append(
            {
                "name": "unrelated",
                "pid": other_pid,
                "footprint": other_footprint,
                "categories": {"MALLOC_TINY": {"dirty": 1, "swapped": 0}},
            }
        )
    return {"unit": "byte", "bytes per unit": 1, "processes": processes}


def series(values, start=0.0, step=1.0, category="MALLOC_LARGE"):
    return [
        MEMORY.Snapshot(
            elapsed=start + index * step,
            footprint=value,
            categories={category: value, "__TEXT": 500},
        )
        for index, value in enumerate(values)
    ]


class FootprintParsingTests(unittest.TestCase):
    def test_the_target_process_is_selected_by_pid(self):
        # Why it exists: `footprint` can be pointed at several processes and the
        # document always carries a list. Reading processes[0] would silently
        # measure whichever process the tool happened to order first.
        document = footprint_document(
            42, 1000, {"MALLOC_TINY": (800, 0)}, other_processes=[(99, 999999)]
        )
        snapshot = MEMORY.snapshot_from_footprint(document, pid=42, elapsed=3.0)
        self.assertEqual(snapshot.footprint, 1000)
        self.assertEqual(snapshot.elapsed, 3.0)

    def test_a_missing_pid_is_an_error_not_an_empty_snapshot(self):
        document = footprint_document(42, 1000, {"MALLOC_TINY": (800, 0)})
        with self.assertRaises(ValueError):
            MEMORY.snapshot_from_footprint(document, pid=7, elapsed=0.0)

    def test_category_cost_counts_dirty_and_swapped_but_not_clean(self):
        # Intent: a category's cost is the memory that must exist somewhere for
        #   this process -- dirty pages plus whatever of them got compressed.
        # Why it exists: clean pages are file-backed and evictable at no cost, so
        #   counting them makes a large binary look like a memory problem and
        #   masks real growth in the malloc zones underneath.
        document = footprint_document(
            42, 5000, {"MALLOC_TINY": (800, 200), "__TEXT": (0, 0)}
        )
        snapshot = MEMORY.snapshot_from_footprint(document, pid=42, elapsed=0.0)
        self.assertEqual(snapshot.categories["MALLOC_TINY"], 1000)
        self.assertEqual(snapshot.categories["__TEXT"], 0)


class GrowthTests(unittest.TestCase):
    def test_warmup_snapshots_are_excluded_from_the_baseline(self):
        # Intent: growth is measured from steady state, not from launch.
        # Why it exists: scrollback is intentionally bounded and the caches
        #   intentionally fill, so the climb during warmup is the design working.
        #   Baselining at t=0 would report that climb as growth on every run and
        #   make every workload look like it leaks.
        snapshots = series([100, 400, 900, 1000, 1000, 1000])
        summary = MEMORY.summarize_memory(snapshots, warmup_seconds=3.0)
        self.assertEqual(summary["baseline"]["footprint"], 1000)
        self.assertEqual(summary["growthBytes"], 0)
        self.assertEqual(summary["excludedWarmupSamples"], 3)

    def test_a_flat_series_reports_no_growth(self):
        summary = MEMORY.summarize_memory(series([1000] * 5), warmup_seconds=0.0)
        self.assertEqual(summary["growthBytes"], 0)
        self.assertEqual(summary["growthBytesPerSecond"], 0)

    def test_linear_growth_is_reported_as_bytes_per_second(self):
        # 500 bytes per 1-second step.
        summary = MEMORY.summarize_memory(
            series([1000, 1500, 2000, 2500], step=1.0), warmup_seconds=0.0
        )
        self.assertEqual(summary["growthBytes"], 1500)
        self.assertAlmostEqual(summary["growthBytesPerSecond"], 500.0)

    def test_the_slope_is_fitted_over_all_samples_not_just_the_endpoints(self):
        # Why it exists: endpoint-to-endpoint growth is hostage to a single noisy
        #   final sample. A spike at the end of an otherwise flat run should move
        #   the fitted slope far less than it moves the raw delta.
        spiky = series([1000, 1000, 1000, 1000, 2000], step=1.0)
        summary = MEMORY.summarize_memory(spiky, warmup_seconds=0.0)
        self.assertEqual(summary["growthBytes"], 1000)
        self.assertLess(summary["growthBytesPerSecond"], 250.0)

    def test_peak_is_reported_even_when_it_is_not_the_final_sample(self):
        summary = MEMORY.summarize_memory(
            series([1000, 5000, 1000], step=1.0), warmup_seconds=0.0
        )
        self.assertEqual(summary["peakFootprint"], 5000)
        self.assertEqual(summary["growthBytes"], 0)

    def test_categories_are_ranked_by_how_much_they_grew(self):
        # Intent: name what grew, not what is merely large. __TEXT dominates the
        #   footprint of every run and never moves.
        snapshots = [
            MEMORY.Snapshot(0.0, 10000, {"__TEXT": 9000, "MALLOC_LARGE": 1000}),
            MEMORY.Snapshot(1.0, 14000, {"__TEXT": 9000, "MALLOC_LARGE": 5000}),
        ]
        summary = MEMORY.summarize_memory(snapshots, warmup_seconds=0.0)
        self.assertEqual(summary["categoryGrowth"][0]["category"], "MALLOC_LARGE")
        self.assertEqual(summary["categoryGrowth"][0]["growthBytes"], 4000)
        self.assertNotIn("__TEXT", [row["category"] for row in summary["categoryGrowth"]])

    def test_a_category_that_appears_only_at_the_end_counts_as_full_growth(self):
        snapshots = [
            MEMORY.Snapshot(0.0, 1000, {"MALLOC_TINY": 1000}),
            MEMORY.Snapshot(1.0, 3000, {"MALLOC_TINY": 1000, "MALLOC_LARGE": 2000}),
        ]
        summary = MEMORY.summarize_memory(snapshots, warmup_seconds=0.0)
        self.assertEqual(summary["categoryGrowth"][0]["category"], "MALLOC_LARGE")
        self.assertEqual(summary["categoryGrowth"][0]["growthBytes"], 2000)

    def test_a_run_with_one_post_warmup_sample_cannot_measure_growth(self):
        # Why it exists: one point is a measurement of nothing, and reporting
        #   growth of 0 from it would be indistinguishable from a flat run.
        # elapsed 0.0, 1.0, 2.0 against a 1.5s warmup leaves only the last point.
        with self.assertRaises(ValueError):
            MEMORY.summarize_memory(series([1000, 2000, 3000]), warmup_seconds=1.5)

    def test_the_full_series_is_preserved_for_a_reader_who_wants_the_curve(self):
        summary = MEMORY.summarize_memory(series([100, 200, 300, 400]), warmup_seconds=1.5)
        self.assertEqual(len(summary["series"]), 4)
        self.assertEqual(
            [point["warmup"] for point in summary["series"]], [True, True, False, False]
        )


if __name__ == "__main__":
    unittest.main()
