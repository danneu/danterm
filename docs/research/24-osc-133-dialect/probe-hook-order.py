#!/usr/bin/env python3
"""Probe defenses against a prompt framework that hooks after DanTerm (F15).

F14 stage 3 left one hazard open: when a framework's `precmd` is registered
*after* DanTerm's, the framework's PS1 rebuild wins and the dialect goes silent
-- 0 marks, no diagnostic. This measures the candidate defenses, and asks the
same question of Bash's PROMPT_COMMAND, which D2 depends on and F14 never
probed.

Two stages, each a real `pty.fork()` shell:

  zsh-defense -- a synthetic framework that rebuilds PS1 every precmd, its hook
                 registered AFTER ours, crossed with four defenses.
  bash-order  -- real Starship (whose bash init rebuilds PS1 every prompt,
                 unlike its zsh init) crossed with three emitter strategies and
                 both source orders.

Mechanics from zsh source, which pick the candidates:
  - `Src/utils.c#callhookfunc` copies the hook array before iterating, so
    re-ordering `precmd_functions` from inside a hook takes effect next cycle,
    never this one.
  - `Src/Zle/zle_main.c#zleread` expands the prompt before `zle-line-init`
    runs, but `reset-prompt` re-expands from the live PS1 slot -- so a
    zle-line-init wrap only lands if it also resets.

Expected at commit 2f13e0b (see F15 for the reading). Marks per prompt; 2 is
correct for zsh, and for bash 1 means `A` survived but the PS1 stamp did not:

  zsh-defense  guarded      + hostile -> 0 everywhere
  zsh-defense  retail       + hostile -> 0 at startup, 2 per cycle after
  zsh-defense  retail+heal  + anything -> 2 at startup and per cycle
  bash-order   ps1-assign   -> 1, in BOTH source orders (Starship rebuilds PS1)
  bash-order   *-guarded    -> 1 ours-first, 4 ours-last
  bash-order   *-retail     -> 1 at startup, then 5 (the doubled `A` is inert)

Usage: probe-hook-order.py [zsh-defense|bash-order|all]
"""
import os, pty, time, select, fcntl, termios, struct, re, sys, tempfile

REPO = "/Users/dan/Code/danterm-terminal-engine"
ZSH = "/etc/profiles/per-user/dan/bin/zsh"
BASH = "/etc/profiles/per-user/dan/bin/bash"
STARSHIP = "/etc/profiles/per-user/dan/bin/starship"
COLS, ROWS = 100, 12

# --- zsh --------------------------------------------------------------------

# A framework that rebuilds PS1 from scratch on every precmd (F14's HOSTILE).
ZSH_HOSTILE = r"""
_fw_n=0
_fw_rebuild() { _fw_n=$((_fw_n+1)); PS1="FW${_fw_n}%% " }
autoload -Uz add-zsh-hook; add-zsh-hook precmd _fw_rebuild
"""

# The guarded wrap body shared by every defense: rebuild from a pristine copy,
# re-capturing whenever a third party changed PS1 underneath us (D1 as amended
# by F14).
ZSH_WRAP = r"""
typeset -g _dt_pristine= _dt_last=
_dt_body() {
  [[ -n "$_dt_last" && "$PS1" == "$_dt_last" ]] || _dt_pristine=$PS1
  PS1=$'%{\e]133;A;redraw=1\a%}ZZMARKZZ'$_dt_pristine$'%{\e]133;B\a%}'
  _dt_last=$PS1
}
"""

ZSH_DEFENSES = {
    # (a) F14's control: a plain precmd hook, registered first, framework second.
    "guarded": ZSH_WRAP + r"""
_dt_wrap() { _dt_body }
autoload -Uz add-zsh-hook; add-zsh-hook precmd _dt_wrap
""",
    # (b) move ourselves to the tail of precmd_functions on every run. Source
    #     says the array is snapshotted, so this can only pay off from cycle 2.
    "retail": ZSH_WRAP + r"""
_dt_wrap() {
  precmd_functions=("${(@)precmd_functions:#_dt_wrap}" _dt_wrap)
  _dt_body
}
autoload -Uz add-zsh-hook; add-zsh-hook precmd _dt_wrap
""",
    # (c) wrap from zle-line-init, which runs after every precmd hook, and
    #     re-expand the prompt so the assignment is actually used.
    "zle-init-reset": ZSH_WRAP + r"""
_dt_zle() { _dt_body; zle reset-prompt }
zle -N zle-line-init _dt_zle
""",
    # (d) the same without the reset -- a discriminator for the claim above,
    #     not a candidate.
    "zle-init-noreset": ZSH_WRAP + r"""
_dt_zle() { _dt_body }
zle -N zle-line-init _dt_zle
""",
    # (e) (b) plus a self-healing zle-line-init that repaints only when it
    #     finds PS1 unmarked -- which, once (b) has re-tailed itself, is only
    #     the very first prompt.
    "retail+heal": ZSH_WRAP + r"""
_dt_wrap() {
  precmd_functions=("${(@)precmd_functions:#_dt_wrap}" _dt_wrap)
  _dt_body
}
autoload -Uz add-zsh-hook; add-zsh-hook precmd _dt_wrap
_dt_zle() {
  [[ $PS1 == *$'\e]133;A'* ]] || { _dt_body; zle reset-prompt }
}
zle -N zle-line-init _dt_zle
""",
}

# --- bash -------------------------------------------------------------------

# D2's shape: A printed from the precmd hook, P/B embedded in PS1 inside \[..\].
BASH_A = r"""printf '\033]133;A;redraw=last\007'"""
BASH_OPEN = r"""\[\033]133;P;k=i\007\]ZZMARKZZ"""
BASH_CLOSE = r"""\[\033]133;B\007\]"""

BASH_EMITTERS = {
    # (a) D2 read literally: wrap PS1 once, at source time.
    "ps1-assign": r"""
PS1='{open}'"$PS1"'{close}'
_dt_pc() {{ {a}; }}
PROMPT_COMMAND="${{PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}}_dt_pc"
""",
    # (b) re-wrap whatever PS1 is now, every prompt, with no guard.
    "promptcmd-naive": r"""
_dt_pc() {{ {a}; PS1='{open}'"$PS1"'{close}'; }}
PROMPT_COMMAND="${{PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}}_dt_pc"
""",
    # (c) guarded: rebuild from a pristine copy, re-capture when a third party
    #     changed PS1 underneath us (the zsh defense, ported).
    "promptcmd-guarded": r"""
_dt_pristine=; _dt_last=
_dt_pc() {{
  {a}
  [[ -n "$_dt_last" && "$PS1" == "$_dt_last" ]] || _dt_pristine=$PS1
  PS1='{open}'"$_dt_pristine"'{close}'
  _dt_last=$PS1
}}
PROMPT_COMMAND="${{PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}}_dt_pc"
""",
    # (d) (c) plus the bash analogue of zsh's re-tail: re-append ourselves to
    #     the end of PROMPT_COMMAND on every run. Starship swallows a
    #     pre-existing PROMPT_COMMAND into STARSHIP_PROMPT_COMMAND and runs it
    #     BEFORE its own PS1 assignment, so this makes us run twice per prompt:
    #     the guarded wrap is idempotent, but `A` is printed twice.
    "promptcmd-retail": r"""
_dt_pristine=; _dt_last=
_dt_retail() {{
  if [[ ${{PROMPT_COMMAND@a}} == *a* ]]; then
    local -a keep=(); local e
    for e in "${{PROMPT_COMMAND[@]}}"; do [[ $e == _dt_pc ]] || keep+=("$e"); done
    PROMPT_COMMAND=("${{keep[@]}}" _dt_pc)
  else
    [[ $PROMPT_COMMAND == *_dt_pc ]] ||
      PROMPT_COMMAND="${{PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}}_dt_pc"
  fi
}}
_dt_pc() {{
  {a}
  [[ -n "$_dt_last" && "$PS1" == "$_dt_last" ]] || _dt_pristine=$PS1
  PS1='{open}'"$_dt_pristine"'{close}'
  _dt_last=$PS1
  _dt_retail
}}
PROMPT_COMMAND="${{PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}}_dt_pc"
""",
}

RC_ZSH = """
autoload -Uz add-zsh-hook
PS1='%% '
{first}
{second}
"""

RC_BASH = """
PS1='bash$ '
{first}
{second}
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


def spawn(path, argv, rcdir=None):
    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        if rcdir:
            env["ZDOTDIR"] = rcdir
        # The dialect is not shipped yet; strip DanTerm's own triggers so we
        # measure only what this probe installs.
        for k in ("DANTERM", "DANTERM_TOKEN", "LC_DANTERM_TOKEN"):
            env.pop(k, None)
        os.chdir(REPO)
        os.execve(path, argv, env)
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


def run_cycles(pid, fd, n=4, settle=1.2):
    """Four `true` commands, then a SIGWINCH. Returns per-cycle mark counts,
    the marks seen on the resize repaint, and the last prompt's bytes."""
    cycles = []
    last = b""
    for _ in range(n):
        os.write(fd, b"true\n")
        out = drain(fd, settle)
        cycles.append(len(marks(out)))
        last = out
    set_size(fd, 80)
    time.sleep(0.15)
    repaint = drain(fd, 1.0)
    return cycles, len(marks(repaint)), last


def stage_zsh_defense():
    print("\n== zsh-defense: framework's precmd registered AFTER ours")
    print("   (startup = the FIRST prompt, drawn before any hook can re-order itself)")
    frameworks = {
        "none": "",
        "hostile": ZSH_HOSTILE,
        "starship": f'eval "$({STARSHIP} init zsh)"',
    }
    for name, defense in ZSH_DEFENSES.items():
        for fw, body in frameworks.items():
            d = tempfile.mkdtemp()
            with open(os.path.join(d, ".zshrc"), "w") as f:
                f.write(RC_ZSH.format(first=defense, second=body))
            pid, fd = spawn(ZSH, ["zsh", "-i"], rcdir=d)
            startup = drain(fd, 2.5)
            cycles, winch, last = run_cycles(pid, fd)
            finish(pid, fd)
            intact = "n/a" if fw != "starship" else (
                "yes" if b"repo:" in last else "no ")
            print(f"   {name:17s} fw={fw:8s} | "
                  f"startup={len(marks(startup)):2d} per-cycle={cycles} "
                  f"SIGWINCH={winch:2d} markers={last.count(b'ZZMARKZZ')} "
                  f"prompt-intact={intact}")
            if fw == "hostile":
                print(f"   {'':17s}             | last prompt: {last[-90:]!r}")


def stage_bash_order():
    print("\n== bash-order: Starship's bash init rebuilds PS1 every prompt")
    init = f'eval "$({STARSHIP} init bash)"'
    for emitter, tmpl in BASH_EMITTERS.items():
        body = tmpl.format(a=BASH_A, open=BASH_OPEN, close=BASH_CLOSE)
        for order in ("ours-first", "ours-last"):
            first, second = (body, init) if order == "ours-first" else (init, body)
            fh = tempfile.NamedTemporaryFile("w", suffix=".bashrc", delete=False)
            fh.write(RC_BASH.format(first=first, second=second))
            fh.close()
            pid, fd = spawn(BASH, ["bash", "--rcfile", fh.name, "-i"])
            startup = drain(fd, 3.0)
            cycles, winch, last = run_cycles(pid, fd)
            finish(pid, fd)
            intact = "yes" if b"danterm-terminal-engine" in last else "no "
            print(f"   {emitter:18s} {order:10s} | startup={len(marks(startup)):2d} "
                  f"per-cycle={cycles} SIGWINCH={winch:2d} "
                  f"markers={last.count(b'ZZMARKZZ')} prompt-intact={intact}")


if __name__ == "__main__":
    stage = sys.argv[1] if len(sys.argv) > 1 else "all"
    if stage in ("zsh-defense", "all"):
        stage_zsh_defense()
    if stage in ("bash-order", "all"):
        stage_bash_order()
