#!/usr/bin/env python3
"""One question: can the retained-row shape driver be trusted to report real shape?

The driver is what doc 28's `F9` and `F10` quote, and it has three ways to be
quietly wrong. It could model malloc's size classes differently from the
allocator the Swift probe asks (making every rounding number fiction); it could
frame stimulus bytes in a way the probe misreads (measuring a truncated
history); or it could count the generated bound stimulus as if it were recorded
evidence about real sessions, which is exactly the flattery `F9` was told to
avoid. This file exists so none of those can reach a finding.
"""
import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


shape = _load("terminal_retained_row_shape", "terminal-retained-row-shape.py")


class SizeClassModelTests(unittest.TestCase):
    def test_model_matches_the_allocator_the_probe_asks(self):
        """The Python size-class model must agree with libmalloc's own answer.

        The driver's whole rounding table is modelled; the probe's
        `allocatedBytes` comes from `malloc_good_size`. `derive` compares them per
        stimulus, but that comparison is only meaningful if the model is right for
        the request sizes a real row produces, which is what this sweeps.
        """
        import ctypes

        libc = ctypes.CDLL(None)
        libc.malloc_good_size.restype = ctypes.c_size_t
        libc.malloc_good_size.argtypes = [ctypes.c_size_t]
        for cells in list(range(0, 400)) + [512, 1024, 4096]:
            request = 32 + cells * 32
            self.assertEqual(
                shape.good_size(request),
                libc.malloc_good_size(request),
                f"size-class model diverged at {cells} cells",
            )

    def test_rounding_is_never_negative(self):
        for request in (1, 15, 16, 257, 1663, 1664, 5760):
            self.assertGreaterEqual(shape.good_size(request), request)


class FramingTests(unittest.TestCase):
    def test_framing_is_big_endian_length_prefixed(self):
        """Pins the framing the Swift probe decodes.

        A mismatch here does not fail loudly: the probe would decode a different
        chunk boundary and still report a plausible history.
        """
        self.assertEqual(
            shape.frame([b"ab", b"c"]),
            (2).to_bytes(8, "big") + b"ab" + (1).to_bytes(8, "big") + b"c",
        )


class StimulusTests(unittest.TestCase):
    def test_recording_stimulus_skips_non_feed_events_and_counts_them(self):
        import json
        import tempfile

        document = {
            "version": 1,
            "provenance": {"source": "test"},
            "initial": {"columns": 20, "rows": 5},
            "events": [
                {"type": "feed", "base64": "YQ=="},
                {"type": "expect", "expect": {}},
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "sample.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            stimulus = shape.recording_stimulus(path)

        self.assertEqual(stimulus["chunks"], [b"a"])
        self.assertEqual(stimulus["skippedEvents"], 1)
        self.assertEqual((stimulus["columns"], stimulus["rows"]), (20, 5))
        self.assertEqual(stimulus["kind"], "recording")

    def test_generated_stimuli_are_excluded_from_both_pools(self):
        """The bound and the reference must never count as corpus evidence.

        `F9`'s instruction was to measure real content and not hand-craft a
        stimulus that flatters `H2`. The all-blank bound exists precisely because
        it flatters `H2` maximally -- it is a ceiling, not a sample -- so a
        summary that pooled it would state the opposite of what was measured.
        """
        reports = [
            {"kind": "recording", "blankRowCount": 0, "storedCellCounts": [5, 5],
             "cellStrideBytes": 32, "columns": 80, "allocatedBytes": 2 * shape.good_size(32 + 5 * 32)},
            {"kind": "bound", "blankRowCount": 100, "storedCellCounts": [1] * 100,
             "cellStrideBytes": 32, "columns": 80, "allocatedBytes": 100 * 64},
            {"kind": "reference", "blankRowCount": 0, "storedCellCounts": [51],
             "cellStrideBytes": 32, "columns": 179, "allocatedBytes": shape.good_size(32 + 51 * 32)},
        ]
        summary = shape.summarize(reports)

        self.assertEqual(summary["all"]["stimulusCount"], 1)
        self.assertEqual(summary["all"]["blankRowCount"], 0)
        self.assertEqual(summary["recording"]["retainedRowCount"], 2)
        self.assertEqual(summary["all"]["sharedBlankCeilingBytes"], 0)

    def test_bound_stimulus_is_all_blank_lines(self):
        (bound,) = list(shape.bound_stimuli())
        self.assertEqual(bound["kind"], "bound")
        self.assertEqual(set(b"".join(bound["chunks"])), set(b"\r\n"))


if __name__ == "__main__":
    unittest.main()
