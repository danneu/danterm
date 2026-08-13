#!/usr/bin/env bash
# Verifies one app bundle against an emitted BundleLayout plan.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: verify-bundle-layout.sh <app-bundle> <layout-json> <repo-root>" >&2
    exit 2
fi

python3 - "$1" "$2" "$3" <<'PY'
import filecmp
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import stat
import sys

bundle = Path(sys.argv[1]).resolve()
plan_path = Path(sys.argv[2])
repo_root = Path(sys.argv[3]).resolve()


def fail(message: str) -> None:
    print(f"verify-bundle-layout: {message}", file=sys.stderr)
    raise SystemExit(1)


def relative_path(value: str, owner: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        fail(f"{owner} is not a safe relative path: {value}")
    return path


def bundle_path(value: str, owner: str) -> Path:
    relative = relative_path(value, owner)
    candidate = bundle.joinpath(*relative.parts)
    try:
        candidate.resolve().relative_to(bundle)
    except ValueError:
        fail(f"{owner} escapes the bundle: {value}")
    return candidate


def repository_path(value: str, owner: str) -> Path:
    relative = relative_path(value, owner)
    candidate = repo_root.joinpath(*relative.parts)
    try:
        candidate.resolve().relative_to(repo_root)
    except ValueError:
        fail(f"{owner} escapes the repository: {value}")
    return candidate


def compare_trees(expected: Path, actual: Path, display_path: str) -> None:
    comparison = filecmp.dircmp(expected, actual)
    if (
        comparison.left_only
        or comparison.right_only
        or comparison.common_funny
        or comparison.funny_files
    ):
        differences = (
            comparison.left_only
            + comparison.right_only
            + comparison.common_funny
            + comparison.funny_files
        )
        fail(f"{display_path} tree differs: {', '.join(sorted(differences))}")
    for name in comparison.common_files:
        expected_file = expected / name
        actual_file = actual / name
        if stat.S_IFMT(expected_file.lstat().st_mode) != stat.S_IFMT(actual_file.lstat().st_mode):
            fail(f"{display_path}/{name} has a different node type")
        if expected_file.is_symlink():
            if os.readlink(expected_file) != os.readlink(actual_file):
                fail(f"{display_path}/{name} has a different symlink target")
        elif filecmp.cmp(expected_file, actual_file, shallow=False) is False:
            fail(f"{display_path}/{name} differs from repository source")
    for name in comparison.common_dirs:
        expected_directory = expected / name
        actual_directory = actual / name
        if stat.S_IFMT(expected_directory.lstat().st_mode) != stat.S_IFMT(
            actual_directory.lstat().st_mode
        ):
            fail(f"{display_path}/{name} has a different node type")
        if expected_directory.is_symlink():
            if os.readlink(expected_directory) != os.readlink(actual_directory):
                fail(f"{display_path}/{name} has a different symlink target")
        else:
            compare_trees(expected_directory, actual_directory, f"{display_path}/{name}")


try:
    with plan_path.open() as stream:
        plan = json.load(stream)
except (OSError, json.JSONDecodeError) as error:
    fail(f"cannot read layout plan {plan_path}: {error}")

if plan.get("schemaVersion") != 1:
    fail(f"unsupported layout schema version: {plan.get('schemaVersion')!r}")
if bundle.is_dir() is False:
    fail(f"bundle does not exist: {bundle}")

entries = plan.get("entries")
identity = plan.get("identity")
exact_directories = plan.get("exactSetDirectories")
if (
    not isinstance(entries, list)
    or not isinstance(identity, dict)
    or not isinstance(exact_directories, list)
):
    fail("layout plan is missing entries, identity, or exactSetDirectories")

entry_by_id = {}
declared_paths = set()
for entry in entries:
    try:
        entry_id = entry["id"]
        display_path = entry["path"]
        required_mode = entry["mode"]
        source = entry["source"]
        source_kind = source["kind"]
        source_value = source["value"]
    except (KeyError, TypeError):
        fail(f"malformed entry: {entry!r}")
    if entry_id in entry_by_id:
        fail(f"duplicate entry id: {entry_id}")
    if display_path in declared_paths:
        fail(f"duplicate entry path: {display_path}")
    entry_by_id[entry_id] = entry
    declared_paths.add(display_path)

    path = bundle_path(display_path, f"entry {entry_id}")
    if path.exists() is False:
        fail(f"missing {display_path}")
    node_mode = path.lstat().st_mode
    expects_directory = source_kind == "repositoryTree"
    if expects_directory and stat.S_ISDIR(node_mode) is False:
        fail(f"{display_path} is not a directory")
    if expects_directory is False and stat.S_ISREG(node_mode) is False:
        fail(f"{display_path} is not a regular file")
    actual_mode = stat.S_IMODE(node_mode)
    if actual_mode != required_mode:
        fail(f"{display_path} has mode {actual_mode:o}; expected {required_mode:o}")

    if source_kind == "repositoryFile":
        expected = repository_path(source_value, f"source for {entry_id}")
        if expected.is_file() is False:
            fail(f"repository source does not exist for {display_path}: {source_value}")
        if path.is_file() is False or filecmp.cmp(expected, path, shallow=False) is False:
            fail(f"{display_path} differs from repository source {source_value}")
    elif source_kind == "repositoryTree":
        expected = repository_path(source_value, f"source for {entry_id}")
        if expected.is_dir() is False or path.is_dir() is False:
            fail(f"{display_path} is not the declared repository tree {source_value}")
        compare_trees(expected, path, display_path)
    elif source_kind == "propertyListTemplate":
        expected = repository_path(source_value, f"source for {entry_id}")
        if expected.is_file() is False or path.is_file() is False:
            fail(f"{display_path} is not the declared plist template {source_value}")
    elif source_kind not in {"product", "generatedThemeCatalog"}:
        fail(f"unknown source kind for {display_path}: {source_kind}")

for directory_value in exact_directories:
    directory = bundle_path(directory_value, "exact-set directory")
    if directory.is_dir() is False:
        fail(f"missing exact-set directory {directory_value}")
    expected_names = {
        PurePosixPath(path).name
        for path in declared_paths
        if str(PurePosixPath(path).parent) == directory_value
    }
    actual_names = {child.name for child in directory.iterdir()}
    extra = actual_names - expected_names
    missing = expected_names - actual_names
    if extra:
        fail(f"undeclared entry {directory_value}/{sorted(extra)[0]}")
    if missing:
        fail(f"missing {directory_value}/{sorted(missing)[0]}")

try:
    info_entry = entry_by_id["infoPlist"]
    plist_file = bundle_path(info_entry["path"], "Info.plist entry")
    with plist_file.open("rb") as stream:
        plist = plistlib.load(stream)
except (KeyError, OSError, plistlib.InvalidFileException) as error:
    fail(f"cannot read declared Info.plist: {error}")

identity_keys = {
    "bundleIdentifier": "CFBundleIdentifier",
    "name": "CFBundleName",
    "displayName": "CFBundleDisplayName",
    "executableName": "CFBundleExecutable",
    "iconName": "CFBundleIconName",
}
for identity_key, plist_key in identity_keys.items():
    expected = identity.get(identity_key)
    actual = plist.get(plist_key)
    if actual != expected:
        fail(
            f"{plist_key} is {actual!r}; expected {expected!r} "
            f"for {plan.get('variant', 'unknown')} variant"
        )

try:
    app_executable = bundle_path(entry_by_id["appExecutable"]["path"], "app executable")
    cli_executable = bundle_path(
        entry_by_id["commandLineExecutable"]["path"], "command-line executable"
    )
except KeyError as error:
    fail(f"layout is missing required executable entry: {error.args[0]}")

if os.path.samefile(app_executable, cli_executable):
    fail("GUI and CLI bundle paths have the same inode")
if filecmp.cmp(app_executable, cli_executable, shallow=False):
    fail("GUI and CLI bundle binaries have identical content")
PY
