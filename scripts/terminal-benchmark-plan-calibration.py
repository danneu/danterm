#!/usr/bin/env python3
"""Collect an A/A plan-time series and choose fixed-N decision rules from it.

The paired comparison decides `faster`/`slower`/`equivalent` from the serialized
draw metric alone. That metric brackets clipping and drawing, so it structurally
cannot observe `planFrame`, which runs on the PTY-output path; plan time is
therefore reported beside the verdict as descriptive evidence with no thresholds
behind it. Giving it a verdict needs exactly what the draw rules already have:
an A/A series measuring the same tree against itself, and thresholds chosen so
that series' own noise almost never reads as a direction.

This script collects that series and reports the rule it implies. It never edits
the frozen rules -- `terminal-benchmark-validation.DECISION_RULES` stays a
predeclared constant that a human moves after reading a report, which is what
keeps the decision rule from drifting silently with each measurement.

Both physical arms are bound to one immutable root on purpose: the resulting
differences contain machine and schedule noise and no code difference at all,
which is the only thing a false-positive rate can be calibrated against.
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


SNAPSHOT = _load(
    "terminal_benchmark_snapshot", "scripts/terminal_benchmark_snapshot.py"
)
VALIDATION = _load(
    "terminal_benchmark_validation", "scripts/terminal-benchmark-validation.py"
)
CALIBRATION = _load(
    "terminal_benchmark_calibration", "scripts/terminal-benchmark-calibration.py"
)
COMPARE = _load(
    "terminal_benchmark_compare", "scripts/terminal-benchmark-compare.py"
)

# Only the workloads whose blocks carry a plan-time measurement can calibrate a
# plan-time rule. `terminal-feed` never plans and `scrollback-stream` reports one
# final draw rather than a normalized per-draw series.
PLAN_WORKLOADS = tuple(COMPARE.AUXILIARY_BLOCK_METRICS)
QUARTET_PATTERNS = COMPARE.QUARTET_PATTERNS
# The thresholds a rule may claim. Only the threshold is searched; the pair count
# comes from the mode's existing draw rule, because plan time is measured on the
# same blocks and cannot buy itself more of them.
THRESHOLD_GRID = tuple(round(1.0 + 0.25 * step, 2) for step in range(37))


def make_aa_schedule(workloads, quartets):
    """Lay out a balanced A/A schedule whose two roles resolve to the same arm.

    Position balance still matters with one binary: block order, thermal drift,
    and per-launch luck are exactly the noise being calibrated, and an unbalanced
    schedule would let them masquerade as a stable direction.
    """
    if quartets <= 0:
        raise ValueError("an A/A series requires at least one quartet")
    unknown = [name for name in workloads if name not in PLAN_WORKLOADS]
    if unknown:
        raise ValueError(f"workloads carry no plan metric: {sorted(unknown)}")
    if not workloads:
        raise ValueError("an A/A series requires at least one workload")
    schedule = {}
    for workload in workloads:
        blocks = []
        for quartet in range(quartets):
            for role in QUARTET_PATTERNS[quartet % len(QUARTET_PATTERNS)]:
                blocks.append({
                    "measurementRole": role,
                    "physicalArm": "a",
                    "quartet": quartet,
                })
        schedule[workload] = blocks
    return schedule


def collect_quartets(workload, collector, *, quartets, maximum_attempts, emit=None):
    """Collect complete quartets one at a time, discarding and retrying invalid ones.

    A comparison voids its whole invocation on one invalid block, because a
    decision must not be assembled from blocks the operator got to look at first.
    Calibration cannot use that rule: at this harness's per-block failure rate a
    48-block series would essentially never complete, and nothing here decides
    anything about a code change. The weaker rule that still holds: a quartet is
    kept only if all four of its blocks are valid, and a quartet with any invalid
    block is discarded whole rather than patched, so no kept quartet mixes blocks
    from different attempts and schedule balance survives intact.
    """
    if maximum_attempts < 1:
        raise ValueError("collection requires at least one attempt per quartet")
    pattern_blocks = make_aa_schedule((workload,), quartets)[workload]
    kept = []
    discarded = 0
    for index in range(quartets):
        planned = pattern_blocks[index * 4:(index + 1) * 4]
        for attempt in range(maximum_attempts):
            # A block whose app never writes its result, or is read while its
            # artifact is still empty, raises out of the collector instead of
            # reporting an invalidation reason. Both are the same thing here -- a
            # quartet that produced no usable evidence -- and the comparison
            # path's decision to let this abort the invocation does not transfer,
            # because no verdict is being assembled from these blocks. The catch
            # stays narrow to these three IO shapes so a contract or programming
            # error still fails loudly instead of being retried into a RuntimeError.
            try:
                evidence = collector(planned)
                reasons = evidence.get("invalidationReasons") or []
            except (TimeoutError, json.JSONDecodeError, OSError) as error:
                evidence, reasons = None, [f"collector-{type(error).__name__}:{error}"]
            if not reasons:
                kept.append(evidence["rawBlocks"])
                break
            discarded += 1
            if emit is not None:
                emit(
                    f"  {workload}: quartet {index} attempt {attempt} discarded "
                    f"({len(reasons)} reasons)"
                )
        else:
            raise RuntimeError(
                f"{workload} quartet {index} never produced four valid blocks in "
                f"{maximum_attempts} attempts"
            )
    return kept, discarded


def plan_quartets(workload, raw_blocks):
    """Reduce collected blocks to the quartet-grouped plan-time paired differences.

    Grouped rather than flat because resampling draws whole quartets: adjacent
    pairs within one share a thermal and scheduling neighborhood, and flattening
    would let calibration assume an independence the measurement does not have.
    """
    metric = COMPARE.AUXILIARY_BLOCK_METRICS.get(workload)
    if metric is None:
        raise ValueError(f"{workload} carries no plan-time metric")
    if not raw_blocks or len(raw_blocks) % 4:
        raise ValueError(f"{workload} calibration requires complete quartets")
    missing = [block["index"] for block in raw_blocks if block.get(metric) is None]
    if missing:
        raise ValueError(
            f"{workload} blocks {missing} report no plan time; the measured arm "
            "predates the plan timer"
        )
    quartets = []
    for offset in range(0, len(raw_blocks), 4):
        group = raw_blocks[offset:offset + 4]
        pairs = []
        for first, second in zip(group[::2], group[1::2]):
            by_role = {block["measurementRole"]: block for block in (first, second)}
            if set(by_role) != {"A", "B"}:
                raise ValueError(
                    f"{workload} pair at offset {offset} is not one A and one B block"
                )
            pairs.append(
                CALIBRATION.symmetric_difference(
                    by_role["A"][metric], by_role["B"][metric]
                )
            )
        quartets.append(pairs)
    return quartets


def describe_series(quartets):
    """Summarize the raw A/A spread, which is what makes a proposed rule readable."""
    values = [value for quartet in quartets for value in quartet]
    return {
        "pairCount": len(values),
        "medianPercent": statistics.median(values),
        "meanPercent": statistics.fmean(values),
        "standardDeviationPercent": (
            statistics.stdev(values) if len(values) > 1 else 0.0
        ),
        "minimumPercent": min(values),
        "maximumPercent": max(values),
        "values": values,
    }


def propose_rule(
    quartets,
    *,
    pair_count,
    effect_percent,
    equivalence_band_percent,
    trials,
    seed,
    maximum_false_positive_rate=0.01,
    minimum_detection_rate=0.90,
    maximum_inconclusive_rate=0.10,
    maximum_wrong_direction_rate=0.0,
    thresholds=THRESHOLD_GRID,
):
    """Choose the tightest threshold clearing every accuracy gate at a fixed pair count.

    The pair count is not free to choose. Plan time is measured on the very same
    blocks as the draw metric, so a plan rule can only ever be applied at the pair
    count that mode's draw rule already collects; proposing a rule that needs more
    would describe a schedule the comparison never runs.

    Returns None when no threshold clears the gates at that pair count. That is a
    real answer, not a failure to search harder: it says this workload's plan
    timer is too noisy to decide with the blocks the mode collects, and the honest
    response is to keep reporting its plan time descriptively.
    """
    eligible = [
        threshold for threshold in thresholds
        if threshold > equivalence_band_percent
    ]
    candidates = (
        CALIBRATION.calibrate_threshold_grid(
            quartets,
            pair_count,
            effect_percent,
            sorted(eligible),
            equivalence_band_percent,
            trials,
            seed,
        )
        if eligible
        else []
    )
    selected = CALIBRATION.select_candidate(
        candidates,
        maximum_false_positive_rate,
        minimum_detection_rate,
        maximum_inconclusive_rate,
        maximum_wrong_direction_rate,
    )
    return {
        "selected": selected,
        "gates": {
            "maximumFalsePositiveRate": maximum_false_positive_rate,
            "minimumDetectionRate": minimum_detection_rate,
            "maximumInconclusiveRate": maximum_inconclusive_rate,
            "maximumWrongDirectionRate": maximum_wrong_direction_rate,
        },
        "searchedCellCount": len(candidates),
    }


def analyze_series(quartets_by_workload, *, trials, seed):
    """Decide a rule per workload and mode from an already-collected series.

    Separate from collection so the analysis can be re-run against stored
    evidence: the gates, thresholds, and pair counts are all things a human
    revisits, and none of them is worth another hour of the machine's time.
    """
    results = {}
    for workload, series_quartets in quartets_by_workload.items():
        modes = {}
        for mode in COMPARE.MODES:
            rule = COMPARE.decision_rule(mode)
            modes[mode] = propose_rule(
                series_quartets,
                pair_count=rule["workloads"][workload]["pairCount"],
                effect_percent=rule["effectPercent"],
                equivalence_band_percent=rule["equivalenceBandPercent"],
                trials=trials,
                seed=seed,
            )
        results[workload] = {
            "series": describe_series(series_quartets),
            "modes": modes,
        }
    return results


def quartets_from_report(report):
    """Recover a stored report's paired series in its original quartet grouping."""
    return {
        workload: [
            result["series"]["values"][offset:offset + 2]
            for offset in range(0, len(result["series"]["values"]), 2)
        ]
        for workload, result in report["workloads"].items()
    }


def render_report(report):
    """Render the proposed rule in the terms a human needs to freeze or reject it."""
    lines = [
        f"plan-time A/A calibration from {report['arm']['revision']} "
        f"(tree {report['arm']['tree'][:12]})",
    ]
    for workload, result in report["workloads"].items():
        series = result["series"]
        lines.append(
            f"  {workload}: {series['pairCount']} A/A pairs, "
            f"median {series['medianPercent']:+.2f}%, "
            f"SD {series['standardDeviationPercent']:.2f}%, "
            f"range {series['minimumPercent']:+.2f}%..{series['maximumPercent']:+.2f}%"
            + (
                f", {result['discardedQuartetCount']} quartet(s) discarded"
                if "discardedQuartetCount" in result
                else ""
            )
        )
        for mode, proposal in result["modes"].items():
            selected = proposal["selected"]
            if selected is None:
                lines.append(
                    f"    {mode}: no threshold clears the gates at its "
                    f"{COMPARE.decision_rule(mode)['workloads'][workload]['pairCount']}"
                    " pairs -- keep reporting plan time descriptively"
                )
                continue
            lines.append(
                f"    {mode}: {selected['pairCount']} pairs at "
                f"+/-{selected['directionalThresholdPercent']}% "
                f"(A/A false positives "
                f"{selected['conditions']['aa']['falsePositiveRate']:.4f}, "
                f"detection "
                f"{min(selected['conditions']['positive']['detectionRate'], selected['conditions']['negative']['detectionRate']):.4f} "
                f"at {selected['effectPercent']}%)"
            )
    return "\n".join(lines)


def run_calibration(
    *,
    revision,
    workloads,
    quartets,
    trials,
    seed,
    repository_root,
    cache_root,
    artifacts_root,
    maximum_attempts=4,
    resolve_baseline=None,
    materialize=None,
    make_collectors=COMPARE.production_collectors,
    emit=print,
    monotonic=time.monotonic,
):
    """Collect one A/A series per workload and report the rule each one implies."""
    resolve_baseline = resolve_baseline or SNAPSHOT.resolve_baseline
    materialize = materialize or SNAPSHOT.materialize_arm
    started = monotonic()
    arm_source = resolve_baseline(repository_root, revision)
    arm = materialize(repository_root, arm_source, cache_root=cache_root)
    schedule = make_aa_schedule(workloads, quartets)
    artifacts = _run_directory(artifacts_root, arm_source["tree"])
    collectors, close = make_collectors(
        schedule,
        artifacts,
        arm_roots={"a": arm["root"], "b": arm["root"]},
        repository_root=arm["root"],
    )
    collected = {}
    try:
        for workload in schedule:
            collected[workload] = collect_quartets(
                workload,
                collectors[workload],
                quartets=quartets,
                maximum_attempts=maximum_attempts,
                emit=emit,
            )
    finally:
        close()

    results = {}
    for workload in schedule:
        kept, discarded = collected[workload]
        series_quartets = [
            pairs
            for blocks in kept
            for pairs in plan_quartets(workload, blocks)
        ]
        modes = {}
        for mode in COMPARE.MODES:
            rule = COMPARE.decision_rule(mode)
            modes[mode] = propose_rule(
                series_quartets,
                pair_count=rule["workloads"][workload]["pairCount"],
                effect_percent=rule["effectPercent"],
                equivalence_band_percent=rule["equivalenceBandPercent"],
                trials=trials,
                seed=seed,
            )
        results[workload] = {
            "series": describe_series(series_quartets),
            "discardedQuartetCount": discarded,
            "modes": modes,
        }

    report = {
        "schemaVersion": 1,
        "purpose": "plan-time-aa-calibration-only",
        "arm": {**arm_source, "root": arm["root"], "cacheHit": arm["cacheHit"]},
        "quartetsPerWorkload": quartets,
        "trialCountPerCondition": trials,
        "seed": seed,
        "workloads": results,
        "wallSeconds": monotonic() - started,
    }
    (artifacts / "plan-calibration.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (artifacts / "blocks.json").write_text(
        json.dumps(
            {workload: kept for workload, (kept, _) in collected.items()},
            indent=2,
            sort_keys=True,
        ) + "\n",
        encoding="utf-8",
    )
    emit(render_report(report))
    emit(f"Artifacts: {artifacts}")
    return report


def _run_directory(artifacts_root, tree):
    parent = pathlib.Path(artifacts_root)
    parent.mkdir(parents=True, exist_ok=True)
    ordinal = 0
    while True:
        directory = parent / f"{tree[:12]}-{ordinal:04d}"
        if not directory.exists():
            directory.mkdir()
            return directory
        ordinal += 1


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--revision", default=None)
    parser.add_argument(
        "--reanalyze",
        type=pathlib.Path,
        default=None,
        help="decide a stored plan-calibration.json again without re-measuring",
    )
    parser.add_argument(
        "--workload",
        action="append",
        dest="workloads",
        choices=PLAN_WORKLOADS,
        default=None,
    )
    parser.add_argument("--quartets", type=int, default=12)
    # The grid searches 6 pair counts x 37 thresholds x 2 modes per workload, and
    # every cell resamples independently, so trial count multiplies out fast: the
    # 100,000 the draw calibration used costs ~10 single-threaded minutes here.
    # 20,000 still resolves a 1% false-positive gate to about a thousandth, which
    # is far finer than the gate needs; raise it for a series being frozen.
    parser.add_argument("--trials", type=int, default=20_000)
    parser.add_argument("--seed", type=int, default=20260727)
    parser.add_argument("--repository-root", type=pathlib.Path, default=ROOT)
    parser.add_argument(
        "--cache-root",
        type=pathlib.Path,
        default=ROOT / ".build" / "terminal-benchmark-arms",
    )
    parser.add_argument(
        "--artifacts-root",
        type=pathlib.Path,
        default=ROOT / ".build" / "terminal-benchmark-plan-calibration",
    )
    arguments = parser.parse_args(argv)
    if arguments.reanalyze is not None:
        stored = json.loads(arguments.reanalyze.read_text(encoding="utf-8"))
        print(render_report({
            **stored,
            "workloads": analyze_series(
                quartets_from_report(stored),
                trials=arguments.trials,
                seed=arguments.seed,
            ),
        }))
        return 0
    if arguments.revision is None:
        parser.error("--revision is required unless --reanalyze is given")
    run_calibration(
        revision=arguments.revision,
        workloads=tuple(arguments.workloads or PLAN_WORKLOADS),
        quartets=arguments.quartets,
        trials=arguments.trials,
        seed=arguments.seed,
        repository_root=arguments.repository_root,
        cache_root=arguments.cache_root,
        artifacts_root=arguments.artifacts_root,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
