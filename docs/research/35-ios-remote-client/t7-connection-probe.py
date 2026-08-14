#!/usr/bin/env python3
"""F8's reproduction: idle connections starve DanTerm's IPC reader threads.

Every accepted connection parks one libdispatch worker in a blocking read for
its whole life (`IpcConnection.startReading`), so a peer that opens connections
and sends nothing exhausts the pool. Past the bound the app still accepts, but
never reads: a new caller waits forever while an already-established
conversation keeps answering.

    python3 t7-connection-probe.py <control-socket> <idle-connections>

Run it against a throwaway `just launch-slot` instance, never the user's app.
"""
import json
import socket
import sys
import time


def ask(sock, rpc_id):
    """Issues one `ls` and returns (reply-or-None, seconds waited)."""
    start = time.monotonic()
    sock.sendall(json.dumps({"jsonrpc": "2.0", "id": rpc_id, "method": "ls"}).encode() + b"\n")
    buf = b""
    try:
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                return None, time.monotonic() - start
            buf += chunk
            lines = buf.split(b"\n")
            buf = lines.pop()
            for line in lines:
                if not line:
                    continue
                message = json.loads(line)
                if message.get("id") == rpc_id:
                    return message, time.monotonic() - start
    except socket.timeout:
        return None, time.monotonic() - start


def connect(path, timeout=15):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(path)
    return sock


def verdict(reply, elapsed):
    state = "ok" if reply and "result" in reply else "FAILED"
    return f"{state} in {elapsed * 1000:.1f}ms"


def main():
    path, count = sys.argv[1], int(sys.argv[2])

    established = connect(path)
    reply, elapsed = ask(established, 1)
    print(f"before the flood, new connection:      {verdict(reply, elapsed)}")

    held = [connect(path, timeout=5) for _ in range(count)]
    print(f"held {len(held)} idle connections that send nothing")

    reply, elapsed = ask(established, 2)
    print(f"during the flood, established:         {verdict(reply, elapsed)}")

    fresh = connect(path)
    reply, elapsed = ask(fresh, 3)
    print(f"during the flood, new connection:      {verdict(reply, elapsed)}")

    for sock in held:
        sock.close()
    reply, elapsed = ask(connect(path), 4)
    print(f"after the flood drains, new connection: {verdict(reply, elapsed)}")

    established.close()
    fresh.close()


if __name__ == "__main__":
    main()
