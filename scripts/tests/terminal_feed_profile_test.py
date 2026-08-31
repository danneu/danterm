#!/usr/bin/env python3
"""Behavioral tests for bounded cleanup in the Terminal.feed profile driver."""
import importlib.util
import pathlib
import subprocess
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "terminal_feed_profile",
    ROOT / "scripts" / "terminal-feed-profile.py",
)
PROFILE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROFILE)


class ProfileCleanupTests(unittest.TestCase):
    def test_cleanup_escalates_when_the_harness_ignores_sigterm(self):
        harness = mock.Mock()
        harness.wait.side_effect = [
            subprocess.TimeoutExpired("harness", PROFILE.STOP_TIMEOUT_SECONDS),
            0,
        ]

        PROFILE.cleanup_harness(harness, pathlib.Path("fixture.bin"))

        harness.terminate.assert_called_once_with()
        harness.kill.assert_called_once_with()
        self.assertEqual(harness.wait.call_count, 2)

    def test_cleanup_failures_do_not_replace_the_sampling_error(self):
        harness = mock.Mock()
        harness.terminate.side_effect = OSError("terminate failed")

        with mock.patch.object(PROFILE.os, "unlink", side_effect=OSError("unlink failed")):
            with self.assertRaisesRegex(RuntimeError, "sampling failed"):
                try:
                    raise RuntimeError("sampling failed")
                finally:
                    PROFILE.cleanup_harness(harness, pathlib.Path("fixture.bin"))


if __name__ == "__main__":
    unittest.main()
