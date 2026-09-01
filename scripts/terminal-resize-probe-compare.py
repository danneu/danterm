#!/usr/bin/env python3
"""Own the paired resize-probe comparison: measure two arms, freeze a rule, decide once.

`TerminalResizeProbe` is a one-arm probe and stays one. This script is the second
arm's owner: it runs a baseline binary and a candidate binary interleaved in one
session, reduces the pairs to symmetric percentage differences, and applies a rule
whose pair count and thresholds were frozen before any decision run existed. It is
the whole of the comparison -- nothing here is read out of a log by eye, and no
number it prints was chosen after the measurement it judges.

Four subcommands, in the order they are used:

  measure   run one interleaved series and write its artifact
  select    pick a pair count and thresholds from an A/A series
  confirm   re-test the selected rule against a disjoint A/A series
  decide    apply the confirmed rule to a baseline-vs-candidate series

The two calibration stages are separate on purpose. A threshold picked from one
A/A series is selected, not verified: a bound set at the observed extreme of n
replications is exceeded by a fresh run with probability about 1/(n+1), so the
sample that chose it cannot also validate it (`agent-docs/measurement-discipline.md`,
"a screen is not a freeze"). `confirm` re-runs the frozen rule against a series it
has never seen and refuses a rule whose false-positive rate there exceeds a limit
this file declares in advance.

What this file guards, and why each guard is here rather than in a reader's head:

  * Both arms are measured in one session, alternating which arm runs first, so an
    arm never owns a position in time. A comparison of two logs from two sessions is
    not expressible here at all.
  * Every series carries a control: a baseline-against-baseline pair beside each
    decision pair. The candidate cannot reach it by construction, so a control that
    moves says the machine moved and voids the run.
  * Both arms report retained rows and retained cells, and a mismatch fails the
    comparison. An arm that reflows less is quicker for a reason that is not a
    speedup, and a row count alone cannot see a row that lost cells.
  * A missing field is refused, never read as zero. Every field this script reads is
    fetched through `field`, which raises on absence.

What does not belong here: injected-effect detection. `decide` answers one
comparative question, and a rule too weak to see the real effect only refuses the
landing -- the safe direction. Detection power is the calibration corpus's problem
(`scripts/terminal-benchmark-candidate-screen.py`), and that machinery is for
workloads on the benchmark ladder, which this probe deliberately is not.
"""
import argparse
import datetime
import gzip
import hashlib
import importlib.util
import json
import pathlib
import platform
import random
import statistics
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]


def _load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The symmetric paired difference is the calibration corpus's, not a second
# implementation of it: reversing the arm labels must only change the sign, and that
# property is already owned and tested there.
CALIBRATION = _load(
    "terminal_benchmark_calibration", "scripts/terminal-benchmark-calibration.py"
)

# --- Frozen constants. Declared before any decision run, and never edited by one. ---

# The recipe under comparison. `wide` is the full-width payload: reflow cost is
# dominated by its per-cell term, so this is the regime a per-cell change moves.
RECIPE = "wide"
# Samples per probe run. The probe's own `wide` default is 20, which prices a p95 off
# a single order statistic; each sample costs about two milliseconds, so a tighter
# tail is nearly free here.
SAMPLES_PER_RUN = 200
# The four deciding statistics: a median and a p95 for each resize direction, named by
# whether the direction narrows and by the report field it reads. Per direction because
# the probe alternates narrow and wide and the two cost very differently, so a quantile
# of the combined samples sits inside one group and moves between the two for reasons
# that are not cost. Both statistics per direction, because a median-only gate accepts a
# change that moved the tail the wrong way.
ESTIMATORS = {
    "narrowing-median": (True, "medianNanoseconds"),
    "narrowing-p95": (True, "p95Nanoseconds"),
    "widening-median": (False, "medianNanoseconds"),
    "widening-p95": (False, "p95Nanoseconds"),
}
# Narrowing is the direction that reflows content; widening mostly re-pads it. So a
# candidate has to improve the reflowing direction to pass, and the other direction is
# held to "not worse" rather than to "better" -- demanding an improvement where there is
# little work to remove would refuse a real win in the direction that does the work.
IMPROVEMENT_ESTIMATORS = ("narrowing-median", "narrowing-p95")
NO_REGRESSION_ESTIMATORS = ("widening-median", "widening-p95")
# The pair counts a rule may use, and the thresholds it may hold. Selection walks the
# pair counts in this order and takes the first one that reaches the declared
# sensitivity, giving each estimator the smallest threshold in the grid that holds its
# own A/A false-positive rate at the limit. Per estimator rather than one number for all
# four: the tail statistics are far noisier than the medians, so a single threshold
# would price every estimator at the noisiest one's.
PAIR_COUNT_GRID = (4, 6, 8, 12, 16, 24)
THRESHOLD_GRID_PERCENT = (0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0, 6.0)
# How sensitive the deciding half of the rule has to be for the rule to be usable at
# all. A pair count that cannot hold both improvement estimators at or under this is too
# few pairs, and selection moves on to the next one. Declared from what the change under
# test is expected to remove -- a per-cell allocation in the reflow walk -- not from what
# any measurement of a candidate showed, because no candidate exists when this is read.
TARGET_THRESHOLD_PERCENT = 2.0
# A cell is selectable when its A/A false-positive rate is at or under this.
SELECTION_FALSE_POSITIVE_LIMIT = 0.05
# And confirmable when the frozen cell's rate on a disjoint A/A series is at or under
# this. Looser than selection on purpose: selection minimizes over a grid, so its own
# rate is optimistically biased, and a confirmation limit equal to it would fail cells
# that are fine. It is declared here, before the confirming series is measured.
CONFIRMATION_FALSE_POSITIVE_LIMIT = 0.10
# Replications per cell, and the seeds. Fixed so a rule is reproducible from its
# series artifact alone.
REPLICATION_COUNT = 4000
SELECTION_SEED = 20260831
CONFIRMATION_SEED = 20260901

SERIES_KIND = "resize-probe-series"
RULE_KIND = "resize-probe-rule"


class ComparisonError(Exception):
    """A refusal: something this script must not paper over with a default value."""


def field(mapping, name, where):
    """Read a required field, refusing absence instead of substituting a zero."""
    if not isinstance(mapping, dict) or name not in mapping:
        raise ComparisonError(f"{where}: missing required field `{name}`")
    return mapping[name]


def digest_of(path):
    """Identify a binary by content, so an A/A series can prove both arms are one build."""
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def run_probe(binary, recipe=RECIPE, samples=SAMPLES_PER_RUN):
    """Run one probe process and return its report."""
    completed = subprocess.run(
        [str(binary), "--recipe", recipe, "--samples", str(samples)],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise ComparisonError(
            f"probe {binary} exited {completed.returncode}: {completed.stderr.strip()}"
        )
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise ComparisonError(f"probe {binary} wrote no readable report: {error}")


def measure_series(baseline, candidate, pair_count, label, recipe=RECIPE,
                   samples=SAMPLES_PER_RUN, probe=run_probe):
    """Collect one interleaved series: a decision pair and a control pair per index.

    The control pair is the baseline binary against itself. It is measured in the same
    session, between the same two decision runs, and no candidate change can reach it --
    which is what makes it able to say "the machine moved" rather than "the code did".
    """
    if pair_count < 1:
        raise ComparisonError("a series needs at least one pair")
    pairs = []
    for index in range(pair_count):
        # Alternating which arm goes first balances position across the series, so a
        # machine that drifts within a pair cannot charge the drift to one arm.
        baseline_first = index % 2 == 0
        if baseline_first:
            base_report = probe(baseline, recipe, samples)
            candidate_report = probe(candidate, recipe, samples)
            control_a = probe(baseline, recipe, samples)
            control_b = probe(baseline, recipe, samples)
        else:
            candidate_report = probe(candidate, recipe, samples)
            base_report = probe(baseline, recipe, samples)
            control_b = probe(baseline, recipe, samples)
            control_a = probe(baseline, recipe, samples)
        pairs.append({
            "index": index,
            "order": "baseline-first" if baseline_first else "candidate-first",
            "baseline": base_report,
            "candidate": candidate_report,
            "controlBaseline": control_a,
            "controlRepeat": control_b,
        })
    series = {
        "kind": SERIES_KIND,
        "label": label,
        "recipe": recipe,
        "samplesPerRun": samples,
        "pairCount": pair_count,
        "baselineDigest": digest_of(baseline),
        "candidateDigest": digest_of(candidate),
        "baselineBinary": str(baseline),
        "candidateBinary": str(candidate),
        "machine": platform.platform(),
        "measuredAt": datetime.datetime.now().astimezone().isoformat(),
        "pairs": pairs,
    }
    series["seriesId"] = series_id(series)
    return series


def series_id(series):
    """Name a series by everything in it, so `confirm` can prove disjointness.

    Its measurements and the session they came from: the label, the time, and the
    binaries, as well as the pairs. Two runs that happen to agree to the nanosecond are
    still two measurements, and the id has to be able to say so.
    """
    payload = json.dumps(
        {key: value for key, value in series.items() if key != "seriesId"},
        sort_keys=True,
    ).encode()
    return hashlib.sha256(payload).hexdigest()[:16]


def check_series(series, where):
    """Refuse a series that is not this script's, or whose pairs are unreadable."""
    if field(series, "kind", where) != SERIES_KIND:
        raise ComparisonError(f"{where}: not a {SERIES_KIND} artifact")
    pairs = field(series, "pairs", where)
    if len(pairs) != field(series, "pairCount", where):
        raise ComparisonError(f"{where}: pairCount disagrees with the pairs it carries")
    if not pairs:
        raise ComparisonError(f"{where}: a series with no pairs decides nothing")
    return pairs


def check_retained_content(series, where):
    """Fail the comparison when the two arms did not reflow the same history.

    Rows and cells both, and both from every pair. An arm that retains fewer cells is
    quicker for a reason that is not an optimization, and the row count cannot see it:
    a row that lost cells is still one row.
    """
    for pair in check_series(series, where):
        index = field(pair, "index", where)
        arms = {name: field(pair, name, where) for name in
                ("baseline", "candidate", "controlBaseline", "controlRepeat")}
        for counted in ("retainedRowCountAtStart", "retainedCellCountAtStart"):
            values = {
                name: field(report, counted, f"{where} pair {index} {name}")
                for name, report in arms.items()
            }
            if len(set(values.values())) != 1:
                raise ComparisonError(
                    f"{where}: pair {index} arms disagree on {counted}: {values}"
                )


def direction_statistic(report, is_narrowing, statistic, where):
    """Read one direction's statistic, refusing a report that did not time both."""
    directions = field(report, "directions", where)
    if len(directions) != 2:
        raise ComparisonError(
            f"{where}: a comparison needs both resize directions, and this report "
            f"carries {len(directions)}"
        )
    for direction in directions:
        if field(direction, "isNarrowing", where) == is_narrowing:
            return field(field(direction, "distribution", where), statistic, where)
    raise ComparisonError(
        f"{where}: the report times no "
        f"{'narrowing' if is_narrowing else 'widening'} resize"
    )


def paired_differences(series, where, arms=("baseline", "candidate")):
    """Reduce a series to one symmetric percentage difference per pair, per estimator."""
    differences = {name: [] for name in ESTIMATORS}
    for pair in check_series(series, where):
        index = field(pair, "index", where)
        first = field(pair, arms[0], where)
        second = field(pair, arms[1], where)
        for name, (is_narrowing, statistic) in ESTIMATORS.items():
            left = direction_statistic(
                first, is_narrowing, statistic, f"{where} pair {index} {arms[0]}"
            )
            right = direction_statistic(
                second, is_narrowing, statistic, f"{where} pair {index} {arms[1]}"
            )
            differences[name].append(CALIBRATION.symmetric_difference(left, right))
    return differences


def false_positive_rate(differences, pair_count, threshold_percent, seed):
    """Estimate how often this rule calls a difference on a series that holds none.

    Two-sided: the gate itself accepts only on improvement, so counting the wrong
    direction too makes the rate an upper bound on the rate that matters.
    """
    generator = random.Random(seed)
    hits = 0
    for _ in range(REPLICATION_COUNT):
        drawn = [generator.choice(differences) for _ in range(pair_count)]
        if abs(statistics.median(drawn)) >= threshold_percent:
            hits += 1
    return hits / REPLICATION_COUNT


def select_rule(series_list, labels):
    """Freeze the cheapest rule the A/A noise supports at the declared sensitivity.

    The first pair count in the grid at which every estimator can hold its own
    false-positive rate at the selection limit, and at which the two deciding
    estimators reach `TARGET_THRESHOLD_PERCENT`. Each estimator then keeps the smallest
    threshold in the grid that holds its rate, so the noisy tail statistics do not
    price the medians.
    """
    for index, series in enumerate(series_list):
        where = labels[index]
        if field(series, "baselineDigest", where) != field(
            series, "candidateDigest", where
        ):
            raise ComparisonError(
                f"{where}: selection needs an A/A series, and its two arms are "
                "different binaries"
            )
        check_retained_content(series, where)
    pooled = {name: [] for name in ESTIMATORS}
    for index, series in enumerate(series_list):
        for name, values in paired_differences(series, labels[index]).items():
            pooled[name].extend(values)

    for pair_count in PAIR_COUNT_GRID:
        thresholds = {}
        rates = {}
        for name, values in pooled.items():
            for threshold in THRESHOLD_GRID_PERCENT:
                rate = false_positive_rate(
                    values, pair_count, threshold, SELECTION_SEED + pair_count
                )
                if rate <= SELECTION_FALSE_POSITIVE_LIMIT:
                    thresholds[name] = threshold
                    rates[name] = rate
                    break
        if len(thresholds) != len(pooled):
            continue
        if any(
            thresholds[name] > TARGET_THRESHOLD_PERCENT
            for name in IMPROVEMENT_ESTIMATORS
        ):
            continue
        return {
            "kind": RULE_KIND,
            "stage": "selected",
            "recipe": RECIPE,
            "samplesPerRun": SAMPLES_PER_RUN,
            "pairCount": pair_count,
            "thresholdPercent": thresholds,
            "targetThresholdPercent": TARGET_THRESHOLD_PERCENT,
            "selectionFalsePositiveRate": rates,
            "selectionFalsePositiveLimit": SELECTION_FALSE_POSITIVE_LIMIT,
            "confirmationFalsePositiveLimit": CONFIRMATION_FALSE_POSITIVE_LIMIT,
            "replicationCount": REPLICATION_COUNT,
            "selectionSeriesIds": [
                field(series, "seriesId", labels[index])
                for index, series in enumerate(series_list)
            ],
        }
    raise ComparisonError(
        "no pair count in the grid reaches "
        f"{TARGET_THRESHOLD_PERCENT}% on both deciding statistics while holding the "
        f"A/A false-positive rate at or under {SELECTION_FALSE_POSITIVE_LIMIT}; this "
        "series is too noisy to decide on"
    )


def confirm_rule(rule, series, where):
    """Re-test the frozen cell on a disjoint A/A series, changing nothing about it."""
    if field(rule, "kind", "rule") != RULE_KIND:
        raise ComparisonError("rule: not a resize-probe rule artifact")
    if field(rule, "stage", "rule") != "selected":
        raise ComparisonError(
            f"rule: confirmation needs a selected rule, not a {rule['stage']} one"
        )
    if field(series, "baselineDigest", where) != field(series, "candidateDigest", where):
        raise ComparisonError(f"{where}: confirmation needs an A/A series")
    if field(series, "seriesId", where) in field(rule, "selectionSeriesIds", "rule"):
        raise ComparisonError(
            f"{where}: this series selected the rule; confirmation needs a disjoint one"
        )
    check_retained_content(series, where)
    pair_count = field(rule, "pairCount", "rule")
    thresholds = field(rule, "thresholdPercent", "rule")
    differences = paired_differences(series, where)
    rates = {
        name: false_positive_rate(
            values, pair_count, field(thresholds, name, "rule"),
            CONFIRMATION_SEED + pair_count
        )
        for name, values in differences.items()
    }
    limit = field(rule, "confirmationFalsePositiveLimit", "rule")
    failed = {name: rate for name, rate in rates.items() if rate > limit}
    if failed:
        raise ComparisonError(
            f"{where}: the frozen rule's false-positive rate exceeds {limit} on the "
            f"confirming series: {failed}"
        )
    confirmed = dict(rule)
    confirmed["stage"] = "confirmed"
    confirmed["confirmationFalsePositiveRate"] = rates
    confirmed["confirmationSeriesId"] = field(series, "seriesId", where)
    return confirmed


def decide(rule, series, where):
    """Apply a confirmed rule to one decision series, once, changing nothing in it."""
    if field(rule, "kind", "rule") != RULE_KIND:
        raise ComparisonError("rule: not a resize-probe rule artifact")
    if field(rule, "stage", "rule") != "confirmed":
        raise ComparisonError(
            f"rule: a decision needs a confirmed rule, not a {rule['stage']} one"
        )
    if field(series, "baselineDigest", where) == field(series, "candidateDigest", where):
        raise ComparisonError(
            f"{where}: both arms are the same binary, so this series decides nothing"
        )
    if field(series, "recipe", where) != field(rule, "recipe", "rule"):
        raise ComparisonError(f"{where}: series recipe is not the rule's recipe")
    if field(series, "samplesPerRun", where) != field(rule, "samplesPerRun", "rule"):
        raise ComparisonError(f"{where}: series sample count is not the rule's")
    pair_count = field(rule, "pairCount", "rule")
    if field(series, "pairCount", where) != pair_count:
        raise ComparisonError(
            f"{where}: the frozen rule decides {pair_count} pairs and this series "
            f"carries {series['pairCount']}"
        )
    pairs = check_series(series, where)
    check_retained_content(series, where)

    thresholds = field(rule, "thresholdPercent", "rule")
    effects = paired_differences(series, where)
    controls = paired_differences(
        series, where, arms=("controlBaseline", "controlRepeat")
    )
    estimates = {name: statistics.median(values) for name, values in effects.items()}
    control_estimates = {
        name: statistics.median(values) for name, values in controls.items()
    }
    moved_controls = {
        name: value for name, value in control_estimates.items()
        if abs(value) >= field(thresholds, name, "rule")
    }
    result = {
        "kind": "resize-probe-decision",
        "seriesId": field(series, "seriesId", where),
        "recipe": field(series, "recipe", where),
        "pairCount": pair_count,
        "thresholdPercent": thresholds,
        "estimatePercent": estimates,
        "controlEstimatePercent": control_estimates,
        # One pair's baseline speaks for the series: `check_retained_content` has just
        # proved every arm of every pair carries these same two numbers.
        "retainedRowCountAtStart": field(
            field(pairs[0], "baseline", where), "retainedRowCountAtStart", where
        ),
        "retainedCellCountAtStart": field(
            field(pairs[0], "baseline", where), "retainedCellCountAtStart", where
        ),
    }
    if moved_controls:
        result["verdict"] = "void"
        result["reason"] = (
            "the control series moved, so this session cannot attribute a difference "
            f"to the candidate: {moved_controls}"
        )
        return result
    improved = {
        name: estimates[name] <= -field(thresholds, name, "rule")
        for name in IMPROVEMENT_ESTIMATORS
    }
    regressed = {
        name: estimates[name] >= field(thresholds, name, "rule")
        for name in NO_REGRESSION_ESTIMATORS
    }
    result["improvedBy"] = improved
    result["regressedBy"] = regressed
    result["verdict"] = (
        "improved" if all(improved.values()) and not any(regressed.values())
        else "not-improved"
    )
    return result


def read_json(path, where):
    """Read an artifact, gzipped or not, so a committed series keeps its raw samples.

    A series holds every timed sample of every run, which is what lets a later reader
    re-reduce it under a different statistic without re-measuring. That is about a
    megabyte per series in text and a fifth of it compressed, so `.gz` is the shape a
    series is kept in and both shapes are read here.
    """
    try:
        data = pathlib.Path(path).read_bytes()
        if str(path).endswith(".gz"):
            data = gzip.decompress(data)
        return json.loads(data)
    except (OSError, ValueError) as error:
        raise ComparisonError(f"{where}: cannot read {path}: {error}")


def write_json(path, payload):
    encoded = (json.dumps(payload, indent=1, sort_keys=True) + "\n").encode()
    if str(path).endswith(".gz"):
        encoded = gzip.compress(encoded, 9)
    pathlib.Path(path).write_bytes(encoded)


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    subcommands = parser.add_subparsers(dest="command", required=True)

    measure = subcommands.add_parser("measure", help="run one interleaved series")
    measure.add_argument("--baseline", required=True)
    measure.add_argument("--candidate", required=True)
    measure.add_argument("--pairs", type=int, required=True)
    measure.add_argument("--label", required=True)
    measure.add_argument("--out", required=True)

    select = subcommands.add_parser("select", help="freeze a rule from an A/A series")
    select.add_argument("--series", action="append", required=True)
    select.add_argument("--out", required=True)

    confirm = subcommands.add_parser("confirm", help="re-test a rule on a disjoint A/A series")
    confirm.add_argument("--rule", required=True)
    confirm.add_argument("--series", required=True)
    confirm.add_argument("--out", required=True)

    decision = subcommands.add_parser("decide", help="apply a confirmed rule once")
    decision.add_argument("--rule", required=True)
    decision.add_argument("--series", required=True)
    decision.add_argument("--out")
    return parser


def main(argv=None):
    arguments = build_parser().parse_args(argv)
    try:
        if arguments.command == "measure":
            series = measure_series(
                arguments.baseline, arguments.candidate, arguments.pairs,
                arguments.label
            )
            write_json(arguments.out, series)
            print(f"{series['label']}: {series['pairCount']} pairs -> {arguments.out}")
            return 0
        if arguments.command == "select":
            series_list = [read_json(path, path) for path in arguments.series]
            rule = select_rule(series_list, list(arguments.series))
            write_json(arguments.out, rule)
            print(json.dumps(rule, indent=1, sort_keys=True))
            return 0
        if arguments.command == "confirm":
            rule = read_json(arguments.rule, "rule")
            series = read_json(arguments.series, arguments.series)
            confirmed = confirm_rule(rule, series, arguments.series)
            write_json(arguments.out, confirmed)
            print(json.dumps(confirmed, indent=1, sort_keys=True))
            return 0
        result = decide(
            read_json(arguments.rule, "rule"),
            read_json(arguments.series, arguments.series),
            arguments.series,
        )
        if arguments.out:
            write_json(arguments.out, result)
        print(json.dumps(result, indent=1, sort_keys=True))
        return 0 if result["verdict"] == "improved" else 1
    except ComparisonError as error:
        print(f"resize-probe comparison refused: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
