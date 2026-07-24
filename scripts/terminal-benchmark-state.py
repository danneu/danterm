#!/usr/bin/env python3
"""Validate the machine and visibility samples captured during one measured block."""

import json
import sys


def validate_samples(samples):
    """Return stable invalidation reasons for all state observed during a block."""
    reasons = []
    for sample in samples:
        thermal = sample["thermalState"]
        candidates = []
        if sample.get("activeSpaceChanged", False):
            candidates.append("active-space-changed")
        if not sample["visible"]:
            candidates.append("window-occluded")
        if thermal != "nominal":
            candidates.append(f"thermal-pressure-{thermal}")
        if sample["lowPowerMode"]:
            candidates.append("low-power-mode")
        for reason in candidates:
            if reason not in reasons:
                reasons.append(reason)
    return {"valid": not reasons, "reasons": reasons}


def main():
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} FINAL_DRAW_JSON")
    with open(sys.argv[1], encoding="utf-8") as input_file:
        result = json.load(input_file)
    print(json.dumps(validate_samples(result["machineStateSamples"]), sort_keys=True))


if __name__ == "__main__":
    main()
