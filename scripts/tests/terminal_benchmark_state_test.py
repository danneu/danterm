#!/usr/bin/env python3
"""Behavioral tests for per-block benchmark machine-state validation."""

import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts" / "terminal-benchmark-state.py"
SPEC = importlib.util.spec_from_file_location("terminal_benchmark_state", MODULE_PATH)
STATE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(STATE)


class BenchmarkStateValidationTests(unittest.TestCase):
    def test_nominal_visible_block_is_valid(self):
        samples = [
            {"reason": "start", "visible": True, "thermalState": "nominal",
             "lowPowerMode": False},
            {"reason": "completion", "visible": True, "thermalState": "nominal",
             "lowPowerMode": False},
        ]

        self.assertEqual(STATE.validate_samples(samples), {"valid": True, "reasons": []})

    def test_space_switch_invalidates_even_when_completion_is_visible(self):
        samples = [
            {"reason": "start", "visible": True, "thermalState": "nominal",
             "lowPowerMode": False},
            {"reason": "active-space-change", "visible": True, "thermalState": "nominal",
             "lowPowerMode": False, "activeSpaceChanged": True},
            {"reason": "completion", "visible": True, "thermalState": "nominal",
             "lowPowerMode": False},
        ]

        self.assertEqual(
            STATE.validate_samples(samples),
            {"valid": False, "reasons": ["active-space-changed"]},
        )

    def test_thermal_pressure_invalidates_block(self):
        samples = [
            {"reason": "start", "visible": True, "thermalState": "serious",
             "lowPowerMode": False},
        ]

        self.assertEqual(
            STATE.validate_samples(samples),
            {"valid": False, "reasons": ["thermal-pressure-serious"]},
        )

    def test_low_power_mode_invalidates_block(self):
        samples = [
            {"reason": "start", "visible": True, "thermalState": "nominal",
             "lowPowerMode": True},
            {"reason": "completion", "visible": True, "thermalState": "nominal",
             "lowPowerMode": True},
        ]

        self.assertEqual(
            STATE.validate_samples(samples),
            {"valid": False, "reasons": ["low-power-mode"]},
        )


if __name__ == "__main__":
    unittest.main()
