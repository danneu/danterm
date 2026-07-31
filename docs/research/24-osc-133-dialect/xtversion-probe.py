#!/usr/bin/env python3
"""Ask a real fish what it concludes from DanTerm's actual XTVERSION reply.

Runs interactive fish (config loaded -- NOT `-N`, which was the F6 artifact)
over a real PTY, answers the startup capability handshake with a caller-chosen
XTVERSION identity, then asks fish to report `status terminal` and the value its
auto-detection picked for `fish_handle_reflow`.
"""
import os, pty, sys, time, select, fcntl, termios, struct, re, json

def set_size(fd, cols=80, rows=24):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

def run(xtversion_reply, term="xterm-256color", extra_env=None):
    """Return (status_terminal, fish_handle_reflow) as fish reports them."""
    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ)
        env["TERM"] = term
        env["XDG_CONFIG_HOME"] = "/nonexistent-danterm-probe"
        env.pop("VTE_VERSION", None)
        env.pop("KONSOLE_VERSION", None)
        if extra_env:
            env.update(extra_env)
        os.execve("/etc/profiles/per-user/dan/bin/fish",
                  ["fish", "-i"], env)
    set_size(fd)

    def respond(data):
        r = b""
        if re.search(rb"\x1b\]11;\?(\x07|\x1b\\)", data):
            r += b"\x1b]11;rgb:0000/0000/0000\x1b\\"
        if re.search(rb"\x1b\[>0?q", data):
            r += xtversion_reply
        if re.search(rb"\x1b\[\?u", data):
            r += b"\x1b[?0u"
        if re.search(rb"\x1b\[(0)?c", data):
            r += b"\x1b[?62;22c"
        for _ in re.findall(rb"\x1b\[6n", data):
            r += b"\x1b[1;1R"
        if r:
            os.write(fd, r)

    def drain(seconds):
        out = b""
        deadline = time.time() + seconds
        while time.time() < deadline:
            sel, _, _ = select.select([fd], [], [], 0.05)
            if not sel:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            respond(chunk)
        return out

    drain(1.5)
    # Markers bracket the answer so prompt/echo noise can't be mistaken for it.
    os.write(fd, b'echo "ZZ|$(status terminal)|$fish_handle_reflow|ZZ"\n')
    out = drain(1.5)
    os.write(fd, b"exit\n")
    drain(0.4)
    try:
        os.close(fd)
    except OSError:
        pass
    os.waitpid(pid, 0)

    text = out.decode("utf-8", "replace")
    # The command line itself echoes; take the last match, which is the output.
    hits = re.findall(r"ZZ\|([^|]*)\|([^|]*)\|ZZ", text)
    hits = [h for h in hits if "status terminal" not in h[0]]
    return hits[-1] if hits else ("<no answer>", "<no answer>")

CASES = [
    ("DanTerm real reply",      b"\x1bP>|DanTerm 0.1.0\x1b\\", "xterm-256color"),
    ("F8 synthetic",            b"\x1bP>|DanTerm(1.0)\x1b\\",  "xterm-256color"),
    ("no XTVERSION reply",      b"",                            "xterm-256color"),
    ("control: WezTerm",        b"\x1bP>|WezTerm 20240203\x1b\\", "xterm-256color"),
    ("control: TERM=alacritty", b"\x1bP>|DanTerm 0.1.0\x1b\\", "alacritty"),
]

if __name__ == "__main__":
    print(f"{'case':28} {'status terminal':24} fish_handle_reflow")
    print("-" * 72)
    for name, reply, term in CASES:
        st, rf = run(reply, term=term)
        print(f"{name:28} {st!r:24} {rf!r}")
