#!/usr/bin/env python3
"""Compare pane-tape observer tax across immutable source revisions.

This is descriptive instrumentation. It does not issue a performance verdict or
borrow a threshold from the calibrated terminal benchmark ladder.
"""
import argparse
import importlib.util
import json
import os
import pathlib
import subprocess
import time


ROOT = pathlib.Path(__file__).resolve().parents[1]


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SNAPSHOT = _load("terminal_benchmark_snapshot", "scripts/terminal_benchmark_snapshot.py")


def follower_counts(cap):
    """Return the plan's unique 0, 1, half-cap, and cap topology."""
    if cap < 1:
        raise ValueError("follower cap must be positive")
    return tuple(dict.fromkeys((0, 1, max(1, cap // 2), cap)))


def make_schedule(cap):
    """Position-balance revision roles and follower counts in one fixed schedule."""
    counts = follower_counts(cap)
    forward = [
        {"revisionRole": "baseline" if index % 2 == 0 else "candidate",
         "followerCount": count}
        for index, count in enumerate(counts)
    ]
    forward_roles = {item["followerCount"]: item["revisionRole"] for item in forward}
    reverse = [
        {"revisionRole": (
            "candidate" if forward_roles[count] == "baseline" else "baseline"
        ), "followerCount": count}
        for count in reversed(counts)
    ]
    schedule = forward + reverse
    physical_arms = ("a", "b", "b", "a", "b", "a", "a", "b")
    if len(schedule) != len(physical_arms):
        # A cap below four deduplicates the topology. It remains useful for unit
        # tests and development, but production's fixed cap is eight.
        physical_arms = tuple("a" if index % 2 == 0 else "b" for index in range(len(schedule)))
    return [
        {**block, "physicalArm": physical_arms[index]}
        for index, block in enumerate(schedule)
    ]


def _validate_block(block):
    followers = block["followerCount"]
    if block.get("terminalEvent") != "final-draw-completed":
        raise ValueError("block did not reach its terminal event")
    if block.get("followerCompletions") != followers:
        raise ValueError("block follower completion count does not match its topology")
    if not isinstance(block.get("producerWriteBytes"), int):
        raise ValueError("block has no measured byte total")
    metrics = block.get("followMetrics")
    if not isinstance(metrics, dict):
        raise ValueError("block has no follow metrics")


def summarize(blocks):
    """Validate blocks and report followed-minus-unfollowed observer tax."""
    if not blocks:
        raise ValueError("observer-tax comparison requires blocks")
    for block in blocks:
        _validate_block(block)
    byte_totals = {block["producerWriteBytes"] for block in blocks}
    if len(byte_totals) != 1:
        raise ValueError("block byte totals differ")

    result = {}
    for role in ("baseline", "candidate"):
        role_blocks = [block for block in blocks if block["revisionRole"] == role]
        if not role_blocks:
            continue
        by_count = {block["followerCount"]: block for block in role_blocks}
        if 0 not in by_count:
            raise ValueError(f"{role} has no zero-follower control")
        control = by_count[0]
        corpus_bytes = control["producerWriteBytes"]
        control_rate = corpus_bytes / (control["producerWriteNanoseconds"] / 1e9) / 1e6
        rows = {}
        for count, block in sorted(by_count.items()):
            metrics = block["followMetrics"]
            samples = metrics.get("ownerSampleCount", 0)
            drain_rate = corpus_bytes / (block["producerWriteNanoseconds"] / 1e9) / 1e6
            rows[count] = {
                "drainTaxNanoseconds": (
                    block["producerWriteNanoseconds"]
                    - control["producerWriteNanoseconds"]
                ),
                "blockTaxNanoseconds": (
                    block["finalDrawNanoseconds"] - control["finalDrawNanoseconds"]
                ),
                "drainMegabytesPerSecond": drain_rate,
                "drainRateTaxMegabytesPerSecond": drain_rate - control_rate,
                "followerCompletionNanoseconds": block.get(
                    "followerCompletionNanoseconds"
                ),
                "ownerNanosecondsPerSubscriberSample": (
                    metrics.get("ownerNanoseconds", 0) / samples if samples else None
                ),
                "ownerSampleCount": samples,
                "followFenceCount": metrics.get("followFenceCount"),
                "pushCount": metrics.get("pushCount"),
                "synchronizationCount": metrics.get("synchronizationCount"),
                "statePairingCount": metrics.get("statePairingCount"),
            }
        result[role] = rows
    return result


def _artifact_block(role, followers, artifact):
    draw = artifact["finalDraw"]
    producer = artifact["producerWrite"]
    completions = artifact.get("paneTapeFollowers", [])
    completion_ns = [
        item["completionNanoseconds"] - producer["startedNanoseconds"]
        for item in completions
    ]
    return {
        "revisionRole": role,
        "followerCount": followers,
        "producerWriteNanoseconds": producer["elapsedNanoseconds"],
        "producerWriteBytes": producer["bytesWritten"],
        "finalDrawNanoseconds": draw["elapsedNanoseconds"],
        "followerCompletionNanoseconds": max(completion_ns) if completion_ns else None,
        "followMetrics": draw["paneTapeFollowMetrics"],
        "terminalEvent": draw["event"],
        "followerCompletions": len(completions),
        "artifact": artifact,
    }


def run_arm(root, physical_arm, followers):
    """Run one fresh app block at the requested follower topology."""
    environment = dict(os.environ)
    environment.update({
        "DANTERM_BENCHMARK_BUNDLE_SUFFIX": f".{physical_arm}",
        "DANTERM_TERMINAL_BENCHMARK_FOLLOWERS": str(followers),
    })
    completed = subprocess.run(
        [str(pathlib.Path(root) / "scripts" / "terminal-benchmark.sh"), "scrollback-stream"],
        cwd=root,
        env=environment,
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(completed.stdout[completed.stdout.find("{"):])


def run_comparison(baseline_revision, cap, repository_root, cache_root, artifacts_root):
    """Materialize both sources, collect the fixed topology, and save its report."""
    baseline = SNAPSHOT.resolve_baseline(repository_root, baseline_revision)
    candidate = SNAPSHOT.snapshot_candidate(repository_root)
    print(SNAPSHOT.describe_sources(baseline, candidate))
    if baseline["tree"] == candidate["tree"]:
        raise ValueError("baseline and candidate are the same tree")
    roots = {
        "baseline": SNAPSHOT.materialize_arm(repository_root, baseline, cache_root=cache_root)["root"],
        "candidate": SNAPSHOT.materialize_arm(repository_root, candidate, cache_root=cache_root)["root"],
    }
    schedule = make_schedule(cap)
    blocks = [
        _artifact_block(
            item["revisionRole"],
            item["followerCount"],
            run_arm(roots[item["revisionRole"]], item["physicalArm"], item["followerCount"]),
        )
        for item in schedule
    ]
    report = {
        "schemaVersion": 1,
        "baseline": baseline,
        "candidate": candidate,
        "schedule": schedule,
        "blocks": blocks,
        "observerTax": summarize(blocks),
        "decisionEligible": False,
    }
    output = pathlib.Path(artifacts_root) / time.strftime("%Y-%m-%d-%H%M%S")
    output.mkdir(parents=True)
    (output / "run.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report["observerTax"], indent=2, sort_keys=True))
    print(f"Artifacts: {output}")
    return report


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--cap", type=int, required=True)
    parser.add_argument("--repository-root", type=pathlib.Path, default=ROOT)
    parser.add_argument("--cache-root", type=pathlib.Path, default=ROOT / ".build/terminal-benchmark-arms")
    parser.add_argument("--artifacts-root", type=pathlib.Path, default=ROOT / ".build/pane-tape-observer-tax")
    args = parser.parse_args(argv)
    run_comparison(args.baseline, args.cap, args.repository_root, args.cache_root, args.artifacts_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
