#!/usr/bin/env bash
# Assembles one app bundle from an emitted BundleLayout plan and named products.
set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "usage: assemble-app-bundle.sh <app-bundle> <layout-json> <repo-root> [--version VERSION] [--product NAME=PATH ...]" >&2
    exit 2
fi

app_bundle="$1"
layout_json="$2"
repo_root="$3"
shift 3

python3 - "$app_bundle" "$layout_json" "$repo_root" "$@" <<'PY'
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import subprocess
import sys

bundle_argument = Path(sys.argv[1])
bundle = bundle_argument.parent.resolve() / bundle_argument.name
plan_path = Path(sys.argv[2])
repo_root = Path(sys.argv[3]).resolve()
arguments = sys.argv[4:]


def fail(message: str) -> None:
    print(f"assemble-app-bundle: {message}", file=sys.stderr)
    raise SystemExit(1)


def relative_path(value: str, owner: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        fail(f"{owner} is not a safe relative path: {value}")
    return path


def repository_path(value: str, owner: str) -> Path:
    relative = relative_path(value, owner)
    candidate = repo_root.joinpath(*relative.parts)
    try:
        candidate.resolve().relative_to(repo_root)
    except ValueError:
        fail(f"{owner} escapes the repository: {value}")
    return candidate


version = None
products: dict[str, Path] = {}
index = 0
while index < len(arguments):
    option = arguments[index]
    if option == "--version":
        if index + 1 >= len(arguments):
            fail("--version requires a value")
        version = arguments[index + 1]
        index += 2
    elif option == "--product":
        if index + 1 >= len(arguments) or "=" not in arguments[index + 1]:
            fail("--product requires NAME=PATH")
        name, value = arguments[index + 1].split("=", 1)
        if not name or not value:
            fail("--product requires non-empty NAME=PATH")
        if name in products:
            fail(f"duplicate product binding: {name}")
        products[name] = Path(value)
        index += 2
    else:
        fail(f"unknown option: {option}")

try:
    with plan_path.open() as stream:
        plan = json.load(stream)
except (OSError, json.JSONDecodeError) as error:
    fail(f"cannot read layout plan {plan_path}: {error}")

if plan.get("schemaVersion") != 1:
    fail(f"unsupported layout schema version: {plan.get('schemaVersion')!r}")
entries = plan.get("entries")
identity = plan.get("identity")
if not isinstance(entries, list) or not isinstance(identity, dict):
    fail("layout plan is missing entries or identity")
if bundle.name.endswith(".app") is False:
    fail(f"bundle destination must end in .app: {bundle}")

if bundle.is_symlink():
    fail(f"bundle destination is not a removable directory: {bundle}")
if bundle.exists():
    if bundle.is_dir() is False:
        fail(f"bundle destination is not a removable directory: {bundle}")
    shutil.rmtree(bundle)

seen_ids: set[str] = set()
seen_paths: set[str] = set()
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
    if entry_id in seen_ids:
        fail(f"duplicate entry id: {entry_id}")
    if display_path in seen_paths:
        fail(f"duplicate entry path: {display_path}")
    seen_ids.add(entry_id)
    seen_paths.add(display_path)

    relative = relative_path(display_path, f"entry {entry_id}")
    destination = bundle.joinpath(*relative.parts)
    destination.parent.mkdir(parents=True, exist_ok=True)

    if source_kind == "product":
        source_path = products.get(source_value)
        if source_path is None:
            fail(f"missing product binding for {source_value}")
        if source_path.is_file() is False:
            fail(f"product does not exist for {display_path}: {source_path}")
        shutil.copyfile(source_path, destination)
    elif source_kind == "repositoryFile":
        source_path = repository_path(source_value, f"source for {entry_id}")
        if source_path.is_file() is False:
            fail(f"repository source does not exist for {display_path}: {source_value}")
        shutil.copyfile(source_path, destination)
    elif source_kind == "repositoryTree":
        source_path = repository_path(source_value, f"source for {entry_id}")
        if source_path.is_dir() is False:
            fail(f"repository tree does not exist for {display_path}: {source_value}")
        shutil.copytree(source_path, destination, symlinks=True)
    elif source_kind == "propertyListTemplate":
        source_path = repository_path(source_value, f"source for {entry_id}")
        if source_path.is_file() is False:
            fail(f"plist template does not exist for {display_path}: {source_value}")
        with source_path.open("rb") as stream:
            plist = plistlib.load(stream)
        plist.update({
            "CFBundleIdentifier": identity["bundleIdentifier"],
            "CFBundleName": identity["name"],
            "CFBundleDisplayName": identity["displayName"],
            "CFBundleExecutable": identity["executableName"],
        })
        icon_name = identity.get("iconName")
        if icon_name is None:
            plist.pop("CFBundleIconName", None)
        else:
            plist["CFBundleIconName"] = icon_name
        if version is not None:
            plist["CFBundleVersion"] = version
            plist["CFBundleShortVersionString"] = version
        with destination.open("wb") as stream:
            plistlib.dump(plist, stream)
    elif source_kind == "generatedThemeCatalog":
        source_path = repository_path(source_value, f"source for {entry_id}")
        packer = repo_root / "scripts/pack-theme-catalog.py"
        if source_path.is_dir() is False or packer.is_file() is False:
            fail(f"theme catalog inputs do not exist for {display_path}")
        subprocess.run(
            [sys.executable, str(packer), "--source", str(source_path), "--output", str(destination)],
            check=True,
        )
    else:
        fail(f"unknown source kind for {display_path}: {source_kind}")

    os.chmod(destination, required_mode)
PY
