#!/usr/bin/env python3
"""Screen a candidate workload's primary metric for a decision rule.

A candidate workload is one the corpus can collect and the comparison cannot yet
decide: it has blocks, a block contract, and no frozen threshold. This runs the
A/A series that resolves that state, and reports the rule it implies.

Distinct from `terminal-benchmark-plan-calibration.py` in the one way that
matters. That screens an *auxiliary* metric, which rides the deciding metric's
blocks and therefore cannot buy more pairs -- 17/F15 refused a rule on exactly
that constraint. A candidate workload owns its blocks, so the pair count is a
free variable and is searched here alongside the threshold. A rule that needs
more pairs is a real proposal, priced in machine time rather than impossible.

Both physical arms bind to one immutable root, so every measured difference is
noise by construction. It never edits the frozen rules: a human reads the report
and moves a threshold into `DECISION_RULES`, and moves the workload out of
`CANDIDATE_WORKLOADS` into `WORKLOADS`.
"""
import argparse
import importlib.util
import json
import pathlib
import statistics
import time


ROOT = pathlib.Path(__file__).resolve().parents[1]


def _load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CALIBRATION = _load("terminal_benchmark_calibration", "scripts/terminal-benchmark-calibration.py")
COMPARE = _load("terminal_benchmark_compare", "scripts/terminal-benchmark-compare.py")
SNAPSHOT = _load("terminal_benchmark_snapshot", "scripts/terminal_benchmark_snapshot.py")
VALIDATION = _load("terminal_benchmark_validation", "scripts/terminal-benchmark-validation.py")
PLAN = _load("terminal_benchmark_plan_calibration", "scripts/terminal-benchmark-plan-calibration.py")

# Searched from cheapest upward, so the reported rule is the least machine time
# that clears the gates rather than the tightest threshold at any price.
PAIR_COUNTS = (2, 4, 6, 8, 12, 16, 24)
THRESHOLD_GRID = tuple(round(0.80 + 0.05 * index, 2) for index in range(45))


def paired_differences(workload, raw_blocks):
    """Reduce one quartet's blocks to its two paired percentage differences."""
    metric = COMPARE.BLOCK_METRICS[workload]
    pairs = []
    for offset in range(0, len(raw_blocks), 2):
        window = raw_blocks[offset:offset + 2]
        roles = {block["measurementRole"]: block for block in window}
        if set(roles) != {"A", "B"}:
            raise ValueError(
                f"{workload} pair at offset {offset} is not one A and one B block"
            )
        baseline = roles["A"][metric]
        candidate = roles["B"][metric]
        pairs.append((candidate - baseline) / baseline * 100.0)
    return pairs


def propose_rule(quartets, *, effect_percent, equivalence_band_percent, trials, seed,
                 pair_counts=PAIR_COUNTS, thresholds=THRESHOLD_GRID,
                 maximum_false_positive_rate=0.01, minimum_detection_rate=0.90,
                 maximum_inconclusive_rate=0.10, maximum_wrong_direction_rate=0.0):
    """Return the cheapest (pairs, threshold) clearing every accuracy gate.

    Cheapest, not tightest: pair count is machine time an operator pays on every
    future comparison, so a rule needing 24 pairs to shave a threshold is worse
    than one needing 4. Returns None when nothing clears at any searched pair
    count, which is a real answer -- it says this stimulus is too noisy to decide
    with, and the honest response is to keep reporting it descriptively.
    """
    eligible = sorted(
        threshold for threshold in thresholds if threshold > equivalence_band_percent
    )
    if not eligible:
        return None
    for pair_count in pair_counts:
        candidates = CALIBRATION.calibrate_threshold_grid(
            quartets, pair_count, effect_percent, eligible,
            equivalence_band_percent, trials, seed,
        )
        selected = CALIBRATION.select_candidate(
            candidates, maximum_false_positive_rate, minimum_detection_rate,
            maximum_inconclusive_rate, maximum_wrong_direction_rate,
        )
        if selected is not None:
            return {"pairCount": pair_count, "selected": selected,
                    "searchedCellCount": len(candidates)}
    return None


def describe_series(quartets):
    """Summarize the raw A/A spread, which is what makes a rule plausible or not."""
    values = [value for pairs in quartets for value in pairs]
    return {
        "pairCount": len(values),
        "medianPercent": round(statistics.median(values), 4),
        "standardDeviationPercent": round(statistics.pstdev(values), 4),
        "minimumPercent": round(min(values), 4),
        "maximumPercent": round(max(values), 4),
    }


def run_screen(*, workload, revision, quartets, trials, seed, repository_root,
               cache_root, artifacts_root, maximum_attempts=4, emit=print,
               monotonic=time.monotonic):
    """Collect one A/A series for a candidate workload and report its implied rule."""
    if workload not in VALIDATION.CANDIDATE_WORKLOADS:
        raise ValueError(
            f"{workload} is not a candidate workload; "
            f"candidates are {sorted(VALIDATION.CANDIDATE_WORKLOADS)}"
        )
    started = monotonic()
    arm_source = SNAPSHOT.resolve_baseline(repository_root, revision)
    arm = SNAPSHOT.materialize_arm(repository_root, arm_source, cache_root=cache_root)
    schedule = {workload: [
        {"measurementRole": role, "physicalArm": "a", "quartet": quartet}
        for quartet in range(quartets)
        for role in PLAN.QUARTET_PATTERNS[quartet % len(PLAN.QUARTET_PATTERNS)]
    ]}
    artifacts = PLAN._run_directory(artifacts_root, arm_source["tree"])
    collectors, close = COMPARE.production_collectors(
        schedule, artifacts,
        arm_roots={"a": arm["root"], "b": arm["root"]},
        repository_root=arm["root"],
    )
    try:
        kept, discarded = PLAN.collect_quartets(
            workload, collectors[workload], quartets=quartets,
            maximum_attempts=maximum_attempts, metric=None, emit=emit,
        )
    finally:
        close()

    series = [paired_differences(workload, blocks) for blocks in kept]
    modes = {}
    for mode in COMPARE.MODES:
        rule = COMPARE.decision_rule(mode)
        modes[mode] = propose_rule(
            series,
            effect_percent=rule["effectPercent"],
            equivalence_band_percent=rule["equivalenceBandPercent"],
            trials=trials, seed=seed,
        )
    report = {
        "schemaVersion": 1,
        "workload": workload,
        "metric": COMPARE.BLOCK_METRICS[workload],
        "revision": revision,
        "tree": arm_source["tree"],
        "quartetsKept": len(kept),
        "quartetsDiscarded": discarded,
        "trials": trials,
        "seed": seed,
        "series": describe_series(series),
        "modes": modes,
        "elapsedSeconds": round(monotonic() - started, 3),
    }
    (artifacts / "candidate-screen.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    report["artifacts"] = str(artifacts)
    return report


def render_report(report):
    """Render the report an operator reads before touching a frozen rule."""
    lines = [
        f"candidate screen: {report['workload']} ({report['metric']})",
        f"  tree {report['tree']}  kept {report['quartetsKept']} quartets, "
        f"discarded {report['quartetsDiscarded']}",
        f"  A/A spread: {report['series']['pairCount']} pairs, "
        f"median {report['series']['medianPercent']:+.2f}%, "
        f"SD {report['series']['standardDeviationPercent']:.2f}%, "
        f"range {report['series']['minimumPercent']:+.2f}%.."
        f"{report['series']['maximumPercent']:+.2f}%",
    ]
    for mode, proposal in report["modes"].items():
        if proposal is None:
            lines.append(f"  {mode}: no threshold clears the gates at any searched "
                         f"pair count -- keep reporting descriptively")
            continue
        selected = proposal["selected"]
        lines.append(
            f"  {mode}: {proposal['pairCount']} pairs, "
            f"+/-{selected['thresholdPercent']}%  "
            f"(A/A false positives {selected['falsePositiveRate']:.4f}, "
            f"detection {selected['detectionRate']:.4f})"
        )
    lines.append("  nothing was written to DECISION_RULES; a human moves a rule.")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--workload", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--quartets", type=int, default=12)
    parser.add_argument("--trials", type=int, default=50_000)
    parser.add_argument("--seed", type=int, default=20260730)
    parser.add_argument("--repository-root", type=pathlib.Path, default=ROOT)
    parser.add_argument("--cache-root", type=pathlib.Path,
                        default=ROOT / ".build" / "terminal-benchmark-arms")
    parser.add_argument("--artifacts-root", type=pathlib.Path,
                        default=ROOT / ".build" / "terminal-benchmark-candidate-screens")
    arguments = parser.parse_args(argv)
    report = run_screen(
        workload=arguments.workload, revision=arguments.revision,
        quartets=arguments.quartets, trials=arguments.trials, seed=arguments.seed,
        repository_root=arguments.repository_root, cache_root=arguments.cache_root,
        artifacts_root=arguments.artifacts_root,
    )
    print(render_report(report))
    print(f"  evidence: {report['artifacts']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
