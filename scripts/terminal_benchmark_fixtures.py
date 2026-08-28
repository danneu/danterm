#!/usr/bin/env python3
"""Load provenance-bearing byte streams for the real-app benchmark corpus."""
import base64
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
        # committed otherwise: 1.25 MB of btop is large as JSON base64 and 149 KB
        # packed. Generated workloads stay plain -- they are a manifest, not a
        # payload. Keyed on the suffix so both forms remain readable by hand.
        if path.suffix == ".gz":
            recording = json.loads(gzip.decompress(path.read_bytes()).decode("utf-8"))
        else:
            recording = json.loads(path.read_text(encoding="utf-8"))
        chunks = []
        for event in recording["events"]:
            if event.get("type") != "feed":
                continue
            if set(event).intersection({"base64", "text", "hex"}) != {"base64"}:
                raise ValueError("Benchmark feed must contain only base64")
            chunks.append(base64.b64decode(event["base64"], validate=True))
        # A capture is repeated rather than re-captured to lengthen a block.
        # `research/20/F12` measured this workload's noise as additive -- near-flat
        # absolute SD across a 2.24x change in duration -- so the denominator is
        # the lever, and repetition moves it without a second capture session or
        # a change to what is being exercised. Valid only because each pass is
        # bracket-balanced and ends on the same frame, so the stream still draws
        # and still satisfies the completion assertion; the loader test pins both.
        # Decoded once and re-yielded: decoding per pass would charge the
        # producer for work the block is not measuring.
        for _ in range(workload.get("replayCount", 1)):
            yield from chunks
        return

    for segment in workload["segments"]:
        if "bytes" in segment:
            yield segment["bytes"].encode()
            continue
        for index in range(segment["repeat"]):
            yield segment["template"].format(index=index).encode()


# Phase bytes the Swift harness decodes. Only TIMED bytes sit inside the clock, so a
# fixture that has to establish terminal state first -- the kitten arms enter the alt
# screen and hide the cursor -- can send that state without charging it to the sample.
SETUP_PHASE = 0
TIMED_PHASE = 1
TEARDOWN_PHASE = 2


def frame_chunks(chunks, *, phase=TIMED_PHASE):
    """Frame chunks as the Swift harness decodes them: phase, big-endian length, bytes.

    Every producer of harness stdin goes through here. A second copy of this encoding
    would let one caller drift from the decoder without any test noticing.
    """
    framed = bytearray()
    for chunk in chunks:
        framed.append(phase)
        framed.extend(len(chunk).to_bytes(8, byteorder="big"))
        framed.extend(chunk)
    return bytes(framed)


def write_all(file_descriptor, data, writer=os.write):
    """Preserve fixture bytes when a blocking PTY write completes partially."""
    remaining = memoryview(data)
    while remaining:
        written = writer(file_descriptor, remaining)
        if written <= 0:
            raise OSError("PTY write made no progress")
        remaining = remaining[written:]
