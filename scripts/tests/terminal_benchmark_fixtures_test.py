#!/usr/bin/env python3
"""One question: can the corpus loader be trusted to hand the producer real bytes?

The loader is the only thing between a committed fixture and a benchmark block,
and both of its failure modes are silent. A recording that decompresses wrong
produces a stimulus nobody notices is different; a recording that ends inside an
open synchronized-output bracket produces a block that never draws and hangs the
harness with no error. This file exists so neither can reach a run.
"""
import gzip
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from terminal_benchmark_fixtures import iter_bytes, load_corpus  # noqa: E402


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SYNCHRONIZED_BEGIN = b"\x1b[?2026h"
SYNCHRONIZED_END = b"\x1b[?2026l"


class RecordingLoaderTests(unittest.TestCase):
    def test_a_gzipped_recording_yields_the_bytes_its_plain_form_yields(self):
        # Intent: a `.json.gz` recording replays byte-for-byte identically to the
        #   same document stored uncompressed.
        # Why it exists: compression exists only to make a real capture committable
        #   -- a 1.25 MB stimulus is 6.2 MB as JSON hex and 149 KB gzipped. The
        #   moment it changes even one delivered byte it has stopped being the
        #   same stimulus, and nothing downstream would report that.
        # Scenario: spec-first; the corpus gains its first captured workload, and
        #   the committed artifact has to be both small and exact.
        document = {
            "dimensions": {"columns": 179, "rows": 66},
            "events": [
                {"type": "feed", "hex": "1b5b3f3230323668"},
                {"type": "feed", "hex": "616263"},
                {"type": "feed", "hex": "1b5b3f323032366c"},
            ],
        }
        expected = b"\x1b[?2026habc\x1b[?2026l"
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "plain.json").write_text(json.dumps(document), encoding="utf-8")
            (root / "packed.json.gz").write_bytes(
                gzip.compress(json.dumps(document).encode("utf-8"))
            )
            plain = b"".join(iter_bytes(root, {"recording": "plain.json"}))
            packed = b"".join(iter_bytes(root, {"recording": "packed.json.gz"}))
        self.assertEqual(plain, expected)
        self.assertEqual(packed, expected)


    def test_a_replay_count_repeats_the_capture_without_disturbing_its_shape(self):
        # Intent: `replayCount: N` delivers the recording's bytes N times, and the
        #   repeated stream still begins and ends where one pass does.
        # Why it exists: `20/F12` found this workload's block noise is additive --
        #   a roughly fixed per-run wobble over a growing denominator -- so a
        #   longer block is the lever on its threshold, and repeating the capture
        #   is the way to lengthen it without a second capture session. The
        #   repetition is only valid if it changes nothing but duration: it must
        #   stay bracket-balanced (else `planIfNeeded` suppresses every later draw
        #   and the harness hangs) and must end in the same final frame the
        #   completion assertion is written against.
        # Scenario: spec-first; `20/D5` needs a length knob that a negative result
        #   can be trusted to have exercised honestly.
        document = {
            "dimensions": {"columns": 179, "rows": 66},
            "events": [
                {"type": "feed", "hex": "1b5b3f3230323668"},
                {"type": "feed", "hex": "616263"},
                {"type": "feed", "hex": "1b5b3f323032366c"},
            ],
        }
        one = b"\x1b[?2026habc\x1b[?2026l"
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "plain.json").write_text(json.dumps(document), encoding="utf-8")
            single = b"".join(iter_bytes(root, {"recording": "plain.json"}))
            fivefold = b"".join(
                iter_bytes(root, {"recording": "plain.json", "replayCount": 5})
            )
        self.assertEqual(single, one, "an absent replayCount must mean one pass")
        self.assertEqual(fivefold, one * 5)
        # The two properties a longer block must not break, asserted on behaviour
        # rather than on the concatenation above: still bracket-balanced, and the
        # stream still ends on the same trailing bytes one pass ends on.
        self.assertGreater(
            fivefold.rfind(SYNCHRONIZED_END), fivefold.rfind(SYNCHRONIZED_BEGIN)
        )
        self.assertTrue(fivefold.endswith(one[-len(SYNCHRONIZED_END) :]))


class CommittedRecordingTests(unittest.TestCase):
    def test_every_recording_workload_closes_its_last_synchronized_bracket(self):
        # Intent: no committed recording ends while synchronized output is still
        #   enabled.
        # Why it exists: `TerminalPaneSession.planIfNeeded` returns early whenever
        #   `isSynchronizedOutputActive`, so a stimulus that ends mid-bracket
        #   suppresses every subsequent plan and draw. The producer's completion
        #   marker would then never render, the harness would wait for a draw that
        #   cannot happen, and the failure looks like a hang rather than a bad
        #   fixture. A capture is trimmed by hand to a frame boundary, which is
        #   exactly the step a human gets wrong.
        # Scenario: spec-first; guards the trim step of every future capture, not
        #   just the first one.
        corpus = load_corpus(ROOT)
        recordings = {
            name: workload
            for name, workload in corpus.items()
            if "recording" in workload
        }
        self.assertNotEqual(recordings, {}, "corpus has no recording workloads")
        for name, workload in recordings.items():
            with self.subTest(workload=name):
                data = b"".join(iter_bytes(ROOT, workload))
                begin = data.rfind(SYNCHRONIZED_BEGIN)
                end = data.rfind(SYNCHRONIZED_END)
                if begin == -1:
                    continue
                self.assertGreater(
                    end,
                    begin,
                    "recording ends inside an open synchronized-output bracket, "
                    "which suppresses every draw after it",
                )


if __name__ == "__main__":
    unittest.main()
