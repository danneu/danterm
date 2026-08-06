#!/usr/bin/env python3
# Quantifies what one idle Terminal costs the process before it holds any content.
#
# Exists because the quantity that motivates arena work is *per-terminal fixed overhead*, and
# neither existing memory instrument reports it directly. `benchmark-memory` is a leak detector
# over a live GUI whose IOSurface churn dwarfs the effect; `terminal-memory-probe`'s census is
# exact but reports the arena's *logical* capacity, which a change to how the arena is backed
# would leave untouched. So the census reads "no change" for exactly the change worth making --
# the silent-zero failure agent-docs/measurement-discipline.md is about.
#
# What this adds over calling the probe once: repetition (so the spread is stated, not assumed)
# and a geometry sweep that acts as a control. Arena size cannot depend on columns or rows, so
# if the fixed term moves with geometry the instrument is measuring something else and the run
# says so instead of reporting a number.
#
# Emits every quantity beside its sample count, and prints the sensitive metric and the blind
# one side by side so a reader cannot pick up the blind one by accident.
#
#   scripts/terminal-fixed-cost-probe.py                     # 5 reps, control on
#   scripts/terminal-fixed-cost-probe.py --reps 9
#   scripts/terminal-fixed-cost-probe.py --json out.json     # artifact for a before/after diff
#   scripts/terminal-fixed-cost-probe.py --compare before.json
import argparse
import json
import pathlib
import statistics
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
PROBE = REPO / "lib/TerminalCore/.build/release/TerminalMemoryProbe"

# The control geometries. The arena is budget-derived, so its cost must be flat across these;
# per-cell storage is the known term that may move with geometry.
GEOMETRIES = [(179, 66), (80, 24), (40, 10)]


def build():
    subprocess.run(
        ["swift", "build", "-c", "release", "--package-path", "lib/TerminalCore",
         "--product", "TerminalMemoryProbe"],
        cwd=REPO, check=True,
    )


def run_probe(columns, rows):
    """One empty-payload measurement. `empty` because fixed cost is what is being priced:
    a payload would add content bytes to the very delta the caller wants clean."""
    out = subprocess.run(
        [str(PROBE), "--payload", "empty", "--columns", str(columns), "--rows", str(rows),
         "--json"],
        cwd=REPO, check=True, capture_output=True, text=True,
    ).stdout
    payload = json.loads(out)["payloads"][0]
    census = payload["census"]
    return {
        "columns": payload["columns"],
        "rows": payload["rows"],
        # The sensitive metric: what the process actually pays to hold one idle terminal.
        "footprintDeltaBytes": payload["footprintAfterBytes"] - payload["footprintBeforeBytes"],
        # The blind metric, reported so a diff can show it did NOT move. Logical address space,
        # not residency -- it is identical whether the arena is eagerly or lazily backed.
        "arenaCapacityBytes": census["retainedArenaCapacityBytes"],
        "arenaBytesInUse": census["retainedArenaBytesInUse"],
        "cellStorageBytes": census["cellStorageBytes"],
    }


def summarize(samples):
    deltas = [s["footprintDeltaBytes"] for s in samples]
    non_cell_deltas = [s["footprintDeltaBytes"] - s["cellStorageBytes"] for s in samples]
    return {
        "sampleCount": len(deltas),
        "medianBytes": int(statistics.median(deltas)),
        "nonCellFootprintBytes": int(statistics.median(non_cell_deltas)),
        "minBytes": min(deltas),
        "maxBytes": max(deltas),
        "spreadBytes": max(deltas) - min(deltas),
        "arenaCapacityBytes": samples[0]["arenaCapacityBytes"],
        "arenaBytesInUse": samples[0]["arenaBytesInUse"],
        "cellStorageBytes": samples[0]["cellStorageBytes"],
    }


def control_residual_drift_bytes(geometries):
    """The unexplained geometry range after subtracting exact live-cell storage."""
    residuals = [geometry["nonCellFootprintBytes"] for geometry in geometries]
    return max(residuals) - min(residuals)


def mb(value):
    return value / 1_048_576.0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reps", type=int, default=5, help="measurements per geometry")
    parser.add_argument("--json", metavar="PATH", help="write the artifact here")
    parser.add_argument("--compare", metavar="PATH", help="diff against an earlier artifact")
    parser.add_argument("--no-build", action="store_true")
    args = parser.parse_args()

    if not args.no_build:
        build()
    if not PROBE.exists():
        sys.exit(f"probe binary missing: {PROBE}")

    report = {"repsPerGeometry": args.reps, "geometries": []}
    for columns, rows in GEOMETRIES:
        samples = [run_probe(columns, rows) for _ in range(args.reps)]
        entry = summarize(samples)
        entry["columns"], entry["rows"] = columns, rows
        report["geometries"].append(entry)

    primary = report["geometries"][0]
    report["fixedCostBytes"] = primary["medianBytes"]

    # The control reports the continuous unexplained range after removing exact cell storage.
    # It deliberately has no frozen pass/fail threshold: once the eager arena is gone, row-array
    # allocation and page rounding are a visible but much smaller geometry-dependent residual.
    report["controlResidualDriftBytes"] = control_residual_drift_bytes(report["geometries"])

    print(f"per-terminal fixed cost -- empty payload, {args.reps} reps per geometry\n")
    print(f"{'geometry':>10}  {'median':>10}  {'non-cell':>10}  {'spread':>9}  {'n':>3}  "
          f"{'arena cap':>10}  {'cells':>9}")
    print("-" * 74)
    for g in report["geometries"]:
        print(f"{g['columns']:>4}x{g['rows']:<5} {mb(g['medianBytes']):>9.2f}M  "
              f"{mb(g['nonCellFootprintBytes']):>9.2f}M  "
              f"{g['spreadBytes']:>8}B  {g['sampleCount']:>3}  "
              f"{mb(g['arenaCapacityBytes']):>9.2f}M  {mb(g['cellStorageBytes']):>8.3f}M")

    print(f"\ncontrol: {report['controlResidualDriftBytes']} B residual drift after subtracting "
          f"exact cell storage across a "
          f"{GEOMETRIES[0][0] * GEOMETRIES[0][1] // (GEOMETRIES[-1][0] * GEOMETRIES[-1][1])}x "
          "cell-count range")
    print(f"headline: {mb(report['fixedCostBytes']):.2f} MB to hold one empty "
          f"{GEOMETRIES[0][0]}x{GEOMETRIES[0][1]} terminal")
    print("\nread footprintDelta, not arenaCapacity: capacity is logical address space and is\n"
          "invariant under a change to how the arena is backed.")

    if args.compare:
        before = json.loads(pathlib.Path(args.compare).read_text())
        delta = report["fixedCostBytes"] - before["fixedCostBytes"]
        noise = max(g["spreadBytes"] for g in report["geometries"])
        print(f"\nvs {args.compare}:")
        print(f"  before {mb(before['fixedCostBytes']):.2f} MB -> "
              f"after {mb(report['fixedCostBytes']):.2f} MB  "
              f"({delta:+d} B, {delta / before['fixedCostBytes'] * 100:+.1f}%)")
        # A difference inside the observed spread is not a result, whatever its sign.
        if abs(delta) <= noise:
            print(f"  WITHIN NOISE (spread {noise} B) -- not a measured change")

    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(f"\nwrote {args.json}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
