#!/usr/bin/env python3
"""Enforces that `just test` reaches every declared first-party test estate.

A package's own `Package.swift` is the claim that its tests exist; the gate's step
list is the claim that they run. Nothing tied the two together, and the gap was
real: `lib/DanTermClient` declares `DanTermClientTests` and no gate step ever named
that package, so the newest module in the tree was the one module whose own package
was never tested.

What counts as a lane, and why the definition is this strict:

  * A lane is a `swift test` that names the package. A step that only *builds* the
    package -- `scripts/ios-portability-gate.sh` cross-compiles every pinned
    manifest -- is a mention, not a lane, and leaves the test estate unrun.
  * One level of script indirection counts. The gate reaches `lib/TerminalPTY`
    through `scripts/test-terminal-pty.sh`, so a shell wrapper named by a step is
    read the same way the step list is. Only `scripts/*.sh` wrappers are followed;
    a wrapper written in another language would have to name its package in the
    step string instead.
  * A lane carrying `--filter` or `--skip` runs a subset, so one such lane on its
    own leaves the rest of the estate unrun. Subset lanes count only when they
    partition the estate: a `--skip X` lane beside a `--filter X` lane, which is
    exactly the shape `scripts/test-terminal-pty.sh` uses to give its fd census a
    process to itself.
  * Two unrestricted lanes over one package fail for the opposite reason -- the
    estate runs twice, and the gate pays for it twice.
  * A test target that declares it needs a WindowServer connection is the one kind
    that must NOT run: the gate is headless. Its package's lane has to `--skip` it
    by name, so the exclusion is visible in the step list rather than implied by a
    lane that happens not to reach it. The declaration lives in the manifest that
    owns the target, so this check keeps no list of excluded names.

Tracked shell and Python self-tests make the same coverage claim as a manifest. A
matching `*_test.sh` or `*_test.py` must occur as a command word in the assembled
gate, or as the script operand of an interpreter command. A path in a comment,
string, or ordinary argument does not run the test and does not count. A test that
cannot run headlessly carries `# gate: opt-out -- <reason>` in its own file.

The rule checks themselves make the same claim, and it is the symmetric half: a
self-test that runs proves only that the lint works, never that the gate points it
at the tree. So every tracked `*-lint` and `*-gate` script is read the same way as a
self-test -- command word, interpreter operand, or an opt-out in its own file --
which makes "this lint exists" and "this lint runs" one fact. One indirection
counts: a script `exec`'d by a covered same-stem wrapper is covered, because the
wrapper names it through `$SCRIPT_DIR` and no literal path in the step list can.
`scripts/lib` is excluded: what lives there is sourced by a lint, not run as one.

The rule is keyed on the name a rule check carries, so a check named something else
is invisible to it. The structure that would close that for good is derivation --
the gate's lint list assembled from the tree instead of written by hand -- but the
step list carries two facts a filename cannot: the arguments a step passes, and
whether the step belongs to the `just lint` subset or the full gate. Derivation
therefore needs a declaration inside each file, and a file that forgets the
declaration is unwired again. This check is the half that catches that, in either
world.

The manifest check reads text only; it never imports or executes a manifest. A
`path:` that is not a string literal is therefore rejected rather than guessed at,
so a computed path fails loudly instead of slipping past.
"""

from __future__ import annotations

import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from manifest_targets import (  # noqa: E402
    DISPLAY_BOUND_DEFINE,
    LintError,
    balanced_span,
    declared_targets,
    first_party_manifests,
)

# Test seam: the self-test points the check at a fixture tree of tiny manifests and a
# synthetic step list, so it can prove each verdict without running the real gate.
# Nothing else sets this.
REPO_ROOT = Path(
    os.environ.get("GATE_TEST_COVERAGE_LINT_ROOT")
    or Path(__file__).resolve().parent.parent
).resolve()

UNRESOLVED = "<unresolved>"


@dataclass(frozen=True)
class Lane:
    """One `swift test` invocation that names a package, plus the selector that narrows it."""

    origin: str
    selector_flag: str | None  # "--filter", "--skip", or None for the whole estate
    selector: str | None

    def describe(self) -> str:
        if self.selector_flag is None:
            return f"{self.origin}: whole estate"
        return f"{self.origin}: {self.selector_flag} {self.selector}"


def gate_steps() -> list[str]:
    """Returns the final step strings that the gate assembles for this tree."""
    runner = REPO_ROOT / "scripts/run-test-suite.sh"
    if not runner.is_file():
        raise LintError(f"{runner} is missing; there is no step list to check against.")
    result = subprocess.run(
        [str(runner), "--list-steps"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "no diagnostic"
        raise LintError(f"{runner} --list-steps failed: {detail}")
    return [line.removeprefix("wide: ") for line in result.stdout.splitlines() if line]


def tracked_files() -> list[Path]:
    """Every tracked path, the one discovery both script estates are filtered out of."""
    result = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "ls-files", "-z"],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode(errors="replace").strip() or "no diagnostic"
        raise LintError(f"tracked-file discovery failed: {detail}")
    return sorted(
        Path(raw.decode(errors="surrogateescape"))
        for raw in result.stdout.split(b"\0")
        if raw
    )


def tracked_script_tests(tracked: list[Path]) -> set[Path]:
    """Returns tracked shell and Python self-tests from every repository directory."""
    return {path for path in tracked if path.name.endswith(("_test.sh", "_test.py"))}


RULE_CHECK = re.compile(r"-(?:lint|gate)\.(?:sh|py)$")

# Sourced libraries live here. `scripts/lib/lint-targets.sh` is read by a lint rather
# than run as one, so a name that matches RULE_CHECK under this directory is not a
# gate step and must not be required to be one.
LIBRARY_DIR = Path("scripts/lib")


def tracked_rule_checks(tracked: list[Path]) -> set[Path]:
    """Returns the tracked rule checks, discovered by the name every one of them carries."""
    return {
        path
        for path in tracked
        if RULE_CHECK.search(path.name)
        and not path.name.endswith(("_test.sh", "_test.py"))
        and LIBRARY_DIR not in path.parents
    }


def shell_tokens(command: str) -> list[str]:
    """Splits one assembled shell command while preserving command separators."""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|")
    lexer.whitespace_split = True
    lexer.commenters = "#"
    try:
        return list(lexer)
    except ValueError:
        return []


def command_segments(step: str) -> list[list[str]]:
    """Splits a gate step into the commands whose first executable word can run a test."""
    segments: list[list[str]] = []
    segment: list[str] = []
    for token in shell_tokens(step):
        if token and set(token) <= set(";&|"):
            if segment:
                segments.append(segment)
                segment = []
        else:
            segment.append(token)
    if segment:
        segments.append(segment)
    return segments


ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
PYTHON = re.compile(r"^python(?:[0-9]+(?:\.[0-9]+)*)?$")
INTERPRETERS = {"bash", "dash", "sh", "zsh"}


def executable_index(tokens: list[str]) -> int | None:
    """Finds the command word after leading assignments and a simple `env` prefix."""
    cursor = 0
    while cursor < len(tokens) and ASSIGNMENT.match(tokens[cursor]):
        cursor += 1
    if cursor >= len(tokens):
        return None
    if Path(tokens[cursor]).name != "env":
        return cursor
    cursor += 1
    while cursor < len(tokens):
        token = tokens[cursor]
        if ASSIGNMENT.match(token):
            cursor += 1
        elif token in {"-u", "--unset", "-C", "--chdir"}:
            cursor += 2
        elif token.startswith("-"):
            cursor += 1
        else:
            return cursor
    return None


def interpreter_operand(tokens: list[str], interpreter_at: int) -> str | None:
    """Returns an interpreter's script operand, excluding `-c` and module commands."""
    cursor = interpreter_at + 1
    while cursor < len(tokens):
        token = tokens[cursor]
        if token == "--":
            return tokens[cursor + 1] if cursor + 1 < len(tokens) else None
        if token in {"-c", "-m", "--command"}:
            return None
        if token.startswith("-"):
            cursor += 1
            continue
        return token
    return None


def normalized_repo_path(token: str) -> Path | None:
    """Normalizes a literal repository-relative command path."""
    if "$" in token:
        return None
    path = Path(token)
    if path.is_absolute():
        try:
            return path.relative_to(REPO_ROOT)
        except ValueError:
            return None
    parts = path.parts
    if parts[:1] == (".",):
        parts = parts[1:]
    if not parts or ".." in parts:
        return None
    return Path(*parts)


def covered_script_tests(steps: list[str], tests: set[Path]) -> set[Path]:
    """Returns tests used in an executable command position at least once."""
    covered: set[Path] = set()
    for step in steps:
        for tokens in command_segments(step):
            command_at = executable_index(tokens)
            if command_at is None:
                continue
            command = tokens[command_at]
            candidate = normalized_repo_path(command)
            if candidate in tests:
                covered.add(candidate)
            executable = Path(command).name
            if executable in INTERPRETERS or PYTHON.match(executable):
                operand = interpreter_operand(tokens, command_at)
                candidate = normalized_repo_path(operand) if operand else None
                if candidate in tests:
                    covered.add(candidate)
    return covered


OPT_OUT = re.compile(
    r"^[ \t]*# gate: opt-out --[ \t]+(\S(?:.*\S)?)[ \t]*$", re.MULTILINE
)


def opted_out(paths: set[Path]) -> set[Path]:
    """Returns the files carrying an in-file opt-out with a non-empty reason."""
    return {path for path in paths if OPT_OUT.search((REPO_ROOT / path).read_text())}


def covered_through_wrapper(paths: set[Path], covered: set[Path]) -> set[Path]:
    """Returns the paths a covered same-stem sibling runs by basename.

    `scripts/core-purity-lint.sh` is three lines that `exec python3
    "$SCRIPT_DIR/core-purity-lint.py"`. The gate reaches the Python file, but through a
    path the step list never spells, so the wrapper's own text is the only evidence.
    """
    reached: set[Path] = set()
    by_stem: dict[Path, set[Path]] = {}
    for path in paths:
        by_stem.setdefault(path.with_suffix(""), set()).add(path)
    for wrapper in covered & paths:
        text = (REPO_ROOT / wrapper).read_text()
        for sibling in by_stem.get(wrapper.with_suffix(""), set()) - {wrapper}:
            if sibling.name in text:
                reached.add(sibling)
    return reached


def expand(value: str, variables: dict[str, str]) -> str:
    """Resolves `$VAR`, `${VAR}`, and `${VAR:-default}`; anything else becomes UNRESOLVED.

    Enough shell to follow a wrapper script's package path back to a directory name.
    A command substitution is not evaluated -- it collapses to UNRESOLVED, which still
    lets a suffix like `/lib/TerminalPTY` identify the package.
    """
    out: list[str] = []
    index = 0
    while index < len(value):
        char = value[index]
        if char != "$":
            out.append(char)
            index += 1
            continue
        if value.startswith("$(", index):
            try:
                index = balanced_span(value, index + 1)
            except LintError:
                index = len(value)
            out.append(UNRESOLVED)
            continue
        if value.startswith("${", index):
            if "}" not in value[index:]:
                out.append(UNRESOLVED)
                break
            close = value.index("}", index)
            inner = value[index + 2 : close]
            index = close + 1
            if ":-" in inner:
                name, default = inner.split(":-", 1)
                out.append(variables.get(name) or expand(default, variables))
            else:
                out.append(variables.get(inner, UNRESOLVED))
            continue
        name_match = re.match(r"\$([A-Za-z_][A-Za-z0-9_]*)", value[index:])
        if not name_match:
            out.append(UNRESOLVED)
            index += 1
            continue
        index += name_match.end()
        out.append(variables.get(name_match.group(1), UNRESOLVED))
    return "".join(out)


def logical_lines(text: str) -> list[str]:
    """Joins backslash continuations so a multi-line invocation reads as one command."""
    lines: list[str] = []
    pending = ""
    for raw in text.splitlines():
        stripped = raw.strip()
        if stripped.endswith("\\"):
            pending += stripped[:-1] + " "
            continue
        lines.append(pending + stripped)
        pending = ""
    if pending:
        lines.append(pending)
    return lines


def tokenize_script(path: Path) -> list[list[str]]:
    """Every command in a wrapper script, variable-expanded and split into tokens."""
    variables: dict[str, str] = {}
    commands: list[list[str]] = []
    for line in logical_lines(path.read_text()):
        if not line or line.startswith("#"):
            continue
        assignment = re.match(
            r'^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(".*"|\'.*\'|\S*)$', line
        )
        if assignment:
            raw = assignment.group(2)
            if raw[:1] in ('"', "'") and raw[-1:] == raw[:1]:
                raw = raw[1:-1]
            variables[assignment.group(1)] = expand(raw, variables)
            continue
        try:
            tokens = shlex.split(expand(line, variables), comments=True)
        except ValueError:
            continue
        if tokens:
            commands.append(tokens)
    return commands


def tokenize_step(step: str) -> list[list[str]]:
    """A gate step string as tokens; `&&`-joined steps stay one token stream."""
    try:
        return [shlex.split(step, comments=True)]
    except ValueError:
        return []


SEPARATORS = {"&&", "||", ";", "|"}


def flag_value(tokens: list[str], cursor: int, flag: str) -> str | None:
    """The value of `--flag value` or `--flag=value` at cursor, or None if this is another token."""
    token = tokens[cursor]
    if token == flag and cursor + 1 < len(tokens):
        return tokens[cursor + 1]
    if token.startswith(flag + "="):
        return token[len(flag) + 1 :]
    return None


def lanes_in(tokens: list[str], origin: str, package_rel: str) -> list[Lane]:
    """The `swift test` invocations in one command that name package_rel."""
    found: list[Lane] = []
    for index, token in enumerate(tokens):
        if token != "test":
            continue
        if index == 0 or not (
            tokens[index - 1] == "swift" or tokens[index - 1].endswith("/swift")
        ):
            continue
        # Stop at a shell separator: a step may join two commands, and the second
        # command's flags say nothing about this invocation.
        rest: list[str] = []
        for following in tokens[index + 1 :]:
            if following in SEPARATORS:
                break
            rest.append(following)
        named: str | None = None
        selector_flag: str | None = None
        selector: str | None = None
        for cursor in range(len(rest)):
            for flag in ("--package-path", "--filter", "--skip"):
                value = flag_value(rest, cursor, flag)
                if value is None:
                    continue
                if flag == "--package-path":
                    named = value
                else:
                    selector_flag, selector = flag, value
        if named is None:
            matched = package_rel == "."
        else:
            normalized = named.rstrip("/")
            matched = package_rel != "." and (
                normalized == package_rel or normalized.endswith("/" + package_rel)
            )
        if matched:
            found.append(Lane(origin=origin, selector_flag=selector_flag, selector=selector))
    return found


def lanes_for(package_rel: str, steps: list[str]) -> list[Lane]:
    """Every lane the gate has for a package, following one level of script indirection."""
    found: list[Lane] = []
    for step in steps:
        for tokens in tokenize_step(step):
            found.extend(lanes_in(tokens, step, package_rel))
            for token in tokens:
                candidate = REPO_ROOT / token.lstrip("./")
                if not token.startswith("./scripts/") or not token.endswith(".sh"):
                    continue
                if not candidate.is_file():
                    continue
                for inner in tokenize_script(candidate):
                    found.extend(lanes_in(inner, f"{step} -> {token}", package_rel))
    return found


def verdict(
    package_rel: str,
    estate: list[str],
    lanes: list[Lane],
    display_bound: list[str] | None = None,
) -> str | None:
    """The coverage complaint for one package, or None when its estate runs exactly once."""
    display_bound = display_bound or []
    for name in display_bound:
        skipped = any(
            lane.selector_flag == "--skip" and re.search(lane.selector or "", name)
            for lane in lanes
        )
        if lanes and not skipped:
            return (
                f"{package_rel} declares {name}, which carries {DISPLAY_BOUND_DEFINE} and so "
                "cannot run in a headless gate, but no gate lane skips it. Add "
                f"`--skip {name}` to the lane that runs this package."
            )
    if not estate:
        return None
    if not lanes:
        return (
            f"{package_rel} declares {', '.join(estate)} and no gate lane runs them. "
            "Add a `swift test --package-path` step to scripts/run-test-suite.sh. "
            "A step that only builds the package does not count -- it leaves the estate unrun."
        )

    def covers_estate(lane: Lane) -> bool:
        if lane.selector_flag is None:
            return True
        if lane.selector_flag == "--skip":
            # A skip that names only display-bound targets still runs the whole runnable
            # estate: it removes what must not run, which the check above already
            # required. Any other skip carves the estate down and does not.
            hits_display_bound = any(
                re.search(lane.selector or "", name) for name in display_bound
            )
            hits_estate = any(re.search(lane.selector or "", name) for name in estate)
            return hits_display_bound and not hits_estate
        return all(re.search(lane.selector or "", name) for name in estate)

    whole = [lane for lane in lanes if covers_estate(lane)]
    if len(whole) == 1 and len(lanes) == 1:
        return None
    if len(whole) > 1:
        return (
            f"{package_rel} has {len(whole)} lanes that each run its whole estate, so every "
            "test in it runs that many times per gate:\n    "
            + "\n    ".join(lane.describe() for lane in whole)
        )
    if whole:
        return (
            f"{package_rel} has a lane over its whole estate and {len(lanes) - 1} more, so part "
            "of the estate runs twice:\n    " + "\n    ".join(lane.describe() for lane in lanes)
        )
    filters = {lane.selector for lane in lanes if lane.selector_flag == "--filter"}
    skips = {lane.selector for lane in lanes if lane.selector_flag == "--skip"}
    if len(lanes) == 2 and filters and filters == skips:
        return None
    return (
        f"{package_rel} is only run by lanes that carve its estate down, and they do not put it "
        "back together. Lanes partition an estate only as a `--filter X` beside a `--skip X` "
        "for the same X:\n    " + "\n    ".join(lane.describe() for lane in lanes)
    )


def main() -> int:
    try:
        manifests = first_party_manifests(REPO_ROOT)
        steps = gate_steps()
        tracked = tracked_files()
        script_tests = tracked_script_tests(tracked)
        rule_checks = tracked_rule_checks(tracked)
        complaints: list[str] = []
        checked = 0
        for manifest in manifests:
            tests = [
                target for target in declared_targets(manifest) if target.kind == "testTarget"
            ]
            display_bound = [target.name for target in tests if target.requires_display]
            estate = [target.name for target in tests if not target.requires_display]
            if not tests:
                continue
            checked += 1
            package_rel = manifest.parent.relative_to(REPO_ROOT).as_posix()
            complaint = verdict(
                package_rel, estate, lanes_for(package_rel, steps), display_bound
            )
            if complaint:
                complaints.append(complaint)
        covered_scripts = covered_script_tests(steps, script_tests)
        opted_out_scripts = opted_out(script_tests)
        for path in sorted(script_tests - covered_scripts - opted_out_scripts):
            complaints.append(
                f"{path.as_posix()} is a tracked self-test but no assembled gate step "
                "runs it. Use it as a command word or interpreter script operand, or "
                "add `# gate: opt-out -- <reason>` to that file."
            )
        covered_checks = covered_script_tests(steps, rule_checks)
        covered_checks |= covered_through_wrapper(rule_checks, covered_checks)
        opted_out_checks = opted_out(rule_checks)
        for path in sorted(rule_checks - covered_checks - opted_out_checks):
            complaints.append(
                f"{path.as_posix()} is a tracked rule check but no assembled gate step "
                "runs it over the tree, so its self-test passing says nothing. Add it to "
                "scripts/run-test-suite.sh as a command word or interpreter script "
                "operand, or add `# gate: opt-out -- <reason>` to that file."
            )
    except LintError as error:
        print(f"gate-test-coverage-lint: {error}", file=sys.stderr)
        return 1

    if not checked:
        print(
            "gate-test-coverage-lint: no manifest declares a test target, so this check is "
            "checking nothing.",
            file=sys.stderr,
        )
        return 1
    if not script_tests:
        print(
            "gate-test-coverage-lint: no tracked shell or Python self-test was found, "
            "so script coverage is checking nothing.",
            file=sys.stderr,
        )
        return 1
    if not rule_checks:
        print(
            "gate-test-coverage-lint: no tracked rule check was found, so rule-check "
            "coverage is checking nothing.",
            file=sys.stderr,
        )
        return 1

    if complaints:
        for complaint in complaints:
            print(f"gate-test-coverage-lint: {complaint}", file=sys.stderr)
        return 1

    all_opted_out = opted_out_scripts | opted_out_checks
    opt_out_summary = ", ".join(path.as_posix() for path in sorted(all_opted_out))
    print(
        f"gate-test-coverage-lint: {checked} Swift test estates each run once per gate; "
        f"{len(script_tests - opted_out_scripts)} script self-tests and "
        f"{len(rule_checks - opted_out_checks)} rule checks covered; "
        f"{len(all_opted_out)} opted out"
        + (f": {opt_out_summary}" if opt_out_summary else "")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
