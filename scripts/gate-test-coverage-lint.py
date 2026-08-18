#!/usr/bin/env python3
"""Enforces that every first-party package which declares tests actually has those tests run by `just test`, exactly once.

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

The check reads text only; it never imports or executes a manifest. A `path:` that
is not a string literal is therefore rejected rather than guessed at, so a computed
path fails loudly instead of slipping past.
"""

from __future__ import annotations

import os
import re
import shlex
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from manifest_targets import LintError, balanced_span, declared_targets  # noqa: E402

# Test seam: the self-test points the check at a fixture tree of tiny manifests and a
# synthetic step list, so it can prove each verdict without running the real gate.
# Nothing else sets this.
REPO_ROOT = Path(
    os.environ.get("GATE_TEST_COVERAGE_LINT_ROOT")
    or Path(__file__).resolve().parent.parent
).resolve()

# Packages the tree owns. `references/` holds external checkouts, so a manifest there
# is not ours to police.
MANIFEST_GLOBS = ("Package.swift", "lib/*/Package.swift", "ios/*/Package.swift")

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
    """The gate's step strings, read from the STEPS array's text rather than by running it."""
    runner = REPO_ROOT / "scripts/run-test-suite.sh"
    if not runner.is_file():
        raise LintError(f"{runner} is missing; there is no step list to check against.")
    text = runner.read_text()
    match = re.search(r"^STEPS=\(\n(.*?)^\)\n", text, re.MULTILINE | re.DOTALL)
    if not match:
        raise LintError(f"{runner}: no STEPS=( ... ) array found.")
    steps: list[str] = []
    for line in match.group(1).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        steps.append(shlex.split(line)[0] if line.startswith(("'", '"')) else line)
    return steps


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


def verdict(package_rel: str, estate: list[str], lanes: list[Lane]) -> str | None:
    """The coverage complaint for one package, or None when its estate runs exactly once."""
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
            return False
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
    manifests: list[Path] = []
    for glob in MANIFEST_GLOBS:
        manifests.extend(sorted(REPO_ROOT.glob(glob)))
    if not manifests:
        print(
            "gate-test-coverage-lint: no first-party manifest found, so this check is "
            "checking nothing. Either the tree moved or this script looks in the wrong place.",
            file=sys.stderr,
        )
        return 1

    try:
        steps = gate_steps()
        complaints: list[str] = []
        checked = 0
        for manifest in manifests:
            estate = [
                target.name
                for target in declared_targets(manifest)
                if target.kind == "testTarget"
            ]
            if not estate:
                continue
            checked += 1
            package_rel = manifest.parent.relative_to(REPO_ROOT).as_posix()
            complaint = verdict(package_rel, estate, lanes_for(package_rel, steps))
            if complaint:
                complaints.append(complaint)
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

    if complaints:
        for complaint in complaints:
            print(f"gate-test-coverage-lint: {complaint}", file=sys.stderr)
        return 1

    print(f"gate-test-coverage-lint: {checked} test estates each run once per gate")
    return 0


if __name__ == "__main__":
    sys.exit(main())
