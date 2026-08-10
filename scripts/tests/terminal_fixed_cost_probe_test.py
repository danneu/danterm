#!/usr/bin/env python3
"""Behavioral tests for the per-terminal fixed-footprint control."""
import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "terminal_fixed_cost_probe",
    ROOT / "scripts" / "terminal-fixed-cost-probe.py",
)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class GeometryControlTests(unittest.TestCase):
    def test_control_removes_known_cell_storage_before_comparing_geometries(self):
        # Intent: the geometry control compares the footprint left after exact cell storage,
        #   so removing the arena does not make ordinary grid-size differences fail the probe.
        # Why it exists: raw footprint was flat only while a 15 MiB eager arena dominated it;
        #   once backing became lazy, the successful result exposed the live grid as the largest
        #   term and the old percentage check rejected the intended optimization.
        common = {"arenaCapacityBytes": 15_000_000, "arenaBytesInUse": 0}
        samples = [
            {**common, "footprintDeltaBytes": 508_000, "cellStorageBytes": 378_000},
            {**common, "footprintDeltaBytes": 524_000, "cellStorageBytes": 382_000},
            {**common, "footprintDeltaBytes": 492_000, "cellStorageBytes": 374_000},
        ]
        summary = PROBE.summarize(samples)
        geometries = [summary, {"nonCellFootprintBytes": 118_000}, {"nonCellFootprintBytes": 102_000}]

        self.assertEqual(summary["nonCellFootprintBytes"], 130_000)
        self.assertEqual(PROBE.control_residual_drift_bytes(geometries), 28_000)


if __name__ == "__main__":
    unittest.main()
