#!/usr/bin/env python3
"""Behavioral tests for the terminal recording corpus schema audit."""

import base64
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "terminal-recording-schema-audit.py"


def load_script():
    spec = importlib.util.spec_from_file_location("terminal_recording_schema_audit", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TerminalRecordingSchemaAuditTests(unittest.TestCase):
    def test_committed_corpus_covers_all_three_recording_families(self):
        audit = load_script()

        counts = audit.audit_recording_corpus(ROOT)

        self.assertEqual(set(counts), {"neutral", "ghostty", "benchmark"})
        self.assertTrue(all(count > 0 for count in counts.values()))

    def test_feed_audit_accepts_binary_base64_and_readable_text(self):
        audit = load_script()
        arbitrary = bytes(range(256))
        events = [
            {"type": "feed", "base64": base64.b64encode(arbitrary).decode("ascii")},
            {"type": "feed", "text": "readable café"},
            {"type": "family-specific", "payload": "ignored"},
        ]

        count = audit.audit_feed_events(events, "synthetic")

        self.assertEqual(count, 2)

    def test_feed_audit_rejects_missing_duplicate_hex_and_malformed_payloads(self):
        audit = load_script()
        cases = {
            "missing": {"type": "feed"},
            "duplicate": {"type": "feed", "base64": "YQ==", "text": "a"},
            "hex": {"type": "feed", "hex": "61"},
            "malformed base64": {"type": "feed", "base64": "not base64!"},
            "non-string text": {"type": "feed", "text": 42},
        }

        for name, event in cases.items():
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    audit.audit_feed_events([event], name)


if __name__ == "__main__":
    unittest.main()
