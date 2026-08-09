#!/usr/bin/env python3
"""Prove that confirm feed blocks survive a large win without biasing A/A."""
import argparse
import importlib.util
import json
import pathlib


REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[3]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def nominal_state():
    return {
        "powerSource": "AC Power",
        "lowPowerMode": False,
        "thermalState": "nominal",
    }


def run_case(compare, validation, per_execution):
    schedule = compare.make_schedule(
        "confirm", ("terminal-feed",), physical_candidate_arm="b"
    )["terminal-feed"]

    def run_benchmark(arm, *, execution_count):
        duration = per_execution[arm]
        if execution_count is None:
            batch_count = (1_000_000_000 + duration - 1) // duration
            samples = 2
        else:
            batch_count = execution_count
            samples = 1
        return {
            "batchCount": batch_count,
            "feedDurationNanoseconds": [duration] * samples,
            "sampleDurationNanoseconds": [batch_count * duration] * samples,
        }

    evidence = validation.collect_terminal_feed(
        schedule,
        minimum_block_nanoseconds=1_000_000_000,
        run_benchmark=run_benchmark,
        sample_state=nominal_state,
    )
    differences = (
        compare.paired_differences("terminal-feed", evidence["rawBlocks"])
        if evidence["valid"]
        else None
    )
    decision = (
        compare.decide_workload("confirm", "terminal-feed", differences)
        if differences is not None
        else None
    )
    return {
        "valid": evidence["valid"],
        "invalidationReasons": evidence["invalidationReasons"],
        "batchCounts": [
            block["batchCount"] for block in evidence["rawBlocks"]
        ],
        "minimumBlockNanoseconds": min(
            block["sampleDurationNanoseconds"]
            for block in evidence["rawBlocks"]
        ),
        "pairedSymmetricPercent": differences,
        "verdict": None if decision is None else decision["decision"],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--implementation-root",
        type=pathlib.Path,
        default=REPOSITORY_ROOT,
    )
    arguments = parser.parse_args()
    root = arguments.implementation_root.resolve()
    compare = load_module(
        "t24_terminal_benchmark_compare",
        root / "scripts" / "terminal-benchmark-compare.py",
    )
    validation = load_module(
        "t24_terminal_benchmark_validation",
        root / "scripts" / "terminal-benchmark-validation.py",
    )

    result = {
        "largeImprovement": run_case(
            compare,
            validation,
            {"a": 300_000_000, "b": 200_000_000},
        ),
        "identicalSource": run_case(
            compare,
            validation,
            {"a": 250_000_000, "b": 250_000_000},
        ),
    }
    print(json.dumps(result, indent=2, sort_keys=True))

    large = result["largeImprovement"]
    identical = result["identicalSource"]
    if not (
        large["valid"]
        and large["batchCounts"] == [4, 5, 5, 4]
        and large["minimumBlockNanoseconds"] >= 1_000_000_000
        and large["verdict"] == "faster"
        and identical["valid"]
        and identical["batchCounts"] == [4, 4, 4, 4]
        and identical["minimumBlockNanoseconds"] >= 1_000_000_000
        and identical["verdict"] == "equivalent"
    ):
        raise SystemExit("T24 verification failed")


if __name__ == "__main__":
    main()
