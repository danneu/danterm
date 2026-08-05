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


def make_report(kind, stored, *, blank=0, columns=80, styled=None, runs=None,
                multi=None, utf8=None, max_scalar=None, hyperlinks=None,
                wide=None):
    """Build a probe-shaped report for the reductions to chew on.

    Composition defaults to plain single-scalar ASCII printed left to right, so a
    test that cares about one axis states only that axis and the rest stay at the
    shape a plain row really has.

    Note what is *not* defaulted to zero any more: `hyperlinkCellCounts` was, and
    that is precisely how a candidate charging nothing for hyperlink metadata
    survived review. A default of zero on an axis is a fixture that cannot fail.
    """
    count = len(stored)
    zeros = [0] * count
    return {
        "stimulus": f"synthetic/{kind}",
        "kind": kind,
        "columns": columns,
        "rows": 24,
        "cellStrideBytes": 32,
        "blankRowCount": blank,
        "storedCellCounts": list(stored),
        "allocatedBytes": sum(shape.good_size(32 + n * 32) for n in stored),
        "composition": {
            "styledCellCounts": list(styled) if styled else zeros,
            "multiScalarCellCounts": list(multi) if multi else zeros,
            "emptyScalarCellCounts": zeros,
            "scalarCounts": list(stored),
            "nonASCIIScalarCounts": zeros,
            "utf8ByteCounts": list(utf8) if utf8 else list(stored),
            "styleRunCounts": list(runs) if runs else [1] * count,
            "distinctStyleCounts": [1] * count,
            "wideCellCounts": list(wide) if wide else zeros,
            "hyperlinkCellCounts": list(hyperlinks) if hyperlinks else zeros,
            "maxSingleScalarValues": list(max_scalar) if max_scalar else [ord("x")] * count,
        },
    }


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
            make_report("recording", [5, 5], blank=0, columns=80),
            make_report("bound", [1] * 100, blank=100, columns=80),
            make_report("reference", [51], blank=0, columns=179),
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

    def test_saturated_replays_are_pooled_apart_from_recorded_evidence(self):
        """A repeated replay is depth, not frequency, and must not pool as evidence.

        `F11` reads styled content at depth off replays that were repeated until
        the budget filled. Their *content* is committed, but how often such content
        reaches depth is manufactured by the repetition -- so pooling them with the
        recordings would turn a question about cost into a claim about incidence.
        """
        reports = [
            make_report("recording", [5]),
            make_report("saturated", [5] * 100),
        ]
        summary = shape.summarize(reports)

        self.assertEqual(summary["recording"]["retainedRowCount"], 1)
        self.assertEqual(summary["all"]["retainedRowCount"], 1)
        self.assertEqual(summary["saturated"]["retainedRowCount"], 100)


class ChargeModelTests(unittest.TestCase):
    def test_row_charge_reproduces_the_engine_charges_the_findings_quote(self):
        """`row_charge` must be the budget's charge, not a lookalike.

        `F9` states two charges measured against the engine: a blank retained row
        costs 80 B and a 55-cell content row at saturation costs 1,808 B. Every
        depth number `F11` and `D5` state is this function divided into the budget,
        so if it drifts from the engine's `scrollbackByteCost` the savings stay
        plausible while the depths become fiction.
        """
        blank = make_report("recording", [1])
        content = make_report("recording", [55])

        self.assertEqual(shape.charged_bytes(blank), 80)
        self.assertEqual(shape.charged_bytes(content), 1808)

    def test_misaligned_composition_fails_loudly(self):
        """Every per-row composition array must be length-checked, not just one.

        Silent misalignment is the failure mode that would produce a complete,
        plausible, wrong table -- styled fractions attributed to the wrong rows.
        The check is swept across all eleven arrays because that is exactly how the
        three retired `contentIdentity` axes went wrong: they stopped being per row
        while the type still claimed they were.
        """
        keys = list(make_report("recording", [5, 5])["composition"])
        self.assertEqual(len(keys), 11)
        for key in keys:
            report = make_report("recording", [5, 5])
            report["composition"][key] = report["composition"][key][:1]
            with self.assertRaises(RuntimeError, msg=f"{key} is not length-checked"):
                shape.row_facts(report)


class PackingTests(unittest.TestCase):
    def test_scalar_width_tier_follows_the_widest_single_scalar(self):
        """1/2/4-byte tiers, chosen from single-scalar cells only."""
        for widest, expected in ((ord("x"), 1), (0xFF, 1), (0x2500, 2), (0x1F600, 4)):
            fact = shape.row_facts(make_report("recording", [4], max_scalar=[widest]))[0]
            self.assertEqual(shape.row_scalar_width(fact), expected)

    def test_a_candidate_that_saves_nothing_drops_no_size_class(self):
        """`D3`'s admission test must be able to answer no.

        The test is only meaningful if a candidate that fails it is reported as
        failing. A "packing" that returns the current payload unchanged must show
        zero rows dropping a class and a zero saving -- otherwise the column is
        decoration rather than a gate.
        """
        report = make_report("recording", [51] * 10)
        facts = shape.row_facts(report)
        original = dict(shape.PACKINGS)
        try:
            shape.PACKINGS.clear()
            shape.PACKINGS["identity"] = lambda fact: fact["stored"] * 32
            priced = shape.price_facts(facts, 32)
        finally:
            shape.PACKINGS.clear()
            shape.PACKINGS.update(original)

        self.assertEqual(priced["identity"]["rowsDroppingAClass"], 0)
        self.assertEqual(priced["identity"]["savingFraction"], 0.0)

    def test_run_length_styles_are_priced_per_run_not_per_styled_cell(self):
        """A uniformly styled row must cost one run, not one entry per cell.

        This is the whole reason run-length styles are a candidate: if the price
        scaled with styled cells, `C3`/`C6` would collapse toward the per-cell
        forms on exactly the styled content `F11` went looking for.
        """
        uniform = shape.row_facts(
            make_report("recording", [80], styled=[80], runs=[1])
        )[0]
        fragmented = shape.row_facts(
            make_report("recording", [80], styled=[80], runs=[40])
        )[0]

        self.assertEqual(
            shape.pack_stride_runs_exceptions(uniform),
            80 * 1 + 1 * 6,
        )
        self.assertGreater(
            shape.pack_stride_runs_exceptions(fragmented),
            shape.pack_stride_runs_exceptions(uniform),
        )


class MetadataChargeCompletenessTests(unittest.TestCase):
    """`PR1` step 5: no candidate may be free of a field it has to preserve.

    The corrected table is only a comparison if every candidate is charged for the
    same storage. The original omission -- hyperlink metadata named in C6's design
    and charged nowhere -- survived review because the fixture fed
    `hyperlinkCellCounts` as all zeros, and a fixture that never exercises a field
    cannot catch a candidate that never charges it. These tests raise each axis
    from zero and demand every candidate's price move.

    Deltas are asserted against `arenaChargedBytes`, which is the unrounded
    `slot + payload + spills`. The rounded charge would let a size class swallow a
    real undercharge and pass.
    """

    def arena_per_row(self, report):
        facts = shape.row_facts(report)
        priced = shape.price_facts(facts, 32)
        return {
            name: entry["arenaMeanChargeBytes"]
            for name, entry in priced.items()
            if name != "current"
        }

    def test_every_candidate_charges_hyperlink_metadata(self):
        """Raising the hyperlink count must move every candidate's price.

        This is the regression the review found, stated as a test. No candidate
        has room for a `HyperlinkId` in the storage it already describes, so each
        owes a side-table entry -- and the one that owes nothing is the bug.
        """
        without = self.arena_per_row(make_report("recording", [51]))
        with_links = self.arena_per_row(make_report("recording", [51], hyperlinks=[4]))

        for candidate, base in without.items():
            self.assertEqual(
                with_links[candidate] - base,
                4 * shape.HYPERLINK_ENTRY_BYTES,
                f"{candidate} does not charge hyperlink metadata",
            )

    def test_a_combined_metadata_row_moves_the_candidates_that_owe_each_axis(self):
        """One row carrying every axis at once, raised one axis at a time.

        The axes interact -- a multi-scalar cell is also a spill reference, a wide
        cell is also an exception entry -- so proving each in isolation leaves the
        combination unproven. This is the fixture `PR1` step 5 asks for.

        Which candidates owe which axis is not uniform, and asserting that it is
        would be a wrong test rather than a strict one: C1's 8-byte cell already
        spends a kind byte on every cell, so wide-cell geometry costs it nothing
        extra, and its per-cell style id makes style runs free. The one axis no
        candidate encodes per cell -- hyperlink metadata -- is owed by all six, and
        it is the one the original table omitted.
        """
        universal = {
            "hyperlinks": {"hyperlinks": [3]},
        }
        exception_list_only = {
            "wide cells": ({"wide": [6]}, ["C6 stride+runs+exceptions"]),
            "multi-scalar cells": ({"multi": [2]}, ["C6 stride+runs+exceptions"]),
            "style runs": ({"runs": [9]}, [
                "C3 text+style-runs", "C5 stride+runs+kindbyte",
                "C6 stride+runs+exceptions",
            ]),
        }
        base_kwargs = dict(
            stored=[60], styled=[30], runs=[3], multi=[1], wide=[2],
            hyperlinks=[1],
        )
        base = self.arena_per_row(make_report("recording", **base_kwargs))

        for axis, override in universal.items():
            raised = self.arena_per_row(
                make_report("recording", **{**base_kwargs, **override})
            )
            for candidate, before in base.items():
                self.assertGreater(
                    raised[candidate], before,
                    f"{candidate} does not charge more when {axis} rise",
                )

        for axis, (override, owed_by) in exception_list_only.items():
            raised = self.arena_per_row(
                make_report("recording", **{**base_kwargs, **override})
            )
            for candidate in owed_by:
                self.assertGreater(
                    raised[candidate], base[candidate],
                    f"{candidate} does not charge more when {axis} rise",
                )

    def test_c6_charges_a_multiscalar_exception_more_than_a_wide_one(self):
        """Exception entries are per kind, not a uniform 3 bytes.

        A wide-cell entry needs a column and a kind tag; a multi-scalar entry also
        needs the reference that reaches its spill allocation. Pricing them the
        same is what the original C6 did, and it under-charges precisely the cells
        a fixed-width scalar slot cannot hold.
        """
        wide_row = shape.row_facts(make_report("recording", [40], wide=[4]))[0]
        multi_row = shape.row_facts(make_report("recording", [40], multi=[4]))[0]

        self.assertGreater(
            shape.pack_stride_runs_exceptions(multi_row),
            shape.pack_stride_runs_exceptions(wide_row),
        )


if __name__ == "__main__":
    unittest.main()
