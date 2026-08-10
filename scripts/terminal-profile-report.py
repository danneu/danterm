#!/usr/bin/env python3
"""Turn a profiler artifact into something an agent can read without Instruments.

`sample` prints an indented call graph and `xctrace` records a `.trace` bundle
that only Instruments.app opens; neither is usable by a process that has to
reach a conclusion on its own. This reads either one -- exporting the trace
first when handed a bundle -- and emits folded stacks plus a bounded JSON
summary (per-thread and per-binary shares, hottest self and inclusive frames,
hottest stacks).

It belongs beside the benchmark harness rather than inside it because it is
pure post-processing: it never launches, measures, or attributes a run, and its
numbers stay diagnostic-only for exactly the reasons the harness documents.
Report shape and parser behavior are pinned by
scripts/tests/terminal_profile_report_test.py.
"""
import argparse
import collections
import dataclasses
import json
import pathlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ElementTree


TIME_PROFILE_XPATH = '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'


@dataclasses.dataclass(frozen=True)
class Frame:
    """One resolved stack frame. Kept hashable so aggregation can key on it."""

    symbol: str
    binary: str = ""


@dataclasses.dataclass(frozen=True)
class Sample:
    """One weighted stack, root-first.

    `weight` is nanoseconds for xctrace and sample counts for `sample`; the unit
    travels in the summary metadata rather than here, so both parsers can feed
    the same aggregation.
    """

    weight: int
    thread: str
    state: str
    stack: list


# --- xctrace time-profile XML -------------------------------------------------

# Every repeated value in an xctrace export is emitted once with an `id` and
# referenced afterwards as `<tag ref="id"/>`. Resolution is therefore mandatory,
# not an optimization: in a real trace most frames appear only as refs.
def _post_order(root):
    for child in root:
        yield from _post_order(child)
    yield root


def _resolve(element, table):
    reference = element.get("ref")
    if reference is not None:
        return table.get(reference)
    return table.get(element.get("id"))


def parse_xctrace_time_profile(xml_text):
    """Parse a `--xpath ...time-profile` export into root-first samples."""
    table = {}
    samples = []
    root = ElementTree.fromstring(xml_text)
    # Post-order: a row's frames must be interned before the row that cites them,
    # and a ref always points at an id defined earlier in document order.
    for node in _post_order(root):
        if node.tag == "binary":
            if node.get("id"):
                table[node.get("id")] = node.get("name", "")
        elif node.tag == "frame":
            if node.get("id"):
                binary_element = node.find("binary")
                binary = _resolve(binary_element, table) if binary_element is not None else ""
                table[node.get("id")] = Frame(node.get("name", "?"), binary or "")
        elif node.tag == "backtrace":
            if node.get("id"):
                frames = [_resolve(child, table) for child in node.findall("frame")]
                table[node.get("id")] = tuple(frame for frame in frames if frame)
        elif node.tag in ("thread", "thread-state", "core", "process"):
            if node.get("id"):
                table[node.get("id")] = node.get("fmt", "")
        elif node.tag == "weight":
            if node.get("id"):
                table[node.get("id")] = int((node.text or "0").strip() or 0)
        elif node.tag == "tagged-backtrace":
            if node.get("id"):
                inner = node.find("backtrace")
                table[node.get("id")] = _resolve(inner, table) if inner is not None else ()
        elif node.tag == "row":
            samples.append(_row_to_sample(node, table))
    return [sample for sample in samples if sample is not None]


def _row_to_sample(row, table):
    stack = ()
    for child in row:
        if child.tag == "tagged-backtrace":
            stack = _resolve(child, table) or ()
        elif child.tag == "backtrace":
            stack = _resolve(child, table) or ()
    if not stack:
        return None
    weight_element = row.find("weight")
    thread_element = row.find("thread")
    state_element = row.find("thread-state")
    return Sample(
        weight=_resolve(weight_element, table) or 0 if weight_element is not None else 0,
        thread=(_resolve(thread_element, table) or "") if thread_element is not None else "",
        state=(_resolve(state_element, table) or "") if state_element is not None else "",
        # xctrace stores stacks leaf-first; everything downstream wants root-first.
        stack=list(reversed(stack)),
    )


# --- sample(1) call graph -----------------------------------------------------

# `    + ! : 4 leafA  (in DanTerm Benchmark) + 72  [0x1947855bc]`
#  ^prefix width carries the depth^  ^inclusive count^
_CALL_GRAPH_ROW = re.compile(r"^(?P<prefix>[ +!:|]*)(?P<count>\d+) +(?P<rest>\S.*)$")
_FRAME_TEXT = re.compile(r"^(?P<symbol>.*?)\s+\(in (?P<binary>[^)]+)\)")
_END_OF_CALL_GRAPH = ("Binary Images:", "Total number in stack", "Sort by top of stack")


def parse_sample_call_graph(text):
    """Parse `sample`'s indented call graph into root-first samples.

    The printed count is inclusive, so a node's own weight is its count minus
    its children's; nodes that own nothing produce no sample.
    """
    lines = text.splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.startswith("Call graph:")) + 1
    except StopIteration:
        return []

    # (column, node) stack; a node is {frame, count, children_count, thread, path}
    open_nodes = []
    finished = []
    thread = ""
    # Thread headers sit at the section's base column and frames are indented past
    # it. Depth is the only reliable discriminator: `sample` draws the + ! : |
    # characters solely where a branch exists, so a thread whose call graph never
    # forks prints its frames with plain spaces and no marker at all.
    base_column = None

    def close_to(column):
        while open_nodes and open_nodes[-1][0] >= column:
            finished.append(open_nodes.pop()[1])

    for line in lines[start:]:
        if any(line.startswith(marker) for marker in _END_OF_CALL_GRAPH):
            break
        match = _CALL_GRAPH_ROW.match(line)
        if not match:
            continue
        prefix, count, rest = match.group("prefix"), int(match.group("count")), match.group("rest")
        column = len(prefix)
        if base_column is None:
            base_column = column
        if column <= base_column:
            close_to(0)
            thread = re.sub(r"\s+", " ", rest).strip()
            continue
        close_to(column)
        node = {
            "frame": _parse_sample_frame(rest),
            "count": count,
            "children": 0,
            "thread": thread,
            "path": [item[1]["frame"] for item in open_nodes],
        }
        if open_nodes:
            open_nodes[-1][1]["children"] += count
        open_nodes.append((column, node))
    close_to(0)

    samples = []
    for node in finished:
        own = node["count"] - node["children"]
        if own <= 0:
            continue
        samples.append(
            Sample(
                weight=own,
                thread=node["thread"],
                # `sample` reports no per-sample thread state.
                state="",
                stack=node["path"] + [node["frame"]],
            )
        )
    return samples


def _parse_sample_frame(rest):
    match = _FRAME_TEXT.match(rest)
    if match:
        return Frame(match.group("symbol").strip(), match.group("binary").strip())
    return Frame(rest.split("  ")[0].strip(), "")


# --- aggregation --------------------------------------------------------------


def detect_format(text):
    head = text[:4000]
    if "time-profile" in head or "trace-query-result" in head:
        return "xctrace"
    if "Call graph:" in text or head.startswith("Analysis of sampling"):
        return "sample"
    raise ValueError("Unrecognized profile artifact: expected xctrace XML or sample(1) text")


def parse(text):
    kind = detect_format(text)
    if kind == "xctrace":
        return kind, parse_xctrace_time_profile(text)
    return kind, parse_sample_call_graph(text)


def filter_samples(samples, threads=None, states=None):
    """Narrow to threads/states by case-insensitive substring match."""
    kept = samples
    if threads:
        needles = [needle.lower() for needle in threads]
        kept = [s for s in kept if any(needle in s.thread.lower() for needle in needles)]
    if states:
        needles = [needle.lower() for needle in states]
        kept = [s for s in kept if any(needle in s.state.lower() for needle in needles)]
    return kept


def fold(samples):
    """Collapse to `thread;root;...;leaf -> weight`, the flamegraph/speedscope format."""
    folded = collections.Counter()
    for sample in samples:
        # Symbols only: flamegraph/speedscope render the key verbatim, and the
        # per-binary attribution lives in the JSON report instead.
        key = ";".join([sample.thread or "unknown"] + [frame.symbol for frame in sample.stack])
        folded[key] += sample.weight
    return dict(folded)


def _share(part, whole):
    return round(part / whole, 6) if whole else 0.0


def _ranked(counter, total, top, extra=None):
    rows = []
    for frame, weight in counter.most_common(top):
        row = {"frame": frame.symbol, "binary": frame.binary, "weight": weight}
        row["share"] = _share(weight, total)
        if extra is not None:
            row["samples"] = extra.get(frame, 0)
        rows.append(row)
    return rows


def summarize(samples, top=25, source=None):
    """Build the bounded JSON report: totals, per-thread/binary, hot frames and stacks."""
    total = sum(sample.weight for sample in samples)
    self_weight = collections.Counter()
    self_samples = collections.Counter()
    total_weight = collections.Counter()
    binary_weight = collections.Counter()
    thread_weight = collections.Counter()
    thread_samples = collections.Counter()
    state_weight = collections.Counter()

    for sample in samples:
        thread_weight[sample.thread] += sample.weight
        thread_samples[sample.thread] += 1
        state_weight[sample.state or "unknown"] += sample.weight
        if not sample.stack:
            continue
        leaf = sample.stack[-1]
        self_weight[leaf] += sample.weight
        self_samples[leaf] += 1
        binary_weight[leaf.binary or "unknown"] += sample.weight
        # A frame recurring in one stack is one frame's worth of inclusive time.
        for frame in set(sample.stack):
            total_weight[frame] += sample.weight

    folded = fold(samples)
    hot_stacks = [
        {"stack": key.split(";"), "weight": weight, "share": _share(weight, total)}
        for key, weight in collections.Counter(folded).most_common(top)
    ]

    report = {
        "totals": {"samples": len(samples), "weight": total},
        "threads": [
            {
                "thread": thread,
                "weight": weight,
                "samples": thread_samples[thread],
                "share": _share(weight, total),
            }
            for thread, weight in thread_weight.most_common()
        ],
        "threadStates": [
            {"state": state, "weight": weight, "share": _share(weight, total)}
            for state, weight in state_weight.most_common()
        ],
        "binaries": [
            {"binary": binary, "selfWeight": weight, "share": _share(weight, total)}
            for binary, weight in binary_weight.most_common(top)
        ],
        "topSelf": _ranked(self_weight, total, top, extra=self_samples),
        "topTotal": _ranked(total_weight, total, top),
        "hotStacks": hot_stacks,
    }
    if source:
        report["source"] = source
    return report


def render_folded(folded):
    return "".join(f"{key} {weight}\n" for key, weight in sorted(folded.items()))


def render_summary(report, top=15):
    """Compact text for stdout: what an agent reads before deciding to open the JSON."""
    unit = report.get("source", {}).get("weightUnit", "weight")
    scale = 1e6 if unit == "nanoseconds" else 1.0
    suffix = " ms" if unit == "nanoseconds" else " samples"
    total = report["totals"]["weight"] or 1
    lines = [
        f"samples: {report['totals']['samples']}  "
        f"total: {report['totals']['weight'] / scale:.1f}{suffix}",
        "threads:",
    ]
    for thread in report["threads"][:5]:
        lines.append(f"  {thread['share'] * 100:5.1f}%  {thread['thread']}")
    lines.append(f"top self frames (share of {report['totals']['weight'] / scale:.1f}{suffix}):")
    for entry in report["topSelf"][:top]:
        binary = f" [{entry['binary']}]" if entry["binary"] else ""
        lines.append(
            f"  {_share(entry['weight'], total) * 100:5.1f}%  {entry['frame']}{binary}"
        )
    return "\n".join(lines) + "\n"


# --- input resolution ---------------------------------------------------------


def _export_trace(trace_path, destination):
    """Run the xctrace export that turns a `.trace` bundle into sample rows.

    The bundle itself is opaque to everything but Instruments.app, so an agent
    handed only a `.trace` has nothing to read; this is the step that makes the
    artifact self-service.
    """
    if not shutil.which("xcrun"):
        raise SystemExit("xcrun is unavailable; install the Xcode command-line tools")
    subprocess.run(
        [
            "xcrun", "xctrace", "export",
            "--input", str(trace_path),
            "--xpath", TIME_PROFILE_XPATH,
            "--output", str(destination),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return destination


def resolve_input(path):
    """Accept a profile directory, a `.trace` bundle, or an already-exported file."""
    path = pathlib.Path(path)
    if path.is_dir() and path.suffix != ".trace":
        for candidate in ("time-profile.xml", "sample.txt"):
            if (path / candidate).is_file():
                return path / candidate
        trace = path / "profile.trace"
        if trace.exists():
            return _export_trace(trace, path / "time-profile.xml")
        raise SystemExit(f"No profile artifact found in {path}")
    if path.suffix == ".trace":
        return _export_trace(path, path.parent / "time-profile.xml")
    if not path.is_file():
        raise SystemExit(f"No such profile artifact: {path}")
    return path


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "input",
        help="profile directory, .trace bundle, exported time-profile XML, or sample.txt",
    )
    parser.add_argument("--top", type=int, default=25, help="entries per ranking")
    parser.add_argument("--thread", action="append", help="keep threads matching substring")
    parser.add_argument("--state", action="append", help="keep thread states matching substring")
    parser.add_argument("--json", dest="json_path", help="write the report here")
    parser.add_argument("--folded", dest="folded_path", help="write folded stacks here")
    parser.add_argument("--quiet", action="store_true", help="suppress the stdout summary")
    arguments = parser.parse_args(argv)

    source_path = resolve_input(arguments.input)
    kind, samples = parse(source_path.read_text(errors="replace"))
    # An empty capture is a failed profiling run, not a profile of an idle
    # process: recording with a template that has no time-profile table (any of
    # the memory templates) exports an XML with no rows at all. Writing a
    # zero-filled report for it would read as success to anyone downstream.
    if not samples:
        raise SystemExit(
            f"No samples parsed from {source_path}. If this came from a .trace, the "
            "recording template produced no time-profile table -- check the schemas "
            "in trace-toc.xml."
        )
    filtered = filter_samples(samples, threads=arguments.thread, states=arguments.state)
    if not filtered:
        raise SystemExit(
            f"No samples matched thread={arguments.thread or []} "
            f"state={arguments.state or []} in {source_path} "
            f"({len(samples)} samples before filtering)."
        )
    samples = filtered
    report = summarize(
        samples,
        top=arguments.top,
        source={
            "kind": "xctrace-time-profile" if kind == "xctrace" else "sample-call-graph",
            "path": str(source_path),
            "weightUnit": "nanoseconds" if kind == "xctrace" else "samples",
            "threadFilter": arguments.thread or [],
            "stateFilter": arguments.state or [],
            "profiledTimingsAreDiagnosticOnly": True,
        },
    )

    # A filtered view is a narrower question than the one the capture answered,
    # so it lands beside the unfiltered report rather than replacing it.
    suffix = "-filtered" if (arguments.thread or arguments.state) else ""
    default_root = source_path.parent
    json_path = pathlib.Path(
        arguments.json_path or default_root / f"profile-report{suffix}.json"
    )
    folded_path = pathlib.Path(
        arguments.folded_path or default_root / f"profile-folded{suffix}.txt"
    )
    json_path.write_text(json.dumps(report, indent=2) + "\n")
    folded_path.write_text(render_folded(fold(samples)))

    if not arguments.quiet:
        sys.stdout.write(render_summary(report))
        print(f"report: {json_path}")
        print(f"folded: {folded_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
