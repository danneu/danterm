#!/usr/bin/env python3
"""Compare two draw-path revisions headlessly by interleaving them in one process.

`just benchmark-headless-draw` runs this. It builds each arm as a dynamic library from its
own TerminalCore checkout, loads both into this process, and alternates their batches ABBA so
that machine drift -- which moves every measurement in a process together -- cancels in the
paired difference.

Why it exists: the GUI paired benchmark cannot resolve a 3% change on `incremental-mixed`
any more. macOS lowers the app's CPU clock during a block because the optimized main thread
is ~96% idle, and no collection-side fix removed it. Batching draws to a 400ms floor keeps
this benchmark's thread ~100% occupied, so the governor never demotes it, and interleaving
two arms cancels what drift remains. Measured paired spread is ~0.7% against the GUI
benchmark's 3.98%. Background, evidence and limits: F14 and F21-F23 in
docs/research/8-benchmark-variance-regression.md.

Scope, deliberately narrow. This measures the cost of DRAWING a row-indexed plan, including
selection of the restricted rows inside `drawRenderFrame`. It
does not see damage *generation* -- which rows `setNeedsDisplay` and AppKit's dirty-rect
coalescing mark. That stays with the GUI benchmark.

One decision rule is frozen, for `fallback-shaped` only (research/40/D1). Every report
carries a `decision` block that either states that rule and reads the run against it, or
says the run decides nothing and why -- so a number from this script cannot be quoted as a
verdict without the conditions that make it one. A workload with no frozen rule still gets
the block, saying it has none; a threshold passed on the command line stays caller-supplied
and is reported apart from the frozen reading.
"""
import argparse
import ctypes
import importlib.util
import json
import pathlib
import shutil
import statistics
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent
# The arm is a target of lib/TerminalCore so the gate compiles it; this script is its
# only runner. Copied, not depended on: each arm must build against its own checkout.
ARM_SOURCE = ROOT / "lib" / "TerminalCore" / "Sources" / "HeadlessDrawArm" / "Arm.swift"
DEFAULT_CORE = ROOT / "lib" / "TerminalCore"
ARTIFACTS = ROOT / ".build" / "terminal-headless-draw"

# Content workloads the arm can fill its grid with. Must match DrawBenchmarkWorkload's raw
# values in TerminalDrawBenchmarkSupport, which the arm's generators are copied from -- in
# order, because the index is what `arm_prepare` receives.
WORKLOADS = ("btop-shaped", "text-shaped", "fallback-shaped", "symbols-shaped")

# Both arms must compile under different Swift module names; see validate_module_names.
BASELINE_MODULE = "DrawArmBaseline"
CANDIDATE_MODULE = "DrawArmCandidate"

# Matches TerminalDrawBenchmarkSupport's floor: a batch this long keeps the thread ~100%
# occupied, which is what stops the platform governor from demoting it mid-measurement.
TARGET_BATCH_NANOSECONDS = 400_000_000

# Decision rules a human froze, one entry per workload that has one. A workload absent
# here has no rule, and its report says so rather than reading as an unlabelled verdict.
# This table is transcribed from the decision, not derived: changing a number here changes
# the rule, so it moves only when a research decision moves.
FROZEN_RULES = {
    "fallback-shaped": {
        "source": "research/40/D1",
        "quantity": "realEffectPercent",
        "mode": "both-directions",
        "roundsPerDirection": 8,
        "directionalThresholdPercent": 1.00,
        "orderBiasGuardPercent": 2.50,
        "statement": (
            "fallback-shaped decides on realEffectPercent from one --both-directions "
            "invocation at 8 rounds per direction, at +/-1.00%, on an idle host. The "
            "verdict is valid only when that invocation's orderBiasPercent is below "
            "2.5%; a run above the guard is invalid and is re-run, never read. A "
            "single-direction run of this workload decides nothing at any magnitude. "
            "The threshold is a false-positive floor argued from ten A/A invocations, "
            "not a screened detection cell, so a reading under about 3% is descriptive."
        ),
    },
}

CALIBRATION = importlib.util.spec_from_file_location(
    "terminal_benchmark_calibration",
    ROOT / "scripts" / "terminal-benchmark-calibration.py",
)
CAL = importlib.util.module_from_spec(CALIBRATION)
CALIBRATION.loader.exec_module(CAL)


def validate_module_names(baseline_module, candidate_module):
    """Refuse two arms that would collide in the ObjC runtime's global class table.

    Swift classes register with the ObjC runtime, which dedups by name across images even
    under RTLD_LOCAL. Two arms sharing a module name can both execute one arm's code while
    still reporting plausible-looking numbers, so this is checked rather than trusted.
    """
    if baseline_module == candidate_module:
        raise ValueError(
            "both arms would compile under the module name "
            f"{baseline_module!r}; the ObjC runtime dedups classes by name across images, "
            "so the arms must use different module names"
        )


def arm_manifest(module_name, core_path):
    """Bind one arm's module name to its own TerminalCore checkout."""
    core_path = pathlib.Path(core_path)
    if core_path.name != "TerminalCore":
        raise ValueError(
            f"core checkout {str(core_path)!r} must keep the basename 'TerminalCore': "
            "SwiftPM takes a path dependency's identity from the directory name, so a "
            "differently named copy cannot resolve .product(package: \"TerminalCore\")"
        )
    return f'''// swift-tools-version: 6.2
// Generated by scripts/terminal-headless-draw-compare.py -- edits are overwritten.
import PackageDescription

let package = Package(
    name: "{module_name}",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "{module_name}", type: .dynamic, targets: ["{module_name}"]),
    ],
    dependencies: [
        .package(path: "{core_path}"),
    ],
    targets: [
        .target(
            name: "{module_name}",
            dependencies: [
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalRenderPlanning", package: "TerminalCore"),
                .product(name: "TerminalRenderExecution", package: "TerminalCore"),
            ],
            path: "Sources/{module_name}",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
'''


def paired_quartets(rounds):
    """Turn ABBA rounds into the two-pair quartets the frozen calibration machinery reads.

    Each round contributes `A1 vs B1` and `B2 vs A2`, pairing every batch with its adjacent
    neighbour so a monotonic drift across the round cancels to first order instead of loading
    onto whichever arm ran first.
    """
    quartets = []
    for index, round_result in enumerate(rounds):
        a_batches = round_result["a"]
        b_batches = round_result["b"]
        if len(a_batches) != 2 or len(b_batches) != 2:
            raise ValueError(f"round {index} must hold two batches per arm")
        if any(value <= 0 for value in list(a_batches) + list(b_batches)):
            raise ValueError(f"round {index} holds a non-positive batch duration")
        quartets.append([
            CAL.symmetric_difference(a_batches[0], b_batches[0]),
            CAL.symmetric_difference(a_batches[1], b_batches[1]),
        ])
    return quartets


def paired_absolute_differences(rounds, batch_count):
    """Pair the same batches as `paired_quartets`, in nanoseconds per draw.

    A percentage cancels the machine drift but hides the size of what it measures: a 2%
    saving on a workload of 4000 icon cells and a 2% saving on 40 are the same number and
    not the same finding. This keeps the absolute side, normalized by the batch count so a
    value is one draw rather than one batch. Positive means the candidate arm is slower,
    which is the sign convention `symmetric_difference` already uses.
    """
    if batch_count <= 0:
        raise ValueError("a per-draw difference needs a positive batch count")
    differences = []
    for index, round_result in enumerate(rounds):
        a_batches = round_result["a"]
        b_batches = round_result["b"]
        if len(a_batches) != 2 or len(b_batches) != 2:
            raise ValueError(f"round {index} must hold two batches per arm")
        for a_batch, b_batch in zip(a_batches, b_batches):
            if a_batch <= 0 or b_batch <= 0:
                raise ValueError(f"round {index} holds a non-positive batch duration")
            differences.append((b_batch - a_batch) / batch_count)
    return differences


def absolute_antisymmetric_estimate(runs):
    """Split the absolute per-draw difference the same way the percentage is split.

    Read from the direction runs rather than passed in beside them, so the absolute
    estimate and the percentages can never describe different measurements. The slot bias
    the percentage cancels sits on the nanoseconds too, so a one-direction difference is
    not the cost of anything; only the antisymmetric part is, and the bias is reported
    beside it rather than dropped.

    `iconCellCount` is the arm's own count of cells that reach the packaged-symbols path.
    It divides the per-draw effect into a per-icon-cell one so the reader takes that number
    off the instrument instead of reconstructing it from a workload description.
    """
    directions = {"forward": [], "reverse": []}
    counts = set()
    for run in runs:
        absolute = run["report"]["absolute"]
        directions[run["direction"]].extend(absolute["pairedValuesNanosecondsPerDraw"])
        counts.add(absolute["iconCellCount"])
    if not directions["forward"] or not directions["reverse"]:
        raise ValueError("an antisymmetric estimate requires both comparison directions")
    if len(counts) != 1:
        raise ValueError(
            f"the direction runs disagree on how many icon cells they drew ({sorted(counts)}); "
            "they must measure the same workload and geometry"
        )
    icon_cells = counts.pop()
    forward = statistics.fmean(directions["forward"])
    reverse = statistics.fmean(directions["reverse"])
    real_effect = (forward - reverse) / 2
    return {
        "realEffectNanosecondsPerDraw": real_effect,
        "orderBiasNanosecondsPerDraw": (forward + reverse) / 2,
        "forwardMeanNanosecondsPerDraw": forward,
        "reverseMeanNanosecondsPerDraw": reverse,
        "iconCellCount": icon_cells,
        "realEffectNanosecondsPerIconCell": (
            real_effect / icon_cells if icon_cells > 0 else None
        ),
    }


def summarize(quartets):
    """Report the paired spread that decides whether a difference is readable at all."""
    values = [value for quartet in quartets for value in quartet]
    if not values:
        raise ValueError("a summary requires at least one paired difference")
    return {
        "quartetCount": len(quartets),
        "pairCount": len(values),
        "pairedMeanPercent": statistics.fmean(values),
        "pairedMedianPercent": statistics.median(values),
        "pairedStandardDeviationPercent": (
            statistics.pstdev(values) if len(values) > 1 else 0.0
        ),
        "pairedValuesPercent": values,
    }


def antisymmetric_estimate(forward_percents, reverse_percents):
    """Split a two-direction measurement into the part that reverses and the part that does not.

    A real difference between two revisions flips sign when the arms swap slots; anything
    that survives the swap -- load order, slot asymmetry -- does not. Reporting the two
    separately is what stops an order bias being published as a performance claim. The first
    positive control read -1.797% one way and +0.101% the other, so this is not hypothetical.
    """
    if not forward_percents or not reverse_percents:
        raise ValueError("an antisymmetric estimate requires both comparison directions")
    forward = statistics.fmean(forward_percents)
    reverse = statistics.fmean(reverse_percents)
    return {
        "realEffectPercent": (forward - reverse) / 2,
        "orderBiasPercent": (forward + reverse) / 2,
        "forwardMeanPercent": forward,
        "reverseMeanPercent": reverse,
    }


def frozen_decision(workload, rounds, mode, estimate=None):
    """Read one run against its workload's frozen rule, and print the rule beside the reading.

    Every report gets this block, including the runs that decide nothing. That is the
    point: an absent decision reads as no opinion, and a number with no opinion beside it
    is quoted as a verdict by whoever needs one. So the block always names the rule it
    used, or says no rule exists, and a run that missed the frozen cell -- wrong mode,
    wrong round count, an order bias above the guard -- reads `invalid` rather than
    carrying a verdict it did not earn.
    """
    rule = FROZEN_RULES.get(workload)
    if rule is None:
        return {
            "workload": workload,
            "rule": None,
            "verdict": "descriptive",
            "reason": (
                f"no decision rule is frozen for '{workload}'; this report is statistics "
                "only, and any threshold read against it is the caller's"
            ),
        }
    decision = {"workload": workload, "rule": rule, "measuredMode": mode}
    if mode != rule["mode"]:
        decision["verdict"] = "descriptive"
        decision["reason"] = (
            f"a {mode} run of '{workload}' decides nothing at any magnitude; the frozen "
            f"rule reads {rule['quantity']} from one {rule['mode']} invocation"
        )
        return decision
    decision["measured"] = {
        "realEffectPercent": estimate["realEffectPercent"],
        "orderBiasPercent": estimate["orderBiasPercent"],
        "roundsPerDirection": rounds,
    }
    threshold = rule["directionalThresholdPercent"]
    guard = rule["orderBiasGuardPercent"]
    effect = estimate["realEffectPercent"]
    bias = estimate["orderBiasPercent"]
    if rounds != rule["roundsPerDirection"]:
        decision["verdict"] = "invalid"
        decision["reason"] = (
            f"measured at {rounds} rounds per direction; the frozen cell is "
            f"{rule['roundsPerDirection']}, and its threshold was argued at that count "
            "only. Re-run at the frozen parameters."
        )
    elif abs(bias) >= guard:
        decision["verdict"] = "invalid"
        decision["reason"] = (
            f"orderBiasPercent {bias:+.3f}% is not below the {guard:.2f}% guard, so "
            "neither direction is trustworthy and realEffectPercent is not a verdict "
            "however large it is. Re-run; never read this run."
        )
    elif effect <= -threshold:
        decision["verdict"] = "faster"
    elif effect >= threshold:
        decision["verdict"] = "slower"
    else:
        decision["verdict"] = "inconclusive"
        decision["reason"] = (
            f"realEffectPercent {effect:+.3f}% is inside the +/-{threshold:.2f}% "
            "threshold. The rule bounds false positives and does not bound detection, "
            "so this is not a claim that the two revisions are equivalent."
        )
    return decision


def build_arm(module_name, core_path, workspace):
    """Generate and compile one arm, returning the built dynamic library path."""
    package_root = workspace / module_name
    source_directory = package_root / "Sources" / module_name
    source_directory.mkdir(parents=True, exist_ok=True)
    (package_root / "Package.swift").write_text(
        arm_manifest(module_name, core_path), encoding="utf-8"
    )
    shutil.copyfile(ARM_SOURCE, source_directory / "Arm.swift")
    scratch = workspace / f"{module_name}-build"
    subprocess.run(
        ["swift", "build", "-c", "release", "--scratch-path", str(scratch)],
        cwd=package_root,
        check=True,
        stdout=sys.stderr,
    )
    library = scratch / "release" / f"lib{module_name}.dylib"
    if not library.exists():
        raise FileNotFoundError(f"arm build produced no library at {library}")
    return library


class Arm:
    """One loaded arm, bound to its own dynamic library.

    Loaded RTLD_LOCAL so the two arms cannot resolve each other's symbols; the module-name
    check is what guards the ObjC class table, which RTLD_LOCAL does not cover.
    """

    def __init__(self, library_path):
        self._library = ctypes.CDLL(str(library_path), mode=ctypes.RTLD_LOCAL)
        self._library.arm_prepare.argtypes = [ctypes.c_int32] * 4
        self._library.arm_prepare.restype = ctypes.c_int32
        self._library.arm_batch.argtypes = [ctypes.c_int32]
        self._library.arm_batch.restype = ctypes.c_uint64
        self._library.arm_icon_cell_count.argtypes = []
        self._library.arm_icon_cell_count.restype = ctypes.c_int64

    def prepare(self, columns, rows, clip_rows, workload):
        if self._library.arm_prepare(
            columns, rows, clip_rows, WORKLOADS.index(workload)
        ) != 0:
            raise RuntimeError(
                f"arm failed to prepare its draw surface for workload {workload!r}; an "
                "arm built from an older TerminalCore checkout may not know it"
            )

    def batch(self, count):
        return self._library.arm_batch(count)

    def icon_cell_count(self):
        """Cells of the prepared surface that reach the packaged-symbols path.

        Refuses the unprepared arm's -1 rather than reporting it as zero icon cells: the
        two answers divide the absolute effect by different denominators.
        """
        count = self._library.arm_icon_cell_count()
        if count < 0:
            raise RuntimeError("an unprepared arm cannot report an icon cell count")
        return count


def calibrate_batch_count(arms, target_nanoseconds=TARGET_BATCH_NANOSECONDS):
    """Pick one batch size that clears the occupancy floor for every arm.

    Calibrating on the baseline arm alone made the batch size depend on comparison
    direction, so swapping the arms changed the measurement instead of only its sign.
    Taking the maximum over both arms is symmetric in them, which is what keeps a
    forward and a reversed run comparable.
    """
    counts = []
    for arm in arms:
        count = 1
        while arm.batch(count) < target_nanoseconds:
            count *= 2
        counts.append(count)
    return max(counts)


def shared_icon_cell_count(arms):
    """Take the icon cell count both arms agree on, or refuse the pair.

    Two arms that drew different numbers of icon cells did not draw the same corpus, so
    their paired difference is a content difference wearing a revision's name. That is a
    refusal rather than an average.
    """
    counts = {arm.icon_cell_count() for arm in arms}
    if len(counts) != 1:
        raise RuntimeError(
            f"the arms disagree on how many icon cells they drew ({sorted(counts)}); "
            "they are not drawing the same corpus, so nothing can be paired between them"
        )
    return counts.pop()


def warm_up(arms, batch_count):
    """Run one discarded batch on every arm so none enters measurement cold.

    Calibration used to leave only the baseline arm warm, biasing the paired
    difference against whichever arm sat in the candidate slot. An A/A control
    cannot reveal that, because there both arms hold identical code.
    """
    for arm in arms:
        arm.batch(batch_count)


def run_rounds(baseline, candidate, batch_count, rounds):
    """Alternate the arms ABBA, which is the production schedule shape."""
    results = []
    for _ in range(rounds):
        first_a = baseline.batch(batch_count)
        first_b = candidate.batch(batch_count)
        second_b = candidate.batch(batch_count)
        second_a = baseline.batch(batch_count)
        results.append({"a": [first_a, second_a], "b": [first_b, second_b]})
    return results


def direction_schedule():
    """Order the direction runs ABBA so neither is systematically measured first.

    Running forward then reverse put forward immediately after the rebuild every time,
    which is its own asymmetry: it reintroduced a +0.511% order bias after the warm-up
    fix had removed a comparable one. This is the same counterbalancing the batch schedule
    already applies within a round, lifted to the direction level.
    """
    return ["forward", "reverse", "reverse", "forward"]


def run_both_directions(arguments):
    """Measure both directions on an ABBA schedule, then report the antisymmetric estimate."""
    pairs = {
        "forward": (arguments.baseline_core, arguments.candidate_core),
        "reverse": (arguments.candidate_core, arguments.baseline_core),
    }
    collected = {"forward": [], "reverse": []}
    runs = []
    for name in direction_schedule():
        baseline, candidate = pairs[name]
        completed = subprocess.run(
            [
                sys.executable, str(pathlib.Path(__file__).resolve()),
                "--baseline-core", str(baseline),
                "--candidate-core", str(candidate),
                "--columns", str(arguments.columns),
                "--rows", str(arguments.rows),
                "--clip-rows", str(arguments.clip_rows),
                "--workload", arguments.workload,
                "--rounds", str(arguments.rounds),
            ],
            check=True, capture_output=True, text=True,
        )
        report = json.loads(completed.stdout)
        collected[name].extend(report["summary"]["pairedValuesPercent"])
        runs.append({"direction": name, "report": report})
    estimate = antisymmetric_estimate(collected["forward"], collected["reverse"])
    return both_directions_report(arguments, estimate, runs)


def both_directions_report(arguments, estimate, runs):
    """Assemble the two-direction report around its decision block.

    Separate from the measurement so the envelope -- which is the whole product, since
    nothing downstream sees anything else -- can be asserted without building an arm.
    """
    return {
        "schemaVersion": 1,
        "mode": "both-directions",
        "workload": arguments.workload,
        "directionSchedule": direction_schedule(),
        "estimate": estimate,
        "absoluteEstimate": absolute_antisymmetric_estimate(runs),
        "decision": frozen_decision(
            arguments.workload, arguments.rounds, "both-directions", estimate
        ),
        "runs": runs,
        "note": (
            "realEffectPercent is the claimable number: negative means the candidate "
            "revision is faster. orderBiasPercent should sit near zero; a large value "
            "means the measurement is asymmetric and neither direction can be trusted "
            "on its own. absoluteEstimate says the same thing in nanoseconds per draw, "
            "and per icon cell where the workload has any, so the size of the effect "
            "can be read without reconstructing the denominator."
        ),
    }


def single_direction_report(
    arguments, batch_count, quartets, absolute_differences, icon_cell_count
):
    """Assemble the one-direction report around its decision block.

    Same reason as `both_directions_report`: the envelope is testable without a build,
    and it must carry a decision block even though a single direction never decides.

    The `absolute` block is this direction's raw material, not a result. Its sign carries
    the slot bias, so only `both_directions_report` turns it into a claimable cost.
    """
    return {
        "schemaVersion": 1,
        "geometry": {
            "columns": arguments.columns,
            "rows": arguments.rows,
            "clipRows": arguments.clip_rows,
        },
        "workload": arguments.workload,
        "batchCount": batch_count,
        "isSelfControl": (
            pathlib.Path(arguments.baseline_core).resolve()
            == pathlib.Path(arguments.candidate_core).resolve()
        ),
        "baselineCore": str(pathlib.Path(arguments.baseline_core).resolve()),
        "candidateCore": str(pathlib.Path(arguments.candidate_core).resolve()),
        "summary": summarize(quartets),
        "absolute": {
            "iconCellCount": icon_cell_count,
            "pairedMeanNanosecondsPerDraw": statistics.fmean(absolute_differences),
            "pairedValuesNanosecondsPerDraw": absolute_differences,
        },
        "decision": frozen_decision(
            arguments.workload, arguments.rounds, "single-direction"
        ),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--baseline-core", type=pathlib.Path, default=DEFAULT_CORE,
        help="TerminalCore checkout for the baseline arm (default: this tree)")
    parser.add_argument(
        "--candidate-core", type=pathlib.Path, default=DEFAULT_CORE,
        help="TerminalCore checkout for the candidate arm; defaults to the baseline "
             "checkout, which makes the run an A/A control")
    parser.add_argument("--columns", type=int, default=160)
    parser.add_argument("--rows", type=int, default=50)
    parser.add_argument(
        "--clip-rows", type=int, default=4,
        help="rows of damage to clip to; 0 measures the full frame")
    parser.add_argument(
        "--workload", choices=WORKLOADS, default="btop-shaped",
        help="content the grid is filled with. 'btop-shaped' is dense sprite art, which "
             "the executor draws as rects and which reaches CoreText's glyph calls zero "
             "times; 'text-shaped' is printable ASCII, which measures the batched "
             "CTFontGetGlyphsForCharacters/CTFontDrawGlyphs fast path; 'fallback-shaped' "
             "is CJK and multi-scalar clusters, the only one that reaches the per-cell "
             "CTLine typesetting in drawTextCell; 'symbols-shaped' is private-use icons, "
             "the only one that reaches the packaged symbols face and its per-icon "
             "glyph lookup and clipped draw")
    parser.add_argument("--rounds", type=int, default=8)
    parser.add_argument(
        "--both-directions", action="store_true",
        help="measure forward and reversed, then report the antisymmetric estimate. "
             "Required for any claim about two revisions: a single direction carries an "
             "order bias that does not reverse with the arms. Runs as two processes "
             "because dlopen caches within one, so load order cannot otherwise differ")
    parser.add_argument(
        "--threshold", type=float, default=None,
        help="optional caller-supplied directional threshold in percent, reported under "
             "callerThreshold and labelled as the caller's. It never overrides the frozen "
             "rule in the report's decision block, and no workload needs it to be read")
    parser.add_argument("--equivalence-band", type=float, default=0.0)
    arguments = parser.parse_args()

    validate_module_names(BASELINE_MODULE, CANDIDATE_MODULE)
    ARTIFACTS.mkdir(parents=True, exist_ok=True)

    if arguments.both_directions:
        json.dump(
            run_both_directions(arguments), sys.stdout, indent=2, sort_keys=True
        )
        sys.stdout.write("\n")
        return

    baseline_library = build_arm(BASELINE_MODULE, arguments.baseline_core, ARTIFACTS)
    candidate_library = build_arm(CANDIDATE_MODULE, arguments.candidate_core, ARTIFACTS)

    baseline = Arm(baseline_library)
    candidate = Arm(candidate_library)
    for arm in (baseline, candidate):
        arm.prepare(
            arguments.columns, arguments.rows, arguments.clip_rows, arguments.workload
        )

    batch_count = calibrate_batch_count([baseline, candidate])
    warm_up([baseline, candidate], batch_count)
    rounds = run_rounds(baseline, candidate, batch_count, arguments.rounds)
    quartets = paired_quartets(rounds)

    report = single_direction_report(
        arguments,
        batch_count,
        quartets,
        paired_absolute_differences(rounds, batch_count),
        shared_icon_cell_count([baseline, candidate]),
    )
    if arguments.threshold is not None:
        report["callerThreshold"] = CAL.decide(
            [value for quartet in quartets for value in quartet],
            directional_threshold=arguments.threshold,
            equivalence_band=arguments.equivalence_band,
            estimator="median",
        )
        report["callerThreshold"]["thresholdSource"] = "caller-supplied; not a frozen rule"
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
