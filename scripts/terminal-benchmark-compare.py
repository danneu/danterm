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
import os
import pathlib
import statistics
import subprocess
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
    # Present so a candidate workload can be screened, and absent from
    # DECISION_RULES until one is: naming the metric is what lets an A/A series be
    # reduced to paired differences at all. A workload here but not there is
    # collectable and undecidable, which is the state a screen resolves.
    "synchronized-frames": "finalDrawNanoseconds",
    # Two more candidates, and the only place a workload's deciding metric is
    # not draw time or replay time. Each names the quantity screened for its own
    # regression (research/29/D2). The routing is workload-local -- no existing
    # workload gains CPU verdict authority from it, and both entries stay out of
    # DECISION_RULES until a screen freezes a threshold for them.
    "sparse-spans-few": "drawNanosecondsPerDraw",
    "sparse-spans-max": "processCPUNanosecondsPerDraw",
    # The browsing candidate, and the only deciding metric on the ladder that is
    # plan time rather than draw or replay time. That is the point rather than an
    # exception: `research/15/F18` measured compact retained rows at -5.79% on frame
    # *planning* over history, and no draw bracket can observe that -- planning
    # runs on the PTY-output path, outside the bracket the four draw workloads
    # measure. Stays out of DECISION_RULES until a screen freezes a threshold.
    "retained-browse": "planNanosecondsPerFrame",
}
# Reported beside the draw verdict and decided separately from it. The
# serialized-draw metric above brackets only clipping and drawing, so it
# structurally cannot observe `planFrame`, which runs on the PTY-output path
# instead. These blocks therefore carry a second quantity for planner work: the
# median duration of the block's full-viewport plans. One class of plan rather
# than a sum over every plan, because a block also holds mid-screen partial
# plans at roughly half the cost in a proportion PTY chunking sets, and the sum
# moved with that proportion on identical binaries (research/38/F1). It is
# classified against a rule in `DECISION_RULES[mode]["planWorkloads"]` when one
# exists and left unclassified otherwise, which is the whole of what a missing
# plan-time rule means. `incremental-mixed` is absent: it replans four or five
# rows per update and never a full viewport, so there is nothing to select.
AUXILIARY_BLOCK_METRICS = {
    "content-churn": "planNanosecondsPerFullPlan",
    "style-churn": "planNanosecondsPerFullPlan",
}
# A second quantity reported beside the same blocks, and deliberately not in the
# table above: whole-process CPU summed over every thread. T25 removed the known
# asynchronous Core Animation replay that motivated it, but this remains a useful
# all-thread diagnostic beside the main-thread render bracket.
#
# Kept out of `AUXILIARY_BLOCK_METRICS` rather than added to it because that table
# drives the `planWorkloads` rule lookup, and this metric has no rule to look up.
# That is a measured outcome, not a gap: a 24-pair paired A/A screen (`research/17/F15`)
# found that on every workload, in both modes, the threshold quiet enough to clear a
# 1% false-positive rate is already too wide to detect the mode's own effect size --
# the two gates cross with no overlap. An auxiliary metric rides the deciding
# metric's blocks and so cannot buy more pairs, which is the only knob that would
# close the gap. It is therefore reported unclassified permanently, and `research/17/D6`
# names the uses that remain (undermining a suspect verdict, sizing an off-thread
# cost) and the one that does not (confirming a win).
UNCALIBRATED_BLOCK_METRICS = {
    "content-churn": "processCPUNanosecondsPerDraw",
    "style-churn": "processCPUNanosecondsPerDraw",
    "incremental-mixed": "processCPUNanosecondsPerDraw",
}
# Workloads that report an absolute cost *composition* rather than a paired
# percentage: how the measured block divides into draining the PTY and the draw
# tail that follows it. This is not a third metric competing for a verdict, and
# it is deliberately in neither table above -- it pairs nothing and classifies
# nothing, so there is no rule for it to look up and nothing for a screen to
# calibrate.
#
# It exists because research doc 20 found `producerWriteNanoseconds` recorded in every
# `scrollback-stream` block since the harness was written (`research/20/F2`),
# referenced by no metric table, and sitting at 95.7% of the deciding metric.
# Two consequences follow, and neither was readable from the verdict alone: this
# workload has always been ~96% a PTY throughput measurement, and a change that
# touches only the draw path can move it by at most ~4%, because the draw tail is
# all that is left. Reporting the split is what makes a flat verdict on a real
# drawing win legible as the expected result rather than a failure.
#
# Only this workload qualifies. The three serialized-draw workloads write one
# update and then wait for that exact draw, so their producer write time measures
# the handshake rather than throughput, and a rate derived from it would invite a
# comparison the number cannot support.
COMPOSITION_WORKLOADS = {"scrollback-stream"}
# The metric tables an A/A calibration run may screen, keyed by the name its
# operator types. Naming the table prevents a run intended for one quantity from
# quietly reporting another. Draw owns the blocks; plan and process CPU ride the
# same collection as auxiliary quantities.
CALIBRATABLE_METRIC_TABLES = {
    "draw": {
        workload: BLOCK_METRICS[workload]
        for workload in ("content-churn", "style-churn", "incremental-mixed")
    },
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


def quartet_phase(candidate_tree):
    """Pick which pattern the first quartet uses, from the tree bit above the slot bit.

    Quick mode is one quartet, so alternating patterns only across quartets left
    every quick run ABBA and the baseline always owning the first block; a
    first-position cost then never reversed (research/38/F2). Deriving the phase
    from the tree makes the alternation hold across invocations, independently
    of the slot, and keeps it reproducible from the record.
    """
    return (int(candidate_tree, 16) >> 1) & 1


def make_schedule(mode, workloads, *, physical_candidate_arm, quartet_phase=0):
    """Lay out every block of the invocation up front at the frozen fixed pair count."""
    rule = decision_rule(mode)
    if quartet_phase not in (0, 1):
        raise ValueError(f"unknown quartet phase: {quartet_phase}")
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
            pattern = QUARTET_PATTERNS[(quartet + quartet_phase) % len(QUARTET_PATTERNS)]
            for role in pattern:
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

    Both shapes exist so that a rule can be frozen without touching this code:
    until a human moves `DECISION_RULES[mode]["planWorkloads"]` from an A/A
    report on the full-plan median, every workload reads the descriptive shape,
    and that is the honest reading of a quantity no rule yet stands behind.
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
    run and refused it a rule at every mode's pair count (`research/17/F15`). Any
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


def summarize_composition(workload, raw_blocks):
    """Describe how a block divides into PTY drain and draw tail, per arm, deciding nothing.

    Returns None rather than raising or assuming a corpus size whenever the
    evidence cannot support a rate: a baseline arm predating the byte counter has
    none, and two arms that drained different byte totals have no shared
    denominator. Averaging across those would yield a rate belonging to neither
    arm while looking exactly like a valid one.

    Reported per arm rather than as one figure because the drain rate is the
    marker an operator watches move between revisions; the paired verdict above
    already answers the direction question for the block as a whole.
    """
    if workload not in COMPOSITION_WORKLOADS or not raw_blocks:
        return None
    metric = BLOCK_METRICS[workload]
    if any(
        block.get("producerWriteNanoseconds") is None
        or block.get("producerWriteBytes") is None
        or block.get(metric) is None
        for block in raw_blocks
    ):
        return None
    corpus_bytes = {block["producerWriteBytes"] for block in raw_blocks}
    if len(corpus_bytes) != 1:
        return None
    corpus = next(iter(corpus_bytes))
    geometries = {
        json.dumps(block.get("producerWriteGeometry"), sort_keys=True)
        for block in raw_blocks
    }
    by_role = {"A": "baseline", "B": "candidate"}
    arms = {}
    for role, arm in by_role.items():
        blocks = [
            block for block in raw_blocks if block.get("measurementRole") == role
        ]
        if not blocks:
            return None
        drain = [float(block["producerWriteNanoseconds"]) for block in blocks]
        tail = [
            float(block[metric]) - float(block["producerWriteNanoseconds"])
            for block in blocks
        ]
        arms[arm] = {
            "drainNanoseconds": statistics.median(drain),
            "drainMegabytesPerSecond": statistics.median(
                corpus / (value / 1e9) / 1e6 for value in drain
            ),
            "tailNanoseconds": statistics.median(tail),
            "tailPercent": statistics.median(
                (float(block[metric]) - float(block["producerWriteNanoseconds"]))
                / float(block[metric])
                * 100.0
                for block in blocks
            ),
        }
    return {
        "corpusBytes": corpus,
        "geometry": (
            json.loads(geometries.pop()) if len(geometries) == 1 else None
        ),
        "arms": arms,
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
    if "directionalThresholdPercent" not in workload_rule:
        return None
    return CALIBRATION.decide(
        differences,
        workload_rule["directionalThresholdPercent"],
        rule["equivalenceBandPercent"],
        estimator=rule["estimator"],
    )


def _default_process_table():
    """Read every process as (pid, ppid, cpu percent, command), busiest first."""
    result = subprocess.run(
        ["ps", "-A", "-o", "pid=,ppid=,pcpu=,comm=", "-r"],
        check=True,
        capture_output=True,
        text=True,
    )
    table = []
    for line in result.stdout.splitlines():
        fields = line.split(None, 3)
        if len(fields) != 4:
            continue
        pid, parent, cpu, command = fields
        try:
            table.append((int(pid), int(parent), float(cpu), command.strip()))
        except ValueError:
            continue
    return table


def sample_host_conditions(
    *,
    load_average=os.getloadavg,
    processor_count=os.cpu_count,
    list_processes=_default_process_table,
    driver_pid=None,
    top_count=5,
):
    """Read what else the machine is doing, for the artifact to carry beside the verdict.

    This exists because of one incident (research/28/F2): a confirm run taken on a loaded
    host reported four `slower` verdicts with `invalidations: []`, and three of
    them did not survive re-measurement against the same trees. Host load is a
    stated condition of every frozen rule and the only one the harness could not
    observe, so it went unrecorded exactly when it mattered.

    Two properties are deliberate. It reports "not measured" as a distinct state
    from "measured idle", because a dropped key reads as a clean machine to the
    next person. And it excludes the driver's own descendants, because research/28/F3
    measured that the harness's builds and GUI app are most of the load during a
    run -- a reading that counted those would condemn every run and be ignored.

    It sets no threshold and returns no verdict: research/28/D1 admitted this scoped to
    annotate-and-record precisely because nobody has calibrated what load
    actually perturbs a decision, and a wrong refusal gate is worse than none.
    """
    driver_pid = os.getpid() if driver_pid is None else driver_pid
    try:
        one, five, fifteen = load_average()
        processors = processor_count() or 1
        table = list(list_processes())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        return {"available": False, "reason": f"host probe failed: {error}"}

    parents = {pid: parent for pid, parent, _, _ in table}
    harness = set()
    for pid in parents:
        walker, seen = pid, set()
        while walker and walker not in seen:
            seen.add(walker)
            if walker == driver_pid:
                harness.add(pid)
                break
            walker = parents.get(walker)
    external = [
        {"pid": pid, "command": command, "cpuPercent": cpu}
        for pid, _, cpu, command in table
        if pid not in harness
    ]
    external.sort(key=lambda entry: entry["cpuPercent"], reverse=True)
    return {
        "available": True,
        "loadAverage": {"one": one, "five": five, "fifteen": fifteen},
        "processorCount": processors,
        "loadPerProcessor": one / processors,
        "topExternalProcesses": external[:top_count],
        "excludedHarnessProcessCount": len(harness),
    }


def _render_host_reading(label, reading):
    """Render one pre-launch reading as an observation, never as a gate."""
    if not reading:
        return [f"  {label}: not measured (no reading was taken)"]
    if not reading.get("available"):
        return [f"  {label}: not measured -- {reading.get('reason', 'unknown')}"]
    load = reading["loadAverage"]
    lines = [
        f"  {label}: load {load['one']:.2f}/{load['five']:.2f}/{load['fifteen']:.2f}"
        f" ({reading['loadPerProcessor']:.2f} per processor"
        f" across {reading['processorCount']}; descriptive, no verdict)"
    ]
    # Basename for the operator, full path in the artifact: a nix-store or
    # framework path is most of a terminal line and buries the number beside it.
    busiest = ", ".join(
        f"{entry['command'].rsplit('/', 1)[-1]} {entry['cpuPercent']:.1f}%"
        for entry in reading["topExternalProcesses"][:3]
    )
    if busiest:
        lines.append(f"    busiest external: {busiest}")
    return lines


def render_host_conditions(conditions):
    """Render both pre-launch readings, naming which one the builds confounded."""
    if not conditions:
        return ""
    lines = ["Host conditions (sampled before any block; no threshold is applied):"]
    lines.extend(_render_host_reading("at invocation", conditions.get("atInvocation")))
    lines.extend(
        _render_host_reading(
            "before first block", conditions.get("beforeFirstBlock")
        )
    )
    # Said here rather than left for the reader to infer, because research/28/F3 found the
    # confound by measuring it: the second reading follows this command's own
    # arm builds, so it is the harness's floor, not the operator's machine.
    lines.append(
        "    the second reading follows this run's own builds and is "
        "confounded by them; the first is the operator's idle machine"
    )
    return "\n".join(lines)


def summarize_comparison(mode, evidence, host_conditions=None):
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
            "composition": (
                summarize_composition(workload, raw_blocks)
                if eligible
                else None
            ),
        }
    return {
        "mode": mode,
        "decisionEligible": eligible,
        "invalidationReasons": reasons,
        "workloads": workloads,
        "hostConditions": host_conditions,
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
        conditions = render_host_conditions(summary.get("hostConditions"))
        if conditions:
            lines.append(conditions)
        return "\n".join(lines)
    lines = [f"{summary['mode']}: candidate versus baseline"]
    for workload, result in summary["workloads"].items():
        decision = result["decision"]
        if decision is None:
            differences = result["pairedSymmetricPercent"]
            lines.append(
                f"  {workload}: {statistics.median(differences):+.2f}% symmetric "
                f"median of {len(differences)} pairs "
                "(descriptive, no verdict -- uncalibratable)"
            )
        else:
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
        composition = result.get("composition")
        if composition:
            # Absolute costs, not a paired percentage, and the denominator is
            # spelled out on the line: a rate is meaningless without the corpus
            # and geometry that produced it, and a reader who cannot reconstruct
            # the arithmetic cannot tell this apart from a verdict.
            geometry = composition["geometry"]
            denominator = f"{composition['corpusBytes'] / 1e6:.2f} MB corpus"
            if geometry:
                denominator += f" at {geometry['columns']}x{geometry['rows']}"
            for arm in ("baseline", "candidate"):
                values = composition["arms"][arm]
                lines.append(
                    f"    drain ({arm}): {values['drainNanoseconds'] / 1e6:.1f} ms, "
                    f"{values['drainMegabytesPerSecond']:.1f} MB/s "
                    f"({denominator}; descriptive, no verdict)"
                )
                lines.append(
                    f"    draw tail ({arm}): {values['tailNanoseconds'] / 1e6:.1f} ms "
                    f"({values['tailPercent']:.1f}% of block)"
                )
    conditions = render_host_conditions(summary.get("hostConditions"))
    if conditions:
        lines.append(conditions)
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
    sample_host_conditions=sample_host_conditions,
):
    """Perform one complete comparison: report the sources, measure, decide once, record."""
    resolve_baseline = resolve_baseline or SNAPSHOT.resolve_baseline
    snapshot_candidate = snapshot_candidate or SNAPSHOT.snapshot_candidate
    materialize = materialize or SNAPSHOT.materialize_arm
    workloads = resolve_workloads(mode, workload)

    started = monotonic()
    # Taken before the snapshot rather than beside the blocks: this is the only
    # moment the machine is the operator's rather than this command's, and it is
    # the reading research/28/F2's contaminated run needed and did not have.
    host_conditions = {"atInvocation": sample_host_conditions()}
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
    phase = quartet_phase(candidate["tree"])
    schedule = make_schedule(
        mode, workloads, physical_candidate_arm=candidate_arm, quartet_phase=phase
    )
    artifacts = _run_directory(artifacts_root, mode, candidate["tree"])
    # The last instant before collection begins, and still off every measured
    # path. Kept separate from the invocation reading because the arm builds sit
    # between them, so this one is the harness's own floor.
    host_conditions["beforeFirstBlock"] = sample_host_conditions()
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

    summary = summarize_comparison(mode, evidence, host_conditions=host_conditions)
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
        "quartetPhase": phase,
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
        "quartetPhase": phase,
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
