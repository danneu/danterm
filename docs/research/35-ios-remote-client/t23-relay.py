#!/usr/bin/env python3
"""Throwaway TCP relay for the T23 on-device smoke: one TCP connection in, one
control-socket connection out, bytes spliced both ways.

This is spike scaffolding, not the T5 bridge. It exists only because a phone
cannot reach an AF_UNIX socket, and it is deliberately dumb: no framing, no
buffering policy, no session state, no resume. T5 owns the bridge and T6 owns
the real auth model, and a spike that pre-decided either would be worse than no
spike.

Authentication, as the research doc's investigation rules require of anything
that opens a listener. There is no tailnet on this machine, so the doc's
"bound to the tailnet interface" branch is unavailable and this takes the
authenticated branch instead: the listener binds one explicit LAN address (never
0.0.0.0, and the script refuses that address), and a connection must send
`token <secret>\n` as its very first line before a single byte reaches the
control socket. A wrong or missing token closes the connection with no reply and
nothing proxied. The token is a shared secret passed on the command line, which
is exactly the strength this smoke needs and no more -- it stops a stray host on
the same LAN from driving the user's terminal, and it decides nothing about how
the bridge will authenticate.

Usage: t23-relay.py --listen <addr>:<port> --socket <control.sock> --token <secret>
"""
import argparse
import socket
import sys
import threading

TOKEN_PREFIX = b"token "
# A client that connects and says nothing must not hold a thread forever.
HANDSHAKE_TIMEOUT_SECONDS = 10.0
# Long enough that the first line cannot be split across a plausible read, short
# enough that a peer cannot make us buffer without bound before authenticating.
MAX_HANDSHAKE_BYTES = 512


def log(message):
    print(f"relay: {message}", flush=True)


def read_token_line(client):
    """Reads the first line, bounded, before anything is proxied. Returns the
    token bytes, or None if the peer failed to send a well-formed first line."""
    buffer = b""
    while b"\n" not in buffer:
        if len(buffer) > MAX_HANDSHAKE_BYTES:
            return None
        try:
            chunk = client.recv(MAX_HANDSHAKE_BYTES)
        except OSError:
            return None
        if not chunk:
            return None
        buffer += chunk
    line, _, rest = buffer.partition(b"\n")
    # Anything after the token line is protocol traffic the peer pipelined; it is
    # returned so the splice does not lose it.
    if not line.startswith(TOKEN_PREFIX):
        return None
    return line[len(TOKEN_PREFIX):].strip(), rest


def splice(source, sink, name):
    try:
        while True:
            chunk = source.recv(65536)
            if not chunk:
                break
            sink.sendall(chunk)
    except OSError:
        pass
    finally:
        # Half-close so the other direction can still drain rather than dying
        # mid-record.
        try:
            sink.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        log(f"{name} closed")


def serve_client(client, address, socket_path, token):
    client.settimeout(HANDSHAKE_TIMEOUT_SECONDS)
    result = read_token_line(client)
    if result is None or result[0] != token:
        log(f"{address} refused: bad or missing token")
        client.close()
        return
    _, pipelined = result
    client.settimeout(None)
    log(f"{address} authenticated")
    upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        upstream.connect(socket_path)
    except OSError as error:
        log(f"{address} upstream connect failed: {error}")
        client.close()
        return
    if pipelined:
        upstream.sendall(pipelined)
    threading.Thread(
        target=splice, args=(client, upstream, f"{address} ->"), daemon=True
    ).start()
    splice(upstream, client, f"{address} <-")
    client.close()
    upstream.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", required=True, help="addr:port, never 0.0.0.0")
    parser.add_argument("--socket", required=True)
    parser.add_argument("--token", required=True)
    options = parser.parse_args()

    address, _, port = options.listen.rpartition(":")
    if address in ("", "0.0.0.0", "::"):
        sys.exit("relay: --listen needs one explicit interface address")
    if not options.token:
        sys.exit("relay: --token must not be empty")

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((address, int(port)))
    listener.listen(4)
    log(f"listening on {address}:{port} -> {options.socket} (token required)")
    token = options.token.encode()
    while True:
        client, peer = listener.accept()
        threading.Thread(
            target=serve_client,
            args=(client, f"{peer[0]}:{peer[1]}", options.socket, token),
            daemon=True,
        ).start()


if __name__ == "__main__":
    main()
