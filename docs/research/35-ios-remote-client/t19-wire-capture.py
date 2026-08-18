#!/usr/bin/env python3
"""T19's instrument: record and account a pane.tape follow stream's wire bytes.

capture: subscribes the way the phone joins (follow, reconstructible, from now)
and writes every byte the server sends into <out>.raw, with per-recv-chunk
timestamps in <out>.meta.json. It decodes nothing while capturing beyond
watching for the subscribe reply, so the recording is the socket's bytes.

analyze: splits a capture into the join prefix (hello, start reply, sync and
gap records) and the steady stream that follows, then reports wire bytes,
decoded PTY payload bytes, the envelope share, and three deflate results:
whole-blob, per-record sync-flushed (what a latency-preserving compressed wire
gets), and payload-only (the floor a binary framing could reach before its own
compression).

Diagnostic instrument, not a benchmark. Run it against a throwaway
`just launch-slot` instance, never the user's app.

    python3 t19-wire-capture.py capture <socket> <pane-id> --out <prefix> \
        [--duration <s>] [--ready-file <path>]
    python3 t19-wire-capture.py analyze <prefix>...
"""
import argparse
import base64
import json
import pathlib
import signal
import socket
import sys
import time
import zlib


def capture(args):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(args.socket)
    request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "pane.tape",
        "params": {
            "pane": args.pane,
            "follow": True,
            "start": "now",
            "mode": "reconstructible",
        },
    }
    sock.sendall(json.dumps(request).encode() + b"\n")

    stop = {"flag": False}
    signal.signal(signal.SIGTERM, lambda *_: stop.update(flag=True))
    signal.signal(signal.SIGINT, lambda *_: stop.update(flag=True))

    raw_path = pathlib.Path(args.out + ".raw")
    chunks = []
    started = time.monotonic()
    deadline = started + args.duration if args.duration else None
    ready_written = False
    pending = b""
    with raw_path.open("wb") as raw:
        while not stop["flag"]:
            if deadline is not None and time.monotonic() >= deadline:
                break
            sock.settimeout(0.25)
            try:
                chunk = sock.recv(1 << 16)
            except socket.timeout:
                continue
            except OSError:
                break
            if not chunk:
                break
            raw.write(chunk)
            chunks.append([round(time.monotonic() - started, 4), len(chunk)])
            if not ready_written and args.ready_file:
                pending += chunk
                if b'"id"' in pending and b"\n" in pending:
                    for line in pending.split(b"\n"):
                        try:
                            if json.loads(line).get("id") == 1:
                                pathlib.Path(args.ready_file).touch()
                                ready_written = True
                                pending = b""
                                break
                        except (json.JSONDecodeError, UnicodeDecodeError, AttributeError):
                            continue
    sock.close()
    meta = {
        "socket": args.socket,
        "pane": args.pane,
        "durationSeconds": round(time.monotonic() - started, 3),
        "chunks": chunks,
    }
    pathlib.Path(args.out + ".meta.json").write_text(json.dumps(meta))


def payload_bytes(record):
    """Decoded PTY/state bytes one record carries, or 0."""
    b64 = record.get("base64") or record.get("event", {}).get("base64")
    return len(base64.b64decode(b64)) if b64 else 0


def base64_chars(record):
    b64 = record.get("base64") or record.get("event", {}).get("base64")
    return len(b64) if b64 else 0


def deflate_whole(data):
    compressor = zlib.compressobj(6, zlib.DEFLATED, -15)
    return len(compressor.compress(data) + compressor.flush())


def deflate_per_record(lines):
    """One shared-window deflate context, sync-flushed after every record, the
    way a compressed interactive wire must flush to preserve latency."""
    compressor = zlib.compressobj(6, zlib.DEFLATED, -15)
    total = 0
    for line in lines:
        total += len(compressor.compress(line + b"\n"))
        total += len(compressor.flush(zlib.Z_SYNC_FLUSH))
    return total


def segment_summary(lines, records):
    wire = sum(len(line) + 1 for line in lines)
    b64 = sum(base64_chars(record) for record in records)
    kinds = {}
    event_types = {}
    payload = {"feed": 0, "write": 0, "sync": 0, "other": 0}
    payload_stream = bytearray()
    for record in records:
        kind = record.get("kind", "?")
        kinds[kind] = kinds.get(kind, 0) + 1
        decoded = payload_bytes(record)
        if kind == "event":
            event_type = record.get("event", {}).get("type", "?")
            event_types[event_type] = event_types.get(event_type, 0) + 1
            bucket = event_type if event_type in ("feed", "write") else "other"
            payload[bucket] += decoded
        elif kind == "sync":
            payload["sync"] += decoded
        else:
            payload["other"] += decoded
        b64_text = record.get("base64") or record.get("event", {}).get("base64")
        if b64_text:
            payload_stream += base64.b64decode(b64_text)
    total_payload = sum(payload.values())
    return {
        "records": len(records),
        "wireBytes": wire,
        "recordKinds": kinds,
        "eventTypes": event_types,
        "payloadBytes": payload,
        "payloadBytesTotal": total_payload,
        "base64Chars": b64,
        "envelopeBytes": wire - b64,
        "wirePerPayloadByte": round(wire / total_payload, 2) if total_payload else None,
        "deflateWholeBytes": deflate_whole(b"\n".join(lines) + b"\n") if lines else 0,
        "deflatePerRecordBytes": deflate_per_record(lines),
        "deflatePayloadOnlyBytes": deflate_whole(bytes(payload_stream)) if payload_stream else 0,
    }


def analyze_one(prefix):
    raw = pathlib.Path(prefix + ".raw").read_bytes()
    meta = json.loads(pathlib.Path(prefix + ".meta.json").read_text())
    lines = [line for line in raw.split(b"\n") if line]
    parsed = []
    for line in lines:
        message = json.loads(line)
        if "result" in message:
            record = message["result"]
        elif message.get("method") == "pane.tape.event":
            record = message["params"]["record"]
        else:
            record = {"kind": f"rpc:{message.get('method', '?')}"}
        parsed.append((line, record))

    # The join prefix is everything up to the first live record: hello, the
    # start reply, and the sync/gap records the from-now join owes. The steady
    # segment is the stream the session then pays for as it runs.
    first_live = next(
        (i for i, (_, record) in enumerate(parsed) if record.get("kind") in ("event", "end")),
        len(parsed),
    )
    join = parsed[:first_live]
    steady = parsed[first_live:]

    # Chunk timestamps place the steady segment in time, so its rate uses the
    # span its own bytes occupied rather than the whole capture.
    offsets = []
    position = 0
    for t, n in meta["chunks"]:
        offsets.append((position, position + n, t))
        position += n
    steady_start_offset = sum(len(line) + 1 for line, _ in join)

    def time_at(offset):
        for begin, end, t in offsets:
            if begin <= offset < end:
                return t
        return meta["durationSeconds"]

    steady_summary = segment_summary([l for l, _ in steady], [r for _, r in steady])
    steady_span = round(meta["durationSeconds"] - time_at(steady_start_offset), 3) if steady else 0
    return {
        "prefix": prefix,
        "captureSeconds": meta["durationSeconds"],
        "totalWireBytes": len(raw),
        "join": segment_summary([l for l, _ in join], [r for _, r in join]),
        "steady": steady_summary,
        "steadySpanSeconds": steady_span,
        "steadyWireBytesPerSecond": round(steady_summary["wireBytes"] / steady_span, 1)
        if steady_span
        else None,
    }


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    cap = commands.add_parser("capture")
    cap.add_argument("socket")
    cap.add_argument("pane")
    cap.add_argument("--out", required=True)
    cap.add_argument("--duration", type=float, default=0)
    cap.add_argument("--ready-file")
    ana = commands.add_parser("analyze")
    ana.add_argument("prefixes", nargs="+")
    args = parser.parse_args()
    if args.command == "capture":
        capture(args)
    else:
        for prefix in args.prefixes:
            json.dump(analyze_one(prefix), sys.stdout, indent=2)
            sys.stdout.write("\n")


if __name__ == "__main__":
    main()
