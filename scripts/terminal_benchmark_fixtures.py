#!/usr/bin/env python3
"""Load provenance-bearing byte streams for the real-app benchmark corpus."""
import gzip
import json
import os


def load_corpus(root):
    """Return the ordered workload map from the committed corpus manifest."""
    path = root / "benchmarks" / "fixtures" / "terminal-app.json"
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("schemaVersion") != 1:
        raise ValueError("Unsupported terminal benchmark fixture schema")
    workloads = document.get("workloads")
    if not isinstance(workloads, dict) or not workloads:
        raise ValueError("Terminal benchmark corpus has no workloads")
    for name, workload in workloads.items():
        provenance = workload.get("provenance", {})
        if (
            not workload.get("identity")
            or not workload.get("dominantQuestion")
            or not provenance.get("source")
            or not provenance.get("license")
        ):
            raise ValueError(f"Benchmark workload lacks identity, dominant question, or provenance: {name}")
    return workloads


def iter_bytes(root, workload):
    """Yield a workload's committed bytes without constructing one giant buffer."""
    if "recording" in workload:
        path = root / workload["recording"]
        # Captured workloads are stored gzipped because a real one cannot be
        # committed otherwise: 1.25 MB of btop is 6.2 MB as JSON hex and 149 KB
        # packed. Generated workloads stay plain -- they are a manifest, not a
        # payload. Keyed on the suffix so both forms remain readable by hand.
        if path.suffix == ".gz":
            recording = json.loads(gzip.decompress(path.read_bytes()).decode("utf-8"))
        else:
            recording = json.loads(path.read_text(encoding="utf-8"))
        for event in recording["events"]:
            if event.get("type") == "feed":
                yield bytes.fromhex(event["hex"])
        return

    for segment in workload["segments"]:
        if "bytes" in segment:
            yield segment["bytes"].encode()
            continue
        for index in range(segment["repeat"]):
            yield segment["template"].format(index=index).encode()


def write_all(file_descriptor, data, writer=os.write):
    """Preserve fixture bytes when a blocking PTY write completes partially."""
    remaining = memoryview(data)
    while remaining:
        written = writer(file_descriptor, remaining)
        if written <= 0:
            raise OSError("PTY write made no progress")
        remaining = remaining[written:]
