#!/usr/bin/env python3
"""Probe how a real zsh prompt framework interacts with marks in PS1 (F14).

D1 embeds the dialect's marks in `PS1`, and flagged one risk: "a prompt
framework that rebuilds `PS1` asynchronously drops the marks". This probes that
against the framework actually installed here (Starship 1.25.1, zsh 5.9.1) plus
a synthetic framework that really does rebuild `PS1` every precmd, which
Starship turns out not to do.

Three stages, each a real `pty.fork()` zsh:

  native    -- the user's own ~/.zshrc, untouched: what does the stack emit on
               its own, and does its prompt occupy the full pane width?
  order     -- a synthetic ZDOTDIR that sources the "integration" BEFORE the
               framework's init, which is the order the real ~/.zshrc uses,
               crossed with three emitter strategies.
  hostile   -- a framework that rebuilds PS1 on every precmd, with its hook
               registered before and after the emitter's.

Expected at commit 1eff9b7 (see F14 for the reading):

  order   ps1-assign     + starship -> 0 marks   (framework's init wins)
  order   precmd-naive   + starship -> grows 2 per prompt cycle, unbounded
  order   precmd-guarded + starship -> stable 2, prompt intact
  hostile hostile-then-ours -> stable 2; ours-then-hostile -> 0

Usage: probe-zsh-prompt-frameworks.py [native|order|hostile|all]
"""
import os, pty, time, select, fcntl, termios, struct, re, sys, tempfile

REPO = "/Users/dan/Code/danterm-terminal-engine"
ZSH = "/etc/profiles/per-user/dan/bin/zsh"
STARSHIP = "/etc/profiles/per-user/dan/bin/starship"
COLS, ROWS = 100, 12

# The three candidate emitters, written as an integration would ship them.
EMITTERS = {
    # (a) D1 as literally written: assign PS1 at source time.
    "ps1-assign": r"""
PS1=$'%{\e]133;A;redraw=1\a%}ZZMARKZZ'$PS1$'%{\e]133;B\a%}'
""",
    # (b) precmd hook that wraps whatever PS1 exists, with no guard.
    "precmd-naive": r"""
_dt_wrap() { PS1=$'%{\e]133;A;redraw=1\a%}ZZMARKZZ'$PS1$'%{\e]133;B\a%}' }
autoload -Uz add-zsh-hook; add-zsh-hook precmd _dt_wrap
""",
    # (c) precmd hook that rebuilds from a pristine copy captured on first run
    #     and re-captures whenever a third party changed PS1 underneath it.
    "precmd-guarded": r"""
typeset -g _dt_pristine= _dt_last=
_dt_wrap() {
  [[ -n "$_dt_last" && "$PS1" == "$_dt_last" ]] || _dt_pristine=$PS1
  PS1=$'%{\e]133;A;redraw=1\a%}ZZMARKZZ'$_dt_pristine$'%{\e]133;B\a%}'
  _dt_last=$PS1
}
autoload -Uz add-zsh-hook; add-zsh-hook precmd _dt_wrap
""",
}

# A framework that rebuilds PS1 from scratch on every precmd -- the shape D1
# feared. Starship-zsh is not this; Powerlevel10k's reload path is closer.
HOSTILE = r"""
_fw_n=0
_fw_rebuild() { _fw_n=$((_fw_n+1)); PS1="FW${_fw_n}%% " }
autoload -Uz add-zsh-hook; add-zsh-hook precmd _fw_rebuild
"""

RC_TEMPLATE = """
autoload -Uz add-zsh-hook
PS1='%% '
# --- the integration is sourced HERE, before the prompt framework ---
{emitter}
# --- prompt framework init, where the real ~/.zshrc has it (last) ---
{framework}
"""


def set_size(fd, cols, rows=ROWS):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def respond(fd, data):
    """Answer the queries a real terminal would, so the shell's startup
    negotiation completes instead of blocking on a timeout."""
    r = b""
    if re.search(rb"\x1b\]11;\?(\x07|\x1b\\)", data):
        r += b"\x1b]11;rgb:0000/0000/0000\x1b\\"
    if re.search(rb"\x1b\[>0?q", data):
        r += b"\x1bP>|DanTerm 0.1.0\x1b\\"
    if re.search(rb"\x1b\[\?u", data):
        r += b"\x1b[?0u"
    if re.search(rb"\x1b\[(0)?c", data):
        r += b"\x1b[?62;22c"
    for _ in re.findall(rb"\x1b\[6n", data):
        r += b"\x1b[1;1R"
    if r:
        os.write(fd, r)


def drain(fd, seconds):
    out, deadline = b"", time.time() + seconds
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
        respond(fd, chunk)
    return out


def marks(data):
    return re.findall(rb"\x1b\]133;([^\x07\x1b]*)(?:\x07|\x1b\\)", data)


def spawn(zdotdir=None):
    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        if zdotdir:
            env["ZDOTDIR"] = zdotdir
        # Strip DanTerm's own integration triggers: the dialect is not shipped
        # yet, and we are measuring the framework alone.
        for k in ("DANTERM", "DANTERM_TOKEN", "LC_DANTERM_TOKEN"):
            env.pop(k, None)
        os.chdir(REPO)
        os.execve(ZSH, ["zsh", "-i"], env)
    set_size(fd, COLS)
    return pid, fd


def finish(pid, fd):
    os.write(fd, b"exit\n")
    drain(fd, 0.4)
    try:
        os.close(fd)
    except OSError:
        pass
    os.waitpid(pid, 0)


def stage_native():
    print("\n== native: the user's own ~/.zshrc, no integration")
    pid, fd = spawn()
    startup = drain(fd, 4.0)
    set_size(fd, 80)
    time.sleep(0.15)
    repaint = drain(fd, 1.0)
    finish(pid, fd)
    print(f"   startup OSC 133 marks : {marks(startup) or 'NONE'}")
    print(f"   repaint OSC 133 marks : {marks(repaint) or 'NONE'}")
    print(f"   repaint bytes         : {repaint[:220]!r}")


def stage_order():
    print("\n== order: integration sourced before the framework's init")
    for emitter in EMITTERS:
        for with_framework in (False, True):
            framework = f'eval "$({STARSHIP} init zsh)"' if with_framework else ""
            d = tempfile.mkdtemp()
            with open(os.path.join(d, ".zshrc"), "w") as f:
                f.write(RC_TEMPLATE.format(emitter=EMITTERS[emitter], framework=framework))
            pid, fd = spawn(d)
            startup = drain(fd, 3.0)
            cycles = []
            for _ in range(4):
                os.write(fd, b"true\n")
                cycles.append(len(marks(drain(fd, 1.2))))
            set_size(fd, 80)
            time.sleep(0.15)
            repaint = drain(fd, 1.0)
            finish(pid, fd)
            intact = "yes" if (b"repo:" in startup or b"repo:" in repaint) else "no "
            print(f"   {emitter:15s} framework={'starship' if with_framework else 'none    '} "
                  f"| startup={len(marks(startup)):2d} per-cycle={cycles} "
                  f"SIGWINCH={len(marks(repaint)):2d} "
                  f"| prompt intact={intact if with_framework else 'n/a'}")


def stage_hostile():
    print("\n== hostile: a framework that rebuilds PS1 every precmd")
    for name, body in (("hostile-then-ours", HOSTILE + EMITTERS["precmd-guarded"]),
                       ("ours-then-hostile", EMITTERS["precmd-guarded"] + HOSTILE)):
        d = tempfile.mkdtemp()
        with open(os.path.join(d, ".zshrc"), "w") as f:
            f.write("autoload -Uz add-zsh-hook\nPS1='%% '\n" + body)
        pid, fd = spawn(d)
        drain(fd, 2.0)
        cycles = []
        for _ in range(4):
            os.write(fd, b"true\n")
            cycles.append(len(marks(drain(fd, 1.0))))
        set_size(fd, 80)
        time.sleep(0.15)
        repaint = drain(fd, 1.0)
        finish(pid, fd)
        print(f"   {name:20s} | per-cycle={cycles} SIGWINCH={len(marks(repaint)):2d}")
        print(f"   {'':20s} | last repaint: {repaint[-80:]!r}")


if __name__ == "__main__":
    stage = sys.argv[1] if len(sys.argv) > 1 else "all"
    if stage in ("native", "all"):
        stage_native()
    if stage in ("order", "all"):
        stage_order()
    if stage in ("hostile", "all"):
        stage_hostile()
