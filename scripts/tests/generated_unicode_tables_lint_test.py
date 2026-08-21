#!/usr/bin/env python3
"""Self-test for scripts/generated-unicode-tables-lint.py.

Every case runs the lint against a fixture tree rather than the real repo, so a
verdict is proved without regenerating anything and without needing the pinned
Unicode data. The fixture stands in for the artifact set: the lint reads the
generator's GENERATED_ARTIFACTS for the file list either way, so what a fixture
varies is the file contents and the manifest, which is exactly what the lint
judges.
"""

from __future__ import annotations

import hashlib
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
LINT = REPO_ROOT / "scripts" / "generated-unicode-tables-lint.py"
GENERATOR = REPO_ROOT / "scripts" / "generate-terminal-unicode-tables.py"

sys.path.insert(0, str(REPO_ROOT / "scripts"))


def artifact_paths() -> list[str]:
    """The artifact list straight from the generator, so the fixture matches production."""
    import importlib.util

    spec = importlib.util.spec_from_file_location("_generator", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return list(module.GENERATED_ARTIFACTS.values())


def build_tree(root: Path, contents: dict[str, str]) -> None:
    for relative_path, text in contents.items():
        path = root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")


def write_manifest(root: Path, contents: dict[str, str]) -> None:
    lines = [
        f"{hashlib.sha256(text.encode('utf-8')).hexdigest()}  {relative_path}"
        for relative_path, text in sorted(contents.items())
    ]
    manifest = root / "scripts" / "generated-unicode-tables.sha256"
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_lint(root: Path, *arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(LINT), *arguments],
        env={
            "GENERATED_UNICODE_TABLES_LINT_ROOT": str(root),
            "PATH": "/usr/bin:/bin",
        },
        capture_output=True,
        text=True,
    )


def case(name: str, condition: bool, detail: str = "") -> bool:
    if condition:
        print(f"  ok    {name}")
        return True
    print(f"  FAIL  {name}{(': ' + detail) if detail else ''}", file=sys.stderr)
    return False


def main() -> int:
    passed = True
    paths = artifact_paths()
    baseline = {path: f"contents of {path}\n" for path in paths}

    # A tree whose files match the manifest is the only passing shape.
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        build_tree(root, baseline)
        write_manifest(root, baseline)
        result = run_lint(root)
        passed &= case(
            "a tree matching its manifest passes",
            result.returncode == 0,
            result.stderr.strip(),
        )
        passed &= case(
            "the success line counts every artifact",
            str(len(paths)) in result.stdout,
            result.stdout.strip(),
        )

    # The whole point: a hand-edit to a generated file is caught.
    for edited in (paths[0], paths[len(paths) // 2], paths[-1]):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build_tree(root, baseline)
            write_manifest(root, baseline)
            (root / edited).write_text("hand edited\n", encoding="utf-8")
            result = run_lint(root)
            passed &= case(
                f"a hand-edit to {Path(edited).name} fails",
                result.returncode == 1 and edited in result.stderr,
                result.stderr.strip(),
            )

    # A missing artifact is a distinct verdict, not a crash.
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        build_tree(root, baseline)
        write_manifest(root, baseline)
        (root / paths[0]).unlink()
        result = run_lint(root)
        passed &= case(
            "a missing artifact fails and names it",
            result.returncode == 1 and paths[0] in result.stderr,
            result.stderr.strip(),
        )

    # An artifact the manifest never mentions must fail, or adding a ninth
    # artifact would silently go unguarded -- the drift this lint exists to stop.
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        build_tree(root, baseline)
        partial = {path: text for path, text in baseline.items() if path != paths[-1]}
        write_manifest(root, partial)
        result = run_lint(root)
        passed &= case(
            "an artifact absent from the manifest fails",
            result.returncode == 1 and paths[-1] in result.stderr,
            result.stderr.strip(),
        )

    # A manifest line for a file the generator no longer writes is stale.
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        build_tree(root, baseline)
        extra = dict(baseline)
        extra["lib/TerminalCore/Sources/TerminalCore/Retired.generated.swift"] = "gone\n"
        write_manifest(root, extra)
        result = run_lint(root)
        passed &= case(
            "a manifest line for a retired artifact fails",
            result.returncode == 1 and "Retired.generated.swift" in result.stderr,
            result.stderr.strip(),
        )

    # A missing manifest must fail rather than vacuously pass.
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        build_tree(root, baseline)
        result = run_lint(root)
        passed &= case(
            "a missing manifest fails",
            result.returncode == 1,
            result.stdout.strip() + result.stderr.strip(),
        )

    # --update writes a manifest the very next check accepts.
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        build_tree(root, baseline)
        update = run_lint(root, "--update")
        recheck = run_lint(root)
        passed &= case(
            "--update writes a manifest that then passes",
            update.returncode == 0 and recheck.returncode == 0,
            update.stderr.strip() + recheck.stderr.strip(),
        )

    if not passed:
        print("generated-unicode-tables-lint self-test: FAILED", file=sys.stderr)
        return 1
    print("generated-unicode-tables-lint self-test: all cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
