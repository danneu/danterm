#!/usr/bin/env bash
# Behavioral tests for the emitted bundle layout and its standalone verifier.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "verify-bundle-layout_test: $*" >&2
    exit 1
}

# shellcheck source=../lib/bundle-layout-tool.sh
source "$ROOT_DIR/scripts/lib/bundle-layout-tool.sh"
bundle_layout_tool_init "$ROOT_DIR"

bundle_layout_tool release > "$TEST_ROOT/release.json"
bundle_layout_tool development > "$TEST_ROOT/development.json"
bundle_layout_tool benchmark .a > "$TEST_ROOT/benchmark.json"
bundle_layout_tool viability > "$TEST_ROOT/viability.json"

mkdir -p "$TEST_ROOT/products"
for product in DanTerm DanTermCLI DanTermInstanceIdentityTool PTYSessionBootstrap; do
    printf '#!/bin/sh\n# %s\nexit 0\n' "$product" > "$TEST_ROOT/products/$product"
    chmod 755 "$TEST_ROOT/products/$product"
done

# Intent: assembly follows every emitted source binding without a second entry list.
# Why it exists: a complete-looking bundle can still fail at runtime when a producer
#   writes the wrong built product into a declared executable slot.
# Scenario: assemble every producer variant from distinct fake products, then compare
#   every product-backed destination with the product named by the declaration.
for variant in release development benchmark viability; do
    bundle="$TEST_ROOT/assembled-$variant.app"
    "$ROOT_DIR/scripts/assemble-app-bundle.sh" \
        "$bundle" "$TEST_ROOT/$variant.json" "$ROOT_DIR" \
        --version 0.0.0-test \
        --product "DanTerm=$TEST_ROOT/products/DanTerm" \
        --product "DanTermCLI=$TEST_ROOT/products/DanTermCLI" \
        --product "DanTermInstanceIdentityTool=$TEST_ROOT/products/DanTermInstanceIdentityTool" \
        --product "PTYSessionBootstrap=$TEST_ROOT/products/PTYSessionBootstrap"
    "$ROOT_DIR/scripts/verify-bundle-layout.sh" \
        "$bundle" "$TEST_ROOT/$variant.json" "$ROOT_DIR"
done

mkdir -p "$TEST_ROOT/symlink-target.app"
ln -s "$TEST_ROOT/symlink-target.app" "$TEST_ROOT/symlink-bundle.app"
if "$ROOT_DIR/scripts/assemble-app-bundle.sh" \
    "$TEST_ROOT/symlink-bundle.app" "$TEST_ROOT/release.json" "$ROOT_DIR" \
    --product "DanTerm=$TEST_ROOT/products/DanTerm" \
    --product "DanTermCLI=$TEST_ROOT/products/DanTermCLI" \
    --product "PTYSessionBootstrap=$TEST_ROOT/products/PTYSessionBootstrap" \
    > "$TEST_ROOT/symlink.out" 2> "$TEST_ROOT/symlink.err"; then
    fail "assembler followed a symlink bundle destination"
fi
grep -qF 'not a removable directory' "$TEST_ROOT/symlink.err" \
    || fail "symlink destination failure did not name the unsafe target type"

ln -s "$TEST_ROOT/missing-target.app" "$TEST_ROOT/broken-symlink.app"
if "$ROOT_DIR/scripts/assemble-app-bundle.sh" \
    "$TEST_ROOT/broken-symlink.app" "$TEST_ROOT/release.json" "$ROOT_DIR" \
    --product "DanTerm=$TEST_ROOT/products/DanTerm" \
    --product "DanTermCLI=$TEST_ROOT/products/DanTermCLI" \
    --product "PTYSessionBootstrap=$TEST_ROOT/products/PTYSessionBootstrap" \
    > "$TEST_ROOT/broken-symlink.out" 2> "$TEST_ROOT/broken-symlink.err"; then
    fail "assembler accepted a broken symlink bundle destination"
fi
grep -qF 'not a removable directory' "$TEST_ROOT/broken-symlink.err" \
    || fail "broken symlink failure did not name the unsafe target type"

python3 - "$TEST_ROOT" <<'PY'
import json
from pathlib import Path
import plistlib
import sys

test_root = Path(sys.argv[1])
for variant in ("release", "development", "benchmark", "viability"):
    with (test_root / f"{variant}.json").open() as stream:
        plan = json.load(stream)
    bundle = test_root / f"assembled-{variant}.app"
    for entry in plan["entries"]:
        source = entry["source"]
        if source["kind"] == "product":
            assert (bundle / entry["path"]).read_bytes() == (
                test_root / "products" / source["value"]
            ).read_bytes(), entry["path"]
    with (bundle / "Contents/Info.plist").open("rb") as stream:
        plist = plistlib.load(stream)
    assert plist["CFBundleVersion"] == "0.0.0-test"
    assert plist["CFBundleShortVersionString"] == "0.0.0-test"
PY

# Intent: every emitted entry is enforced without a second hand-written list.
# Why it exists: adding an entry to BundleLayout must add existence, mode, and
#   source checks without requiring a matching test edit.
# Scenario: construct a valid release bundle from the emitted plan, then mutate
#   each declared obligation one at a time.
python3 - "$ROOT_DIR" "$TEST_ROOT" <<'PY'
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

root = Path(sys.argv[1])
test_root = Path(sys.argv[2])
release_plan_path = test_root / "release.json"
development_plan_path = test_root / "development.json"
verifier = root / "scripts/verify-bundle-layout.sh"

with release_plan_path.open() as stream:
    release_plan = json.load(stream)
with development_plan_path.open() as stream:
    development_plan = json.load(stream)


def build_fixture(plan: dict, destination: Path) -> None:
    if destination.exists():
        shutil.rmtree(destination)
    for entry in plan["entries"]:
        path = destination / entry["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        source = entry["source"]
        if source["kind"] == "repositoryFile":
            shutil.copyfile(root / source["value"], path)
        elif source["kind"] == "repositoryTree":
            shutil.copytree(root / source["value"], path)
        elif source["kind"] == "propertyListTemplate":
            shutil.copyfile(root / source["value"], path)
        elif source["kind"] == "product":
            path.write_bytes((source["value"] + "\n").encode())
        elif source["kind"] == "generatedThemeCatalog":
            path.write_text("{}\n")
        else:
            raise AssertionError(f"unknown source kind: {source['kind']}")
        os.chmod(path, entry["mode"])

    identity = plan["identity"]
    plist_path = destination / "Contents/Info.plist"
    with plist_path.open("rb") as stream:
        plist = plistlib.load(stream)
    plist.update({
        "CFBundleIdentifier": identity["bundleIdentifier"],
        "CFBundleName": identity["name"],
        "CFBundleDisplayName": identity["displayName"],
        "CFBundleExecutable": identity["executableName"],
    })
    if identity["iconName"] is None:
        plist.pop("CFBundleIconName", None)
    else:
        plist["CFBundleIconName"] = identity["iconName"]
    with plist_path.open("wb") as stream:
        plistlib.dump(plist, stream)
    info_entry = next(entry for entry in plan["entries"] if entry["id"] == "infoPlist")
    os.chmod(plist_path, info_entry["mode"])


def verify(bundle: Path, plan_path: Path = release_plan_path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(verifier), str(bundle), str(plan_path), str(root)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def expect_failure(bundle: Path, expected: str, plan_path: Path = release_plan_path) -> None:
    result = verify(bundle, plan_path)
    if result.returncode == 0:
        raise AssertionError(f"verification unexpectedly passed; wanted {expected!r}")
    if expected not in result.stderr:
        raise AssertionError(
            f"failure did not name {expected!r}: stdout={result.stdout!r} stderr={result.stderr!r}"
        )


def exercise_entries(plan: dict, plan_path: Path, bundle: Path) -> None:
    build_fixture(plan, bundle)
    result = verify(bundle, plan_path)
    if result.returncode != 0:
        raise AssertionError(f"valid {plan['variant']} bundle failed: {result.stderr}")

    for entry in plan["entries"]:
        build_fixture(plan, bundle)
        path = bundle / entry["path"]
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()
        expect_failure(bundle, entry["path"], plan_path)

        build_fixture(plan, bundle)
        path = bundle / entry["path"]
        os.chmod(path, 0o700 if entry["mode"] != 0o700 else 0o755)
        expect_failure(bundle, entry["path"], plan_path)

        build_fixture(plan, bundle)
        path = bundle / entry["path"]
        if path.is_dir():
            shutil.rmtree(path)
            path.write_text("wrong node type\n")
        else:
            path.unlink()
            path.mkdir()
        os.chmod(path, entry["mode"])
        expect_failure(bundle, entry["path"], plan_path)

        if entry["source"]["kind"] == "repositoryFile":
            build_fixture(plan, bundle)
            path = bundle / entry["path"]
            path.write_bytes(path.read_bytes() + b"perturbed\n")
            expect_failure(bundle, entry["path"], plan_path)
        elif entry["source"]["kind"] == "repositoryTree":
            build_fixture(plan, bundle)
            path = bundle / entry["path"]
            first_file = next(candidate for candidate in path.rglob("*") if candidate.is_file())
            first_file.write_bytes(first_file.read_bytes() + b"perturbed\n")
            expect_failure(bundle, entry["path"], plan_path)


release_bundle = test_root / "DanTerm.app"
development_bundle = test_root / "DanTerm Dev.app"
exercise_entries(release_plan, release_plan_path, release_bundle)
exercise_entries(development_plan, development_plan_path, development_bundle)

build_fixture(release_plan, release_bundle)
(release_bundle / "Contents/Helpers/undeclared").write_text("extra\n")
expect_failure(release_bundle, "Contents/Helpers/undeclared")

build_fixture(release_plan, release_bundle)
(release_bundle / "Contents/Resources/shell-integration/undeclared").write_text("extra\n")
expect_failure(release_bundle, "Contents/Resources/shell-integration")

# Intent: identity and binary-distinctness checks reject bundles that look
#   complete but cannot launch the intended GUI and CLI pair.
# Why it exists: exact paths and executable modes alone admit both a stale plist
#   and a CLI copied or linked from the GUI.
# Scenario: mutate a valid release bundle into each known invalid shape.
build_fixture(release_plan, release_bundle)
plist_path = release_bundle / "Contents/Info.plist"
with plist_path.open("rb") as stream:
    plist = plistlib.load(stream)
plist["CFBundleExecutable"] = "Wrong Executable"
with plist_path.open("wb") as stream:
    plistlib.dump(plist, stream)
os.chmod(plist_path, 0o644)
expect_failure(release_bundle, "CFBundleExecutable")

build_fixture(release_plan, release_bundle)
expect_failure(release_bundle, "Contents/MacOS/DanTerm Dev", development_plan_path)
build_fixture(development_plan, development_bundle)
expect_failure(development_bundle, "Contents/MacOS/DanTerm")

gui = release_bundle / "Contents/MacOS/DanTerm"
cli = release_bundle / "Contents/Helpers/danterm"
build_fixture(release_plan, release_bundle)
cli.unlink()
os.link(gui, cli)
expect_failure(release_bundle, "same inode")

build_fixture(release_plan, release_bundle)
shutil.copyfile(gui, cli)
os.chmod(cli, 0o755)
expect_failure(release_bundle, "identical content")
PY

echo "bundle layout verifier tests passed"
