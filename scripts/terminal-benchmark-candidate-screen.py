#!/usr/bin/env python3
"""Screen a candidate workload's primary metric for a decision rule.

A candidate workload is one the corpus can collect and the comparison cannot yet
decide: it has blocks, a block contract, and no frozen threshold. This runs the
A/A series that resolves that state, and reports the rule it implies.

Distinct from `terminal-benchmark-plan-calibration.py` in the one way that
matters. That screens an *auxiliary* metric, which rides the deciding metric's
blocks and therefore cannot buy more pairs -- research/17/F15 refused a rule on exactly
that constraint. A candidate workload owns its blocks, so the pair count is a
free variable and is searched here alongside the threshold. A rule that needs
more pairs is a real proposal, priced in machine time rather than impossible.

Both physical arms bind to one immutable root, so every measured difference is
noise by construction. It never edits the frozen rules: a human reads the report
and moves a threshold into `DECISION_RULES`, and moves the workload out of
`CANDIDATE_WORKLOADS` into `WORKLOADS`.

Two subcommands, because a screen is not a freeze. `screen` collects the A/A
series and searches the grid; `confirm` re-runs only the cell that search selected,
at more trials and disjoint fresh seeds, against the same evidence and the same
gates. Freezing off a screen alone skips the second stage the design rests on
(`research/20/F15`), so `confirm` is the last step before a human touches a rule.
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
# The accuracy gates a cell must clear, named once. The confirmation re-runs the
# cell the screen selected and has to judge it by the gates that selected it: two
# copies of these numbers is a way for a cell to be confirmed against a bar it was
# never screened against.
ACCEPTANCE_GATES = {
    "maximum_false_positive_rate": 0.01,
    "minimum_detection_rate": 0.90,
    "maximum_inconclusive_rate": 0.10,
    "maximum_wrong_direction_rate": 0.0,
}


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
                 gates=ACCEPTANCE_GATES):
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
        selected = CALIBRATION.select_candidate(candidates, **gates)
        if selected is not None:
            return {"pairCount": pair_count, "selected": selected,
                    "searchedCellCount": len(candidates)}
    return None


def collect_quartets(workload, collector, *, quartets, maximum_attempts, emit):
    """Collect complete quartets one at a time, discarding and retrying invalid ones.

    Deliberately not `plan-calibration.collect_quartets`, which rebuilds its
    schedule through an auxiliary-metric registry a candidate workload is not in
    and cannot be -- the metric being screened here is the workload's own primary
    one. The retry rule is the same and is the part worth sharing conceptually: a
    quartet is kept only if all four blocks are valid and discarded whole
    otherwise, so no kept quartet mixes attempts and schedule balance survives.
    """
    if maximum_attempts < 1:
        raise ValueError("collection requires at least one attempt per quartet")
    kept = []
    discarded = 0
    for index in range(quartets):
        planned = [
            {"measurementRole": role, "physicalArm": "a", "quartet": index}
            for role in PLAN.QUARTET_PATTERNS[index % len(PLAN.QUARTET_PATTERNS)]
        ]
        for attempt in range(maximum_attempts):
            try:
                evidence = collector(planned)
                reasons = evidence.get("invalidationReasons") or []
            except (TimeoutError, json.JSONDecodeError, OSError) as error:
                evidence, reasons = None, [f"collector-{type(error).__name__}:{error}"]
            if not reasons:
                kept.append(evidence["rawBlocks"])
                break
            discarded += 1
            emit(f"  {workload}: quartet {index} attempt {attempt} discarded "
                 f"({len(reasons)} reasons: {reasons[:3]})")
        else:
            raise RuntimeError(
                f"{workload} quartet {index} never produced four valid blocks in "
                f"{maximum_attempts} attempts"
            )
    return kept, discarded


def describe_series(quartets):
    """Summarize the raw A/A spread, which is what makes a rule plausible or not.

    Reports a trimmed spread beside the plain one because the first screen run of
    `synchronized-frames` was decided by a single pair: 23 pairs inside +/-1.7%
    and one at -16%, which tripled the SD and pushed the cheapest clearing rule
    from 2 pairs to 12. A summary that showed only the SD would have hidden which
    of those two worlds the workload lives in, and they call for opposite
    responses -- one is a noisy stimulus, the other is a rare event whose
    frequency is the thing to measure.
    """
    values = [value for pairs in quartets for value in pairs]
    ordered = sorted(values)
    # Drop the most extreme 5% from each end, but at least one pair once the
    # series is big enough to spare it. A plain len//20 is zero below 20 pairs,
    # which is exactly the size where one bad pair does the most damage and the
    # trimmed figure would silently equal the untrimmed one.
    trim = max(1, len(ordered) // 20) if len(ordered) >= 8 else 0
    trimmed = ordered[trim:len(ordered) - trim] if trim else ordered
    return {
        "pairCount": len(values),
        "medianPercent": round(statistics.median(values), 4),
        "standardDeviationPercent": round(statistics.pstdev(values), 4),
        "trimmedStandardDeviationPercent": round(statistics.pstdev(trimmed), 4),
        "trimmedPairCount": len(trimmed),
        "minimumPercent": round(min(values), 4),
        "maximumPercent": round(max(values), 4),
        # Persisted whole so a proposal can be re-examined, or re-analyzed under
        # different gates, without spending the machine time again. The first run
        # kept only the summary and the outlier had to be recovered by hand from
        # per-block harness artifacts. Grouped by quartet because that is the unit
        # resampling draws: a flat list of pairs cannot be handed back to
        # `resample_quartets` at all, so `confirm_screen` would have no evidence to
        # re-run the selected cell against.
        "quartetsPercent": [[round(value, 4) for value in pairs] for pairs in quartets],
    }


def run_screen(*, workload, revision, quartets, trials, seed, repository_root,
               cache_root, artifacts_root, maximum_attempts=4, emit=print,
               monotonic=time.monotonic,
               sample_host_conditions=COMPARE.sample_host_conditions):
    """Collect one A/A series for a screenable workload and report its implied rule."""
    # A screen is a measurement like any other, and research/28/F5's screen 1 had to state
    # its host conditions in prose because nothing recorded them. The comparison
    # driver's preflight is reused verbatim here so a screen's conditions live in
    # its own artifact and a replicate can be compared against them: two readings,
    # no threshold, "not measured" distinct from "measured idle" (research/28/D1 pitch 4).
    host_conditions = {"atInvocation": sample_host_conditions()}
    # Calibrated workloads are screenable too, and deliberately: re-screening one
    # is how a frozen rule gets revisited when the workload's inputs change
    # (`research/20/D5` lengthens a replay to test whether its threshold can be bought
    # down). Admitting them costs no safety, because this script writes a report
    # and never a rule -- moving a threshold into `DECISION_RULES` stays a human
    # act. The guard remains only to reject names that belong to neither set.
    screenable = set(VALIDATION.WORKLOADS) | set(VALIDATION.CANDIDATE_WORKLOADS)
    if workload not in screenable:
        raise ValueError(
            f"{workload} is neither calibrated nor a candidate; "
            f"screenable workloads are {sorted(screenable)}"
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
    host_conditions["beforeFirstBlock"] = sample_host_conditions()
    try:
        kept, discarded = collect_quartets(
            workload, collectors[workload], quartets=quartets,
            maximum_attempts=maximum_attempts, emit=emit,
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
        "hostConditions": host_conditions,
        "series": describe_series(series),
        "modes": modes,
        "elapsedSeconds": round(monotonic() - started, 3),
    }
    (artifacts / "candidate-screen.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    report["artifacts"] = str(artifacts)
    return report


def gate_audit(cell, gates=ACCEPTANCE_GATES):
    """Judge one calibrated cell gate by gate, naming each one.

    `select_candidate` answers the same question with a single boolean because a
    screen only needs the cheapest cell that passes. A confirmation needs to say
    *which* gate moved when a cell stops clearing, so the operator can tell a
    marginal detection rate from an A/A false positive -- they call for opposite
    responses.
    """
    conditions = cell["conditions"]
    effects = (conditions["positive"], conditions["negative"])
    checks = {
        "falsePositiveRate": (conditions["aa"]["falsePositiveRate"]
                              <= gates["maximum_false_positive_rate"]),
        "detectionRate": all(condition["detectionRate"] >= gates["minimum_detection_rate"]
                             for condition in effects),
        "inconclusiveRate": all(
            condition["inconclusiveRate"] <= gates["maximum_inconclusive_rate"]
            for condition in effects
        ),
        "wrongDirectionRate": all(
            condition["wrongDirectionRate"] <= gates["maximum_wrong_direction_rate"]
            for condition in effects
        ),
    }
    return {"checks": checks, "accepted": all(checks.values())}


def confirm_screen(screened, *, trials=100_000, seed_base=20260828,
                   gates=ACCEPTANCE_GATES):
    """Re-run the cells a screen selected, at more trials and disjoint fresh seeds.

    A screen is not a freeze. It searches a grid of pair counts and thresholds and
    reports the cheapest cell that clears the gates, which means the winner is
    selected partly by Monte Carlo luck across everything it was compared against.
    This re-runs *only* the selected cell, changing nothing but the trial count and
    the seed, so a cell that only looked selected fails here (`research/20/F15`).
    It writes a report and never a rule: a human still moves a threshold into
    `DECISION_RULES`.
    """
    quartets = screened.get("series", {}).get("quartetsPercent")
    if not quartets:
        raise ValueError(
            "screen report carries no series.quartetsPercent; a confirmation "
            "resamples whole quartets and has nothing to run against"
        )
    modes = {}
    for index, mode in enumerate(COMPARE.MODES):
        proposal = screened["modes"].get(mode)
        if proposal is None:
            modes[mode] = None
            continue
        cell = proposal["selected"]
        rule = COMPARE.decision_rule(mode)
        for field, frozen in (("effectPercent", rule["effectPercent"]),
                              ("equivalenceBandPercent", rule["equivalenceBandPercent"])):
            if cell[field] != frozen:
                raise ValueError(
                    f"{mode} cell was screened at {field} {cell[field]} and the frozen "
                    f"rule now says {frozen}; confirming would change a parameter after "
                    "screening, so re-screen instead"
                )
        seed = seed_base + index
        if seed == screened["seed"]:
            raise ValueError(
                f"{mode} would confirm on seed {seed}, which the screen already spent; "
                "a confirmation needs seeds disjoint from the screen's"
            )
        confirmed = CALIBRATION.calibrate_mode(
            quartets,
            pair_count=cell["pairCount"],
            effect_percent=rule["effectPercent"],
            directional_threshold=cell["directionalThresholdPercent"],
            equivalence_band=rule["equivalenceBandPercent"],
            trial_count=trials,
            seed=seed,
            estimator="median",
        )
        modes[mode] = {"cell": confirmed, "audit": gate_audit(confirmed, gates)}
    confirmed_modes = [value for value in modes.values() if value is not None]
    return {
        "schemaVersion": 1,
        "workload": screened["workload"],
        "metric": screened["metric"],
        "tree": screened["tree"],
        "screenTrials": screened["trials"],
        "screenSeed": screened["seed"],
        "trials": trials,
        "seedBase": seed_base,
        "quartetCount": len(quartets),
        "gates": dict(gates),
        "modes": modes,
        # Beside the aggregate because `all([])` is True: a report that confirmed
        # nothing must not read as a report that confirmed everything.
        "confirmedModeCount": len(confirmed_modes),
        "accepted": bool(confirmed_modes) and all(
            value["audit"]["accepted"] for value in confirmed_modes
        ),
    }


def render_confirmation(report):
    """Render the confirmation an operator reads immediately before freezing."""
    lines = [
        f"candidate confirmation: {report['workload']} ({report['metric']})",
        f"  tree {report['tree']}  {report['quartetCount']} quartets, "
        f"{report['trials']} trials per condition, seed base {report['seedBase']} "
        f"(screen: {report['screenTrials']} trials, seed {report['screenSeed']})",
    ]
    for mode, confirmed in report["modes"].items():
        if confirmed is None:
            lines.append(f"  {mode}: the screen proposed no cell; nothing to confirm")
            continue
        cell = confirmed["cell"]
        failed = [name for name, passed in confirmed["audit"]["checks"].items()
                  if not passed]
        verdict = "holds" if confirmed["audit"]["accepted"] else f"FAILS {', '.join(failed)}"
        conditions = cell["conditions"]
        lines.append(
            f"  {mode}: {cell['pairCount']} pairs, "
            f"+/-{cell['directionalThresholdPercent']}% -- {verdict}  "
            f"(A/A false positives {conditions['aa']['falsePositiveRate']:.4f}, "
            f"detection {conditions['positive']['detectionRate']:.4f}/"
            f"{conditions['negative']['detectionRate']:.4f})"
        )
    lines.append(
        f"  {report['confirmedModeCount']} of {len(report['modes'])} modes confirmed; "
        f"accepted: {report['accepted']}"
    )
    lines.append("  nothing was written to DECISION_RULES; a human moves a rule.")
    return "\n".join(lines)


def render_report(report):
    """Render the report an operator reads before touching a frozen rule."""
    lines = [
        f"candidate screen: {report['workload']} ({report['metric']})",
        f"  tree {report['tree']}  kept {report['quartetsKept']} quartets, "
        f"discarded {report['quartetsDiscarded']}",
        f"  A/A spread: {report['series']['pairCount']} pairs, "
        f"median {report['series']['medianPercent']:+.2f}%, "
        f"SD {report['series']['standardDeviationPercent']:.2f}% "
        f"(trimmed {report['series']['trimmedStandardDeviationPercent']:.2f}%), "
        f"range {report['series']['minimumPercent']:+.2f}%.."
        f"{report['series']['maximumPercent']:+.2f}%",
    ]
    conditions = COMPARE.render_host_conditions(report.get("hostConditions"))
    if conditions:
        lines.extend(conditions.splitlines())
    for mode, proposal in report["modes"].items():
        if proposal is None:
            lines.append(f"  {mode}: no threshold clears the gates at any searched "
                         f"pair count -- keep reporting descriptively")
            continue
        selected = proposal["selected"]
        conditions = selected["conditions"]
        lines.append(
            f"  {mode}: {proposal['pairCount']} pairs, "
            f"+/-{selected['directionalThresholdPercent']}%  "
            f"(A/A false positives {conditions['aa']['falsePositiveRate']:.4f}, "
            f"detection {conditions['positive']['detectionRate']:.4f}/"
            f"{conditions['negative']['detectionRate']:.4f})"
        )
    lines.append("  nothing was written to DECISION_RULES; a human moves a rule.")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    screen = subparsers.add_parser("screen")
    screen.add_argument("--workload", required=True)
    screen.add_argument("--revision", required=True)
    screen.add_argument("--quartets", type=int, default=12)
    screen.add_argument("--trials", type=int, default=50_000)
    screen.add_argument("--seed", type=int, default=20260730)
    screen.add_argument("--repository-root", type=pathlib.Path, default=ROOT)
    screen.add_argument("--cache-root", type=pathlib.Path,
                        default=ROOT / ".build" / "terminal-benchmark-arms")
    screen.add_argument("--artifacts-root", type=pathlib.Path,
                        default=ROOT / ".build" / "terminal-benchmark-candidate-screens")

    confirm = subparsers.add_parser("confirm")
    confirm.add_argument("--screen", required=True, type=pathlib.Path,
                         help="a candidate-screen.json written by the screen command")
    confirm.add_argument("--trials", type=int, default=100_000)
    confirm.add_argument("--seed-base", type=int, default=20260828)
    confirm.add_argument("--output", type=pathlib.Path, default=None)

    arguments = parser.parse_args(argv)
    if arguments.command == "screen":
        report = run_screen(
            workload=arguments.workload, revision=arguments.revision,
            quartets=arguments.quartets, trials=arguments.trials, seed=arguments.seed,
            repository_root=arguments.repository_root, cache_root=arguments.cache_root,
            artifacts_root=arguments.artifacts_root,
        )
        print(render_report(report))
        print(f"  evidence: {report['artifacts']}")
        return 0

    screened = json.loads(arguments.screen.read_text(encoding="utf-8"))
    report = confirm_screen(screened, trials=arguments.trials,
                            seed_base=arguments.seed_base)
    output = arguments.output or arguments.screen.parent / "candidate-confirm.json"
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(render_confirmation(report))
    print(f"  evidence: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
