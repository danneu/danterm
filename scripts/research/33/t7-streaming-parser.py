#!/usr/bin/env python3
"""Research doc 33, task T7: gate the streaming parser.

`T7` deletes the eager `[TerminalStreamAction]`: `TerminalInputStream` hands back one action
per call and `Terminal.feed` applies each to the grid before pulling the next, so the token
stream is never materialized. The implementation is **parked, not landed** -- claim 4 below is
why -- so it lives beside this script as `t7-streaming-parser.patch`, and this script builds
both arms itself: a clean worktree at the named revision, and the same worktree with the patch
applied. That is what lets the gate run on both sides of a change the tree does not contain.

Four claims, and the script says for each one whether it is measured or structural:

1. **Equivalence (measured).** The streaming parser must recognize the same token stream the
   eager one did -- same counts, same composition, per corpus, at every chunking. `F9` recorded
   that stream; the expectations below are its numbers. `T7` claims nothing about what the
   parser recognizes, so movement here is a regression, not a result.
2. **The array is gone (structural).** No `[TerminalStreamAction]` may be constructed anywhere
   under `lib/*/Sources` in the patched arm. This is a grep, and the script labels it as one.
3. **Chunk-invariant footprint (measured).** Before `T7`, feeding a corpus in one call cost
   ~103.7 MB against ~72.8 MB chunked, because the parse spike scaled with the chunk. After it
   the two must agree, since nothing in the parse path scales with the chunk any more. This is
   the claim that fails loudly if the array ever comes back.
4. **Feed throughput (measured, and the claim that failed).** The parked implementation is
   1.5-3% slower per token headless and `slower` on `scrollback-stream` under
   `benchmark-confirm`, because a per-token call boundary costs more than the array traffic it
   saves. This script's A/B is a **diagnostic**, not a verdict: directional claims come from
   `terminal-benchmark-compare.py`. It is here so the size of the cost is reproducible without
   re-deriving it.
"""
import argparse
import json
import pathlib
import re
import shutil
import statistics
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))

from terminal_benchmark_fixtures import iter_bytes, load_corpus  # noqa: E402

HERE = pathlib.Path(__file__).resolve().parent
PATCH = HERE / "t7-streaming-parser.patch"
PROBE = HERE / "t7-streaming-parser-probe.swift"
PTY_TURN_LIMIT = 16 * 1024

# `F9`'s table, verbatim. Comparing against a literal rather than against a second run is
# deliberate: the before side of this gate is a finding in the tree, so a change that moved
# both sides together would still be caught.
F9_TOKENS = {
    "scrollback-stream": {
        "tokenCount": 1_525_000,
        "printActions": 1_500_000,
        "executeActions": 25_000,
        "csiActions": 0,
    },
    "styled-screen-redraw": {"tokenCount": 4_399_501},
    "unicode-wrapping": {"tokenCount": 1_314_000},
    "incremental-screen-updates": {
        "tokenCount": 3_200_029,
        "printActions": 2_500_025,
        "executeActions": 100_000,
        "csiActions": 600_004,
    },
    "synchronized-frames": {"tokenCount": 934_889},
}

FORBIDDEN_SOURCE_PATTERN = re.compile(r"\[\s*TerminalStreamAction\s*\]")

# Footprint readings drift with allocator bucket rounding between runs, so chunk invariance
# needs a tolerance. It sits far below the ~31 MB spike it has to catch and far above the
# ~0.1 MB drift observed across repeated runs.
CHUNK_INVARIANCE_TOLERANCE_MB = 2.0


def git(*arguments, cwd=ROOT):
    return subprocess.run(
        ["git", *arguments], cwd=str(cwd), check=True, capture_output=True, text=True
    ).stdout.strip()


def add_worktree(path, revision):
    git("worktree", "add", "--detach", str(path), revision)


def remove_worktree(path):
    subprocess.run(
        ["git", "worktree", "remove", "--force", str(path)],
        cwd=str(ROOT),
        capture_output=True,
    )


def frame(scratch, name, workload):
    """Write one corpus in the 8-byte big-endian length framing the probe reads."""
    path = scratch / f"{name}.framed"
    with path.open("wb") as handle:
        for chunk in iter_bytes(ROOT, workload):
            handle.write(len(chunk).to_bytes(8, byteorder="big"))
            handle.write(chunk)
    return path


def build_probe(arm, scratch):
    """Compile the streaming probe together with one arm's engine sources as one module."""
    main = scratch / "main.swift"
    shutil.copyfile(PROBE, main)
    binary = scratch / "t7-probe"
    sources = sorted((arm / "lib/TerminalCore/Sources/TerminalCore").glob("*.swift"))
    subprocess.run(
        ["swiftc", "-O", "-swift-version", "6", "-o", str(binary), str(main),
         *(str(path) for path in sources)],
        check=True,
    )
    return binary


def probe_tokens(binary, framed, limit):
    result = subprocess.run(
        [str(binary), str(limit), *(f"{name}={path}" for name, path in framed)],
        check=True,
        capture_output=True,
    )
    return json.loads(result.stdout)["runs"][0]


def check_tokens(runs):
    failures = []
    for limit, run in runs.items():
        corpora = {corpus["name"]: corpus for corpus in run["corpora"]}
        for name, expected in F9_TOKENS.items():
            observed = corpora.get(name)
            if observed is None:
                failures.append(f"chunk {limit}: corpus {name} missing")
                continue
            if observed["peakLiveActions"] > 1:
                failures.append(
                    f"chunk {limit}: {name} held {observed['peakLiveActions']} actions at once"
                )
            for field, value in expected.items():
                if observed[field] != value:
                    failures.append(
                        f"chunk {limit}: {name}.{field} is {observed[field]:,}, "
                        f"F9 recorded {value:,}"
                    )
    return failures


def check_no_action_array(arm):
    hits = []
    for root in sorted((arm / "lib").glob("*/Sources")):
        for path in sorted(root.rglob("*.swift")):
            for number, line in enumerate(path.read_text().splitlines(), start=1):
                if FORBIDDEN_SOURCE_PATTERN.search(line):
                    hits.append(f"{path.relative_to(arm)}:{number}: {line.strip()}")
    return hits


def swift_build(arm, product):
    subprocess.run(
        ["swift", "build", "-c", "release", "--package-path",
         str(arm / "lib/TerminalCore"), "--product", product],
        check=True,
        cwd=str(arm),
        stdout=subprocess.DEVNULL,
    )
    return arm / "lib/TerminalCore/.build/release" / product


def footprint_mb(binary, chunk):
    """One `TerminalMemoryProbe` reading, in the MiB its own table prints."""
    arguments = [str(binary), "--payload", "scrollback-plain", "--json"]
    if chunk is not None:
        arguments += ["--chunk", str(chunk)]
    entry = json.loads(
        subprocess.run(arguments, check=True, capture_output=True, text=True).stdout
    )["payloads"][0]
    return (entry["footprintAfterBytes"] - entry["footprintBeforeBytes"]) / (1024 * 1024)


def feed_nanoseconds(binary, fixture):
    result = subprocess.run(
        [str(binary), "--fixed", "2", "1"], input=fixture, check=True, capture_output=True
    )
    return json.loads(result.stdout)["feedDurationNanoseconds"][0]


def paired_feed_medians(binaries, fixture, rounds=3):
    """Alternate the two arms ABBA so drift cancels. Diagnostic only -- no verdict."""
    samples = {name: [] for name in binaries}
    for _ in range(rounds):
        for name, binary in binaries.items():
            samples[name].append(feed_nanoseconds(binary, fixture))
        for name, binary in reversed(list(binaries.items())):
            samples[name].append(feed_nanoseconds(binary, fixture))
    return {name: statistics.median(values) for name, values in samples.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", default="HEAD", help="revision both arms start from")
    parser.add_argument("--skip-throughput", action="store_true", help="skip claim 4")
    arguments = parser.parse_args()

    failures = []
    corpus = load_corpus(ROOT)

    with tempfile.TemporaryDirectory(prefix="t7-streaming-") as directory:
        scratch = pathlib.Path(directory)
        baseline = scratch / "baseline"
        candidate = scratch / "candidate"
        try:
            add_worktree(baseline, arguments.revision)
            add_worktree(candidate, arguments.revision)
            git("apply", str(PATCH), cwd=candidate)

            framed = [(name, frame(scratch, name, workload)) for name, workload in corpus.items()]

            print("== claim 1 (measured): the token stream is F9's, at every chunking ==")
            binary = build_probe(candidate, scratch)
            runs = {
                limit: probe_tokens(binary, framed, limit)
                for limit in (0, PTY_TURN_LIMIT, -1)
            }
            token_failures = check_tokens(runs)
            for corpus_report in runs[0]["corpora"]:
                expected = F9_TOKENS.get(corpus_report["name"], {})
                print(
                    f"  {corpus_report['name']:<28}{corpus_report['tokenCount']:>12,} tokens"
                    f"  (F9: {expected.get('tokenCount', 0):,})"
                    f"  peak live actions {corpus_report['peakLiveActions']}"
                )
            print("  PASS" if not token_failures else "  FAIL")
            for failure in token_failures:
                print(f"    {failure}")
            failures += token_failures

            print()
            print("== claim 2 (structural): no [TerminalStreamAction] under lib/*/Sources ==")
            for label, arm in (("baseline", baseline), ("candidate", candidate)):
                hits = check_no_action_array(arm)
                print(f"  {label}: {len(hits)} occurrences")
                for hit in hits:
                    print(f"    {hit}")
                if label == "candidate" and hits:
                    failures += hits
            print("  (this is a grep, not a measurement)")

            print()
            print("== claim 3 (measured): single-shot feeding costs what chunked feeding costs ==")
            for label, arm in (("baseline", baseline), ("candidate", candidate)):
                probe = swift_build(arm, "TerminalMemoryProbe")
                single = footprint_mb(probe, 0)
                chunked = footprint_mb(probe, None)
                difference = abs(single - chunked)
                print(
                    f"  {label:<10} single-shot {single:>7.2f} MB   chunked {chunked:>7.2f} MB"
                    f"   difference {difference:>6.2f} MB"
                )
                if label == "candidate" and difference > CHUNK_INVARIANCE_TOLERANCE_MB:
                    message = f"footprint still scales with chunk size: {difference:.2f} MB apart"
                    print(f"  FAIL: {message}")
                    failures.append(message)
            print(f"  tolerance {CHUNK_INVARIANCE_TOLERANCE_MB} MB")

            if not arguments.skip_throughput:
                print()
                print("== claim 4 (measured, diagnostic): headless feed throughput ==")
                binaries = {
                    label: swift_build(arm, "TerminalCoreBenchmark")
                    for label, arm in (("baseline", baseline), ("candidate", candidate))
                }
                for label, workloads in (
                    ("scrollback-stream", ["scrollback-stream"]),
                    ("four-stream fixture", list(corpus)),
                ):
                    fixture = bytearray()
                    for name in workloads:
                        for chunk in iter_bytes(ROOT, corpus[name]):
                            fixture += len(chunk).to_bytes(8, byteorder="big")
                            fixture += chunk
                    medians = paired_feed_medians(binaries, bytes(fixture))
                    change = 100 * (medians["candidate"] - medians["baseline"]) / medians["baseline"]
                    print(
                        f"  {label:<22} baseline {medians['baseline'] / 1e6:>9.2f} ms"
                        f"   candidate {medians['candidate'] / 1e6:>9.2f} ms   {change:+.2f}%"
                    )
                print("  No verdict here by construction: `just benchmark-confirm` decides")
                print("  direction, and it read `slower` on scrollback-stream. See F15.")
        finally:
            remove_worktree(candidate)
            remove_worktree(baseline)

    print()
    print("VERDICT on claims 1-3: " + ("PASS" if not failures else f"FAIL ({len(failures)})"))
    print("Claim 4 is why T7 is parked rather than landed; see docs/research/33/F15.")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
