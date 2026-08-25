#!/usr/bin/env python3
"""Checks every first-party module against its portable or pure-source policy."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import re
import sys

from manifest_targets import LintError, declared_targets, first_party_manifests


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SWEEP_ROOT = Path(os.environ.get("CORE_PURITY_LINT_ROOT") or SCRIPT_DIRECTORY.parent).resolve()
POLICY_FILE = Path(
    os.environ.get("CORE_PURITY_LINT_POLICY") or SCRIPT_DIRECTORY / "core-purity-policy.conf"
).resolve()
AMBIENT_SEAM_MARKER = "core-purity: ambient-seam"

IMPORT_RE = re.compile(
    r"^\s*(?:(?:@\S+|public|internal|package|private|fileprivate)\s+)*"
    r"import\s+([A-Za-z0-9_][A-Za-z0-9_.]*)(?:[^A-Za-z0-9_]|$)"
)
UI_IMPORT_RE = re.compile(
    r"^\s*(?:@\S+\s+)?import\s+(Cocoa|AppKit|SwiftUI)(?:[^A-Za-z0-9_]|$)"
)
HARD_BANS = [
    re.compile(pattern)
    for pattern in (
        r"(^|[^A-Za-z0-9_])import[ \t]+Darwin([^A-Za-z0-9_]|$)",
        r"(^|[^A-Za-z0-9_])import[ \t]+Network([^A-Za-z0-9_]|$)",
        r"(^|[^A-Za-z0-9_])FileManager([^A-Za-z0-9_]|$)",
        r"(^|[^A-Za-z0-9_])Process\(",
        r"(^|[^A-Za-z0-9_])DispatchSource",
        r"(^|[^A-Za-z0-9_])DispatchQueue\(",
        r"\.asyncAfter",
        r"(^|[^A-Za-z0-9_])Timer\(",
        r"(^|[^A-Za-z0-9_])URLSession",
        r"(^|[^A-Za-z0-9_])NSWorkspace",
        r"(^|[^A-Za-z0-9_])setsockopt",
        r"Data\(contentsOf:",
        r"\.write\(to:",
        r"(^|[^A-Za-z0-9_])ProcessInfo",
    )
]
AMBIENT_BANS = [
    re.compile(pattern)
    for pattern in (
        r"(^|[^A-Za-z0-9_])NSHomeDirectory",
        r"(^|[^A-Za-z0-9_])UUID\(\)",
        r"(^|[^A-Za-z0-9_])Date\(\)",
    )
]

PURE_FAILURE_RATIONALE = """
=======================================================================
core-purity lint FAILED: lib/DanTermCore must stay pure -- no IO, no
ambient nondeterminism. Two violation kinds (see the [tags] above):

  [hard-ban IO/nondeterminism] -- FileManager, Process(, DispatchSource,
    URLSession, ProcessInfo, import Darwin/Network, etc. Side-effecting
    or platform IO has no place in the pure core. Move the code to app/
    (runtime) or lib/DanTermSupport (portable side effects), as the
    earlier phases did, and call it from there.

  [ambient token outside an allowlisted seam] -- NSHomeDirectory, bare
    UUID(), or bare Date() used off-seam. The rule -- inject vs. ambient:

      Inject an explicit value when the result is SAVED (to disk),
      SENT (over IPC), or ASSERTED (in a test) -- anything a second
      execution will compare against. Leave it AMBIENT (read the real
      value) ONLY when the result is just SHOWN live and discarded.

    Thread the value through CoreEnv (env.newId()/now()/homeDirectory())
    or a `home:` parameter instead. The only legitimate ambient reads are
    the seams already marked `// core-purity: ambient-seam` (CoreEnv.live
    and the abbreviateHome/expandTilde leaf defaults). Add that marker
    ONLY when establishing a genuine new ambient seam -- and never to
    silence a hard-ban token (the marker does not exempt those).

  See the ADR subsection "When to inject an ambient input:
  save/send/assert vs. show" in
  docs/design/2026-05-28-pure-core-support-split.md.
======================================================================="""


@dataclass(frozen=True)
class ModulePolicy:
    """The source restrictions applied to one manifest-declared module."""

    profile: str = "portable"
    import_rule: str = ""


def swift_files(directory: Path) -> list[Path]:
    """Returns the module's Swift sources in a stable diagnostic order."""
    return sorted(path for path in directory.rglob("*.swift") if path.is_file())


def source_lines(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def strip_noncode(lines: list[str]) -> list[str]:
    """Strips the simple strings and comments understood by the denylist contract."""
    stripped: list[str] = []
    in_block = False
    for raw in lines:
        line = raw
        if in_block:
            end = line.find("*/")
            if end < 0:
                stripped.append("")
                continue
            line = line[end + 2 :]
            in_block = False
        line = re.sub(r'"[^"]*"', "", line)
        while (start := line.find("/*")) >= 0:
            end = line.find("*/", start + 2)
            if end >= 0:
                line = line[:start] + line[end + 2 :]
            else:
                line = line[:start]
                in_block = True
                break
        comment = line.find("//")
        if comment >= 0:
            line = line[:comment]
        stripped.append(line)
    return stripped


def check_module(directory: Path, policy: ModulePolicy) -> bool:
    """Checks one module without spawning another lint process."""
    contents = [(path, source_lines(path)) for path in swift_files(directory)]

    if policy.import_rule == "forbid-imports":
        violations = [
            (path, number, line)
            for path, lines in contents
            for number, line in enumerate(lines, 1)
            if IMPORT_RE.search(line)
        ]
        for path, number, line in violations:
            print(f"{path}:{number}:{line}", file=sys.stderr)
        if violations:
            print(f"Swift import found in {directory} (module must remain import-free)", file=sys.stderr)
            return False
    elif policy.import_rule.startswith("allow="):
        allowed_text = policy.import_rule.removeprefix("allow=")
        allowed = set(allowed_text.split(","))
        violations = []
        for path, lines in contents:
            for number, line in enumerate(lines, 1):
                match = IMPORT_RE.search(line)
                if match and match.group(1) not in allowed:
                    violations.append((path, number, match.group(1)))
        for path, number, module in violations:
            print(f"{path}:{number}: disallowed Swift import {module}", file=sys.stderr)
        if violations:
            print(
                f"Swift import outside allowlist '{allowed_text}' found in {directory}",
                file=sys.stderr,
            )
            return False

    ui_violations = [
        (path, number, line)
        for path, lines in contents
        for number, line in enumerate(lines, 1)
        if UI_IMPORT_RE.search(line)
    ]
    for path, number, line in ui_violations:
        print(f"{path}:{number}:{line}", file=sys.stderr)
    if ui_violations:
        print(
            f"Cocoa/AppKit/SwiftUI import found in {directory} (must stay UI-free)",
            file=sys.stderr,
        )
        return False
    if policy.profile == "portable":
        return True

    pure_violation = False
    for path, raw_lines in contents:
        for number, (raw, code) in enumerate(zip(raw_lines, strip_noncode(raw_lines)), 1):
            if any(pattern.search(code) for pattern in HARD_BANS):
                print(f"{path}:{number}: [hard-ban IO/nondeterminism] {raw}", file=sys.stderr)
                pure_violation = True
            if AMBIENT_SEAM_MARKER not in raw and any(
                pattern.search(code) for pattern in AMBIENT_BANS
            ):
                print(
                    f"{path}:{number}: [ambient token outside an allowlisted seam] {raw}",
                    file=sys.stderr,
                )
                pure_violation = True
    if pure_violation:
        print(PURE_FAILURE_RATIONALE, file=sys.stderr)
    return not pure_violation


def read_policy() -> dict[str, ModulePolicy]:
    """Reads the first policy declaration for each root-relative module path."""
    policies: dict[str, ModulePolicy] = {}
    for raw in POLICY_FILE.read_text(encoding="utf-8").splitlines():
        content = raw.split("#", 1)[0].strip()
        if not content:
            continue
        fields = content.split()
        policies.setdefault(
            fields[0],
            ModulePolicy(fields[1] if len(fields) > 1 else "", fields[2] if len(fields) > 2 else ""),
        )
    return policies


def run_sweep() -> int:
    policies = read_policy()
    passed = True
    for relative in policies:
        if not (SWEEP_ROOT / relative).is_dir():
            print(
                f"core-purity-lint: {POLICY_FILE} names '{relative}', which is not a module directory",
                file=sys.stderr,
            )
            passed = False
    try:
        modules: list[tuple[str, Path]] = []
        for manifest in first_party_manifests(SWEEP_ROOT):
            package = manifest.parent.relative_to(SWEEP_ROOT)
            for target in declared_targets(manifest):
                if target.kind != "testTarget":
                    relative = (package / target.declared_path()).as_posix()
                    modules.append((relative, SWEEP_ROOT / relative))
    except (LintError, OSError) as error:
        print(f"manifest-targets: {error}", file=sys.stderr)
        return 1

    for relative, directory in modules:
        if not directory.is_dir():
            print(
                f"core-purity-lint: a manifest declares a target at '{relative}', which is not a directory",
                file=sys.stderr,
            )
            passed = False
            continue
        policy = policies.get(relative, ModulePolicy())
        if policy.profile == "ui":
            continue
        if policy.profile not in {"pure", "portable"}:
            print(
                f"core-purity-lint: {relative} declares unknown profile '{policy.profile}'",
                file=sys.stderr,
            )
            passed = False
            continue
        if policy.import_rule and not (
            policy.import_rule == "forbid-imports" or policy.import_rule.startswith("allow=")
        ):
            print(
                f"core-purity-lint: {relative} declares unknown import rule '{policy.import_rule}'",
                file=sys.stderr,
            )
            passed = False
            continue
        passed = check_module(directory, policy) and passed

    if passed:
        print(
            "core-purity lint: every module checked "
            f"(portable floor, policy in {os.path.relpath(POLICY_FILE, SWEEP_ROOT)})"
        )
    return 0 if passed else 1


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--profile", default="pure")
    parser.add_argument("--forbid-imports", action="store_true")
    parser.add_argument("--allow-imports", default="")
    parser.add_argument("target", nargs="?")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.target is None:
        if arguments.profile != "pure" or arguments.forbid_imports or arguments.allow_imports:
            print(
                f"core-purity-lint: flags need a target; the sweep takes its profiles from {POLICY_FILE}",
                file=sys.stderr,
            )
            return 2
        return run_sweep()
    if arguments.forbid_imports and arguments.allow_imports:
        print(
            "core-purity-lint: --forbid-imports and --allow-imports are mutually exclusive",
            file=sys.stderr,
        )
        return 2
    if arguments.profile not in {"pure", "portable"}:
        print(
            f"core-purity-lint: unknown profile '{arguments.profile}' (expected pure|portable)",
            file=sys.stderr,
        )
        return 2
    import_rule = "forbid-imports" if arguments.forbid_imports else ""
    if arguments.allow_imports:
        import_rule = f"allow={arguments.allow_imports}"
    policy = ModulePolicy(arguments.profile, import_rule)
    return 0 if check_module(Path(arguments.target), policy) else 1


if __name__ == "__main__":
    raise SystemExit(main())
