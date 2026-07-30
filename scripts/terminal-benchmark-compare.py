#!/usr/bin/env python3
"""Run one paired baseline-vs-candidate benchmark comparison and decide it once.

This is the whole of `benchmark-quick` and `benchmark-confirm` above the source
layer: it selects the workloads a mode measures, lays out a position-balanced
ABBA/BAAB schedule at the frozen fixed pair count, binds the two immutable arm
roots to physical slots, collects blocks through the tested workload collectors,
and applies the frozen median symmetric rule exactly once. It owns the two
properties that keep a directional claim honest -- the schedule's size is fixed
before any measurement exists (so there is nothing to peek at or extend), and a
single invalid block voids the entire invocation rather than the block. Source
snapshotting and build caching belong to `terminal_benchmark_snapshot`; the
workload stimuli, machine-state validation, and persistent app lifecycles belong
to the collectors this module calls. Nothing here writes durable history: each
invocation's complete evidence lands in its own artifact directory.
"""
import argparse
import importlib.util
import json
import pathlib
import statistics
import sys
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

MODES = ("quick", "confirm")
# The normalized per-block quantity each collector reports. Pairing reads only
# these, so a workload can never be paired on a cumulative total that means
# something different from its calibrated metric.
BLOCK_METRICS = {
    "terminal-feed": "feedDurationNanoseconds",
    "scrollback-stream": "finalDrawNanoseconds",
    "content-churn": "drawNanosecondsPerDraw",
    "style-churn": "drawNanosecondsPerDraw",
    "incremental-mixed": "drawNanosecondsPerDraw",
}
# Reported beside the draw verdict and decided separately from it. The
# serialized-draw metric above brackets only clipping and drawing, so it
# structurally cannot observe `planFrame`, which runs on the PTY-output path
# instead. These blocks therefore carry a second quantity for planner work,
# classified against its own calibrated rule in `DECISION_RULES[mode]
# ["planWorkloads"]` -- and left unclassified for any workload absent from that
# table, which is the whole of what a missing plan-time rule means.
AUXILIARY_BLOCK_METRICS = {
    "content-churn": "planNanosecondsPerDraw",
    "style-churn": "planNanosecondsPerDraw",
    "incremental-mixed": "planNanosecondsPerDraw",
}
# A second quantity reported beside the same blocks, and deliberately not in the
# table above: whole-process CPU summed over every thread. It is here because the
# draw metric measures elapsed time between two points on the main thread, so
# work on any other thread is invisible to it at any size -- and doc 17's `F6`
# found the app's largest single cost, Core Animation recomputing per-glyph
# bounds during display-list replay, living precisely there.
#
# Kept out of `AUXILIARY_BLOCK_METRICS` rather than added to it because that table
# drives the `planWorkloads` rule lookup, and this metric has no rule to look up.
# That is a measured outcome, not a gap: a 24-pair paired A/A screen (doc 17 `F15`)
# found that on every workload, in both modes, the threshold quiet enough to clear a
# 1% false-positive rate is already too wide to detect the mode's own effect size --
# the two gates cross with no overlap. An auxiliary metric rides the deciding
# metric's blocks and so cannot buy more pairs, which is the only knob that would
# close the gap. It is therefore reported unclassified permanently, and doc 17 `D6`
# names the uses that remain (undermining a suspect verdict, sizing an off-thread
# cost) and the one that does not (confirming a win).
UNCALIBRATED_BLOCK_METRICS = {
    "content-churn": "processCPUNanosecondsPerDraw",
    "style-churn": "processCPUNanosecondsPerDraw",
    "incremental-mixed": "processCPUNanosecondsPerDraw",
}
# The auxiliary tables an A/A calibration run may screen, keyed by the name its
# operator types. It exists so the calibrator names a metric instead of reaching
# into one hardcoded table: the two above ride the very same blocks, so one
# collection can screen either, and a run that meant CPU must not be able to
# quietly report plan-time noise instead. Adding an entry here is what makes a
# new auxiliary quantity screenable; moving that quantity from
# `UNCALIBRATED_BLOCK_METRICS` into `AUXILIARY_BLOCK_METRICS` is what freezing
# its rule means.
CALIBRATABLE_METRIC_TABLES = {
    "plan": AUXILIARY_BLOCK_METRICS,
    "process-cpu": UNCALIBRATED_BLOCK_METRICS,
}
# Alternated across quartets so neither source sits first in every group of four.
QUARTET_PATTERNS = ("ABBA", "BAAB")


def decision_rule(mode):
    """Expose the frozen rule for one mode, which is calibration output and not a tunable."""
    if mode not in VALIDATION.DECISION_RULES:
        raise ValueError(f"unknown comparison mode: {mode}")
    return VALIDATION.DECISION_RULES[mode]


def resolve_workloads(mode, workload=None):
    """Fix which workloads an invocation measures before any of them run."""
    decision_rule(mode)
    if mode == "confirm":
        if workload is not None:
            raise ValueError(
                "confirm always runs the complete five-workload ladder; "
                "use quick to select a single workload"
            )
        return VALIDATION.WORKLOADS
    if workload is None:
        raise ValueError(
            "quick requires workload=<name>; it measures exactly one workload"
        )
    if workload not in VALIDATION.WORKLOADS:
        raise ValueError(
            f"unknown workload {workload}; expected one of "
            f"{', '.join(VALIDATION.WORKLOADS)}"
        )
    return (workload,)


def physical_candidate_arm(candidate_tree):
    """Pick the candidate's physical slot reproducibly from the candidate's own identity.

    Both arms launch once per invocation, so the slot cannot alternate within a
    run. Deriving it from the tree keeps the assignment inspectable and
    reproducible while still varying across candidates, instead of pinning the
    candidate to one slot forever.
    """
    return "a" if int(candidate_tree, 16) & 1 else "b"


def make_schedule(mode, workloads, *, physical_candidate_arm):
    """Lay out every block of the invocation up front at the frozen fixed pair count."""
    rule = decision_rule(mode)
    if physical_candidate_arm not in ("a", "b"):
        raise ValueError(
            f"unknown physical candidate arm: {physical_candidate_arm}"
        )
    baseline_arm = "a" if physical_candidate_arm == "b" else "b"
    schedule = {}
    for workload in workloads:
        if workload not in rule["workloads"]:
            raise ValueError(f"unknown workload {workload} for mode {mode}")
        pair_count = rule["workloads"][workload]["pairCount"]
        if pair_count <= 0 or pair_count % 2:
            raise ValueError(
                f"{mode}/{workload} pair count must form complete quartets"
            )
        blocks = []
        for quartet in range(pair_count // 2):
            for role in QUARTET_PATTERNS[quartet % len(QUARTET_PATTERNS)]:
                blocks.append({
                    "measurementRole": role,
                    "physicalArm": (
                        physical_candidate_arm if role == "B" else baseline_arm
                    ),
                    "quartet": quartet,
                })
        schedule[workload] = blocks
    return schedule


def paired_differences(workload, raw_blocks):
    """Reduce a collected block series to its adjacent source-oriented paired differences."""
    if workload not in BLOCK_METRICS:
        raise ValueError(f"unknown workload {workload}")
    if not raw_blocks or len(raw_blocks) % 2:
        raise ValueError(
            f"{workload} pairing requires a non-empty even block series"
        )
    metric = BLOCK_METRICS[workload]
    differences = []
    for offset in range(0, len(raw_blocks), 2):
        pair = raw_blocks[offset:offset + 2]
        by_role = {block["measurementRole"]: block for block in pair}
        if set(by_role) != {"A", "B"}:
            raise ValueError(
                f"{workload} block pair at offset {offset} is not one "
                "baseline and one candidate block"
            )
        differences.append(
            CALIBRATION.symmetric_difference(
                by_role["A"][metric], by_role["B"][metric]
            )
        )
    return differences


def auxiliary_differences(workload, raw_blocks, metrics=None):
    """Pair one auxiliary metric the same way, or report nothing when it is absent.

    Returns None rather than raising or substituting zero: a baseline arm built
    from a revision that predates the metric's timer legitimately has no such
    evidence, and that must not block the draw verdict for the same blocks.
    """
    metric = (AUXILIARY_BLOCK_METRICS if metrics is None else metrics).get(workload)
    if metric is None or not raw_blocks or len(raw_blocks) % 2:
        return None
    if any(block.get(metric) is None for block in raw_blocks):
        return None
    differences = []
    for offset in range(0, len(raw_blocks), 2):
        by_role = {
            block["measurementRole"]: block
            for block in raw_blocks[offset:offset + 2]
        }
        if set(by_role) != {"A", "B"}:
            return None
        differences.append(
            CALIBRATION.symmetric_difference(
                by_role["A"][metric], by_role["B"][metric]
            )
        )
    return differences


def summarize_auxiliary(mode, workload, raw_blocks):
    """Classify the plan-time evidence where a calibrated rule exists, describe it where none does.

    Both shapes coexist because plan-time noise is not uniform across workloads:
    `incremental-mixed` measures a few damaged rows, so its per-draw plan time is
    small and its A/A spread swamps any threshold worth claiming. Reporting an
    unclassified number there is not a gap to be closed later -- it is the honest
    reading of a metric no rule can stand behind.
    """
    differences = auxiliary_differences(workload, raw_blocks)
    if not differences:
        return None
    summary = {
        "metric": AUXILIARY_BLOCK_METRICS[workload],
        "pairedSymmetricPercent": differences,
        "estimatePercent": statistics.median(differences),
        "sampleCount": len(differences),
        "decision": None,
    }
    rule = decision_rule(mode).get("planWorkloads", {}).get(workload)
    if rule and len(differences) == rule["pairCount"]:
        summary["decision"] = CALIBRATION.decide(
            differences,
            rule["directionalThresholdPercent"],
            rule["equivalenceBandPercent"],
            estimator=decision_rule(mode)["estimator"],
        )
    return summary


def summarize_uncalibrated(workload, raw_blocks):
    """Describe an uncalibrated metric's paired spread without ever classifying it.

    Takes no `mode` and consults no rule table, so there is no code path by which
    this can produce a verdict. That is the point, and it is now settled rather
    than provisional: the A/A screening that would have calibrated this metric was
    run and refused it a rule at every mode's pair count (doc 17 `F15`). Any
    threshold applied to this number would be invented rather than measured, and
    the measurement says no honest one exists here.
    """
    differences = auxiliary_differences(
        workload, raw_blocks, metrics=UNCALIBRATED_BLOCK_METRICS
    )
    if not differences:
        return None
    return {
        "metric": UNCALIBRATED_BLOCK_METRICS[workload],
        "pairedSymmetricPercent": differences,
        "estimatePercent": statistics.median(differences),
        "sampleCount": len(differences),
        "decision": None,
        "calibrated": False,
    }


def decide_workload(mode, workload, differences):
    """Apply the frozen fixed-N median rule, refusing any other number of pairs."""
    rule = decision_rule(mode)
    if workload not in rule["workloads"]:
        raise ValueError(f"unknown workload {workload} for mode {mode}")
    workload_rule = rule["workloads"][workload]
    if len(differences) != workload_rule["pairCount"]:
        raise ValueError(
            f"{mode}/{workload} decides on exactly "
            f"{workload_rule['pairCount']} pairs, received {len(differences)}"
        )
    return CALIBRATION.decide(
        differences,
        workload_rule["directionalThresholdPercent"],
        rule["equivalenceBandPercent"],
        estimator=rule["estimator"],
    )


def summarize_comparison(mode, evidence):
    """Decide a complete invocation, or none of it, and keep every raw block either way."""
    reasons = list(evidence.get("invalidationReasons", []))
    eligible = bool(evidence.get("valid")) and not reasons
    workloads = {}
    for workload, workload_evidence in evidence["workloads"].items():
        raw_blocks = workload_evidence["rawBlocks"]
        differences = paired_differences(workload, raw_blocks) if eligible else None
        workloads[workload] = {
            "rawBlocks": raw_blocks,
            "invalidationReasons": list(
                workload_evidence.get("invalidationReasons", [])
            ),
            "pairedSymmetricPercent": differences,
            "decision": (
                decide_workload(mode, workload, differences)
                if eligible
                else None
            ),
            "auxiliary": (
                summarize_auxiliary(mode, workload, raw_blocks)
                if eligible
                else None
            ),
            "uncalibrated": (
                summarize_uncalibrated(workload, raw_blocks)
                if eligible
                else None
            ),
        }
    return {
        "mode": mode,
        "decisionEligible": eligible,
        "invalidationReasons": reasons,
        "workloads": workloads,
    }


def render_decisions(summary):
    """Render the verdict in the operator's terms: baseline versus candidate."""
    if not summary["decisionEligible"]:
        lines = [
            f"{summary['mode']}: no decision -- this invocation is invalid.",
            "  Every raw block is retained; a new decision needs a fresh "
            "complete invocation.",
        ]
        lines.extend(f"  {reason}" for reason in summary["invalidationReasons"])
        return "\n".join(lines)
    lines = [f"{summary['mode']}: candidate versus baseline"]
    for workload, result in summary["workloads"].items():
        decision = result["decision"]
        lines.append(
            f"  {workload}: {decision['decision']} "
            f"({decision['estimatePercent']:+.2f}% symmetric median of "
            f"{decision['sampleCount']} pairs)"
        )
        if decision["outlierIndices"]:
            lines.append(
                "    flagged outlier pairs (retained in the estimate): "
                + ", ".join(str(index) for index in decision["outlierIndices"])
            )
        auxiliary = result.get("auxiliary")
        if auxiliary:
            plan_decision = auxiliary.get("decision")
            qualifier = (
                f"{plan_decision['decision']}"
                if plan_decision
                else "descriptive, no verdict -- uncalibrated"
            )
            lines.append(
                f"    plan time: {auxiliary['estimatePercent']:+.2f}% symmetric "
                f"median of {auxiliary['sampleCount']} pairs ({qualifier})"
            )
        uncalibrated = result.get("uncalibrated")
        if uncalibrated:
            # Spelled out rather than shown as a bare percentage beside two
            # verdicts: this line sits under a classified draw result, so the
            # only way it cannot be misread as a third verdict is to say what it
            # is not.
            lines.append(
                f"    process CPU: {uncalibrated['estimatePercent']:+.2f}% symmetric "
                f"median of {uncalibrated['sampleCount']} pairs "
                "(descriptive, no verdict -- uncalibrated; all threads, CPU "
                "consumed not latency)"
            )
    return "\n".join(lines)


def _describe_arms(arms):
    lines = ["Arm build products:"]
    for role, arm in arms.items():
        lines.append(
            f"  {role:9s} {'cached' if arm['cacheHit'] else 'built'} "
            f"{arm['root']}"
        )
    return "\n".join(lines)


def _run_directory(artifacts_root, mode, candidate_tree):
    """Give every invocation its own directory, since no run may overwrite another's evidence."""
    parent = pathlib.Path(artifacts_root) / mode
    parent.mkdir(parents=True, exist_ok=True)
    prefix = candidate_tree[:12]
    ordinal = 0
    while True:
        directory = parent / f"{prefix}-{ordinal:04d}"
        if not directory.exists():
            directory.mkdir()
            return directory
        ordinal += 1


def production_collectors(schedule, attempt_directory, *, arm_roots, repository_root):
    """Bind the tested workload collectors to two immutable arm roots.

    `repository_root` here is the baseline arm root, not the operator's checkout:
    the stimulus fixtures and producer script must come from a named immutable
    revision so both arms are driven by the same one, and so a working-tree edit
    cannot silently redefine a workload mid-comparison.
    """
    repository_root = pathlib.Path(repository_root)
    if "terminal-feed" in schedule:
        sample_state = VALIDATION.make_terminal_feed_state_sampler(
            pathlib.Path(attempt_directory) / "terminal-feed-state"
        )
    else:
        sample_state = dict
    return VALIDATION.make_production_collectors(
        schedule,
        attempt_directory,
        arm_roots=arm_roots,
        repository_root=repository_root,
        sample_state=sample_state,
    )


def run_comparison(
    *,
    mode,
    baseline_revision,
    workload,
    repository_root,
    cache_root,
    artifacts_root,
    resolve_baseline=None,
    snapshot_candidate=None,
    materialize=None,
    make_collectors=production_collectors,
    emit=print,
    monotonic=time.monotonic,
):
    """Perform one complete comparison: report the sources, measure, decide once, record."""
    resolve_baseline = resolve_baseline or SNAPSHOT.resolve_baseline
    snapshot_candidate = snapshot_candidate or SNAPSHOT.snapshot_candidate
    materialize = materialize or SNAPSHOT.materialize_arm
    workloads = resolve_workloads(mode, workload)

    started = monotonic()
    baseline = resolve_baseline(repository_root, baseline_revision)
    candidate = snapshot_candidate(repository_root)
    # Before either build: what each arm will contain, so a wrong baseline or a
    # stray captured path is caught while cancelling is still free.
    emit(SNAPSHOT.describe_sources(baseline, candidate))
    if baseline["tree"] == candidate["tree"]:
        # Both arms would resolve to one cache entry, so every block would measure
        # the same binary and the run would report a confident "equivalent" for a
        # change it never contained.
        raise ValueError(
            f"baseline {baseline['revision']} and the candidate working tree are "
            f"the same tree ({baseline['tree']}); there is nothing to compare"
        )
    snapshot_finished = monotonic()

    arms = {
        "baseline": materialize(repository_root, baseline, cache_root=cache_root),
        "candidate": materialize(repository_root, candidate, cache_root=cache_root),
    }
    emit(_describe_arms(arms))
    build_finished = monotonic()

    candidate_arm = physical_candidate_arm(candidate["tree"])
    baseline_arm = "a" if candidate_arm == "b" else "b"
    arm_roots = {
        candidate_arm: arms["candidate"]["root"],
        baseline_arm: arms["baseline"]["root"],
    }
    schedule = make_schedule(
        mode, workloads, physical_candidate_arm=candidate_arm
    )
    artifacts = _run_directory(artifacts_root, mode, candidate["tree"])
    collectors, close = make_collectors(
        schedule,
        artifacts,
        arm_roots=arm_roots,
        repository_root=arms["baseline"]["root"],
    )
    try:
        evidence = VALIDATION.collect_attempt(schedule, collectors=collectors)
    finally:
        close()
    comparison_finished = monotonic()

    summary = summarize_comparison(mode, evidence)
    emit(render_decisions(summary))
    timings = {
        "snapshotSeconds": snapshot_finished - started,
        "cachePopulationSeconds": build_finished - snapshot_finished,
        "cachedComparisonSeconds": comparison_finished - build_finished,
        "totalSeconds": monotonic() - started,
    }
    record = {
        "schemaVersion": 1,
        "mode": mode,
        "baseline": baseline,
        "candidate": candidate,
        "arms": arms,
        "physicalCandidateArm": candidate_arm,
        "schedule": schedule,
        "decisionRule": decision_rule(mode),
        "blockContracts": VALIDATION.BLOCK_CONTRACTS,
        "summary": summary,
        "timings": timings,
    }
    (artifacts / "run.json").write_text(
        json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    emit(
        f"Artifacts: {artifacts}\n"
        f"  snapshot {timings['snapshotSeconds']:.1f}s"
        f" | cache {timings['cachePopulationSeconds']:.1f}s"
        f" | comparison {timings['cachedComparisonSeconds']:.1f}s"
        f" | total {timings['totalSeconds']:.1f}s"
    )
    return {
        "mode": mode,
        "baseline": baseline,
        "candidate": candidate,
        "arms": arms,
        "physicalCandidateArm": candidate_arm,
        "schedule": schedule,
        "summary": summary,
        "timings": timings,
        "artifacts": str(artifacts),
    }


def main(argv=None, *, stderr=None):
    """Run one comparison and exit non-zero when the invocation produced no decision."""
    stderr = sys.stderr if stderr is None else stderr
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=MODES)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--workload", default=None)
    parser.add_argument("--repository-root", type=pathlib.Path, default=ROOT)
    parser.add_argument(
        "--cache-root",
        type=pathlib.Path,
        default=ROOT / ".build" / "terminal-benchmark-arms",
    )
    parser.add_argument(
        "--artifacts-root",
        type=pathlib.Path,
        default=ROOT / ".build" / "terminal-benchmark-comparisons",
    )
    arguments = parser.parse_args(argv)
    # Mode/workload selection is the one failure an operator hits by typing, so it
    # reports as a usage error rather than a traceback. Everything after this point
    # failing loudly is the point.
    try:
        resolve_workloads(arguments.mode, arguments.workload)
    except ValueError as error:
        stderr.write(f"error: {error}\n")
        return 2
    result = run_comparison(
        mode=arguments.mode,
        baseline_revision=arguments.baseline,
        workload=arguments.workload,
        repository_root=arguments.repository_root,
        cache_root=arguments.cache_root,
        artifacts_root=arguments.artifacts_root,
    )
    return 0 if result["summary"]["decisionEligible"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
