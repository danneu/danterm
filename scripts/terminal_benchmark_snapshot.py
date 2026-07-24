#!/usr/bin/env python3
"""Materialize immutable benchmark arms from Git trees and cache their build products.

The paired comparison workflow may never build in the operator's checkout: both
arms must come from immutable trees so a mid-session edit cannot redefine what a
measured binary contains. This module owns that boundary -- resolving an explicit
baseline revision, snapshotting the complete working tree without touching the
caller's index, exporting each tree into its own arm root together with the
ignored build prerequisites `git archive` omits, and reusing compiled products
only on an exact match of tree, configuration, toolchain, and prerequisite
digests. Scheduling, measurement, and the decision rule live in the comparison
runner; nothing here knows which arm is baseline once both roots exist.
"""
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile


CONFIGURATION = "release"
BUILD_FLAGS = ("-Xswiftc", "-DDANTERM_TERMINAL_BENCHMARK")
# Mirrors the path terminal-benchmark.sh compiles into, so a populated cache entry
# makes the harness's own `swift build` a no-op instead of a hidden recompile.
BUILD_PATH_SUFFIX = ".build/terminal-benchmark-swiftpm"
# Build inputs `git archive` cannot carry: .gitignore excludes them, but no arm
# links without them. Their content is part of every cache key.
IGNORED_PREREQUISITES = ("lib/GhosttyKit.xcframework", "lib/ghostty-themes")


def _git(repository_root, *arguments, check=True):
    return subprocess.run(
        ["git", *arguments],
        cwd=str(repository_root),
        check=check,
        capture_output=True,
        text=True,
    )


def file_sha256(path):
    """Digest one file in bounded memory so multi-hundred-megabyte binaries stay cheap."""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_baseline(repository_root, revision):
    """Resolve the operator's explicit baseline once, refusing to infer one."""
    if revision is None or not str(revision).strip():
        raise ValueError(
            "a comparison requires an explicit baseline revision; "
            "it is never inferred from HEAD, history, or the candidate"
        )
    revision = str(revision).strip()
    commit = _git(
        repository_root, "rev-parse", "--verify", "--quiet", f"{revision}^{{commit}}",
        check=False,
    )
    if commit.returncode != 0 or not commit.stdout.strip():
        raise ValueError(f"unknown baseline revision: {revision}")
    tree = _git(
        repository_root, "rev-parse", "--verify", f"{revision}^{{tree}}"
    ).stdout.strip()
    return {
        "role": "baseline",
        "revision": revision,
        "commit": commit.stdout.strip(),
        "tree": tree,
    }


def snapshot_candidate(repository_root):
    """Freeze the complete working tree into a Git tree without disturbing the caller's index."""
    repository_root = pathlib.Path(repository_root)
    base_commit = _git(repository_root, "rev-parse", "HEAD").stdout.strip()
    base_tree = _git(repository_root, "rev-parse", "HEAD^{tree}").stdout.strip()
    # A scratch index outside the repository, so `git add -A` can stage the whole
    # working tree without ever opening the index the operator is committing from.
    # Kept off `.git/` because a linked worktree makes that path a file, not a
    # directory -- and this branch is developed in exactly such a worktree.
    with tempfile.TemporaryDirectory() as scratch:
        environment = {
            **os.environ,
            "GIT_INDEX_FILE": str(pathlib.Path(scratch) / "candidate-index"),
        }

        def scratch_git(*arguments):
            return subprocess.run(
                ["git", *arguments],
                cwd=str(repository_root),
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            ).stdout.strip()

        scratch_git("read-tree", base_tree)
        scratch_git("add", "-A")
        tree = scratch_git("write-tree")
    paths = sorted(
        _git(
            repository_root, "diff-tree", "-r", "--name-only", base_tree, tree
        ).stdout.split()
    )
    return {
        "role": "candidate",
        "baseCommit": base_commit,
        "tree": tree,
        "paths": paths,
    }


def describe_sources(baseline, candidate):
    """Render what is about to be compared, so no arm's contents are a surprise."""
    lines = [
        "Comparing immutable source snapshots:",
        f"  baseline  revision {baseline['revision']}",
        f"  baseline  commit   {baseline['commit']}",
        f"  baseline  tree     {baseline['tree']}",
        f"  candidate base     {candidate['baseCommit']}",
        f"  candidate tree     {candidate['tree']}",
    ]
    if candidate["paths"]:
        lines.append(
            f"  candidate captured {len(candidate['paths'])} working-tree path(s):"
        )
        lines.extend(f"    {path}" for path in candidate["paths"])
    else:
        lines.append("  candidate captured no working-tree changes")
    return "\n".join(lines)


def _digest_path(path):
    """Digest a file or directory by its sorted relative-path/content listing."""
    digest = hashlib.sha256()
    if path.is_file() and not path.is_symlink():
        digest.update(b"file\0")
        digest.update(file_sha256(path).encode())
        return digest.hexdigest()
    entries = []
    for child in sorted(path.rglob("*")):
        relative = child.relative_to(path).as_posix()
        if child.is_symlink():
            entries.append((relative, "link", str(child.readlink())))
        elif child.is_dir():
            entries.append((relative, "dir", ""))
        else:
            entries.append((relative, "file", file_sha256(child)))
    digest.update(json.dumps(entries, sort_keys=True).encode())
    return digest.hexdigest()


def digest_prerequisites(repository_root, prerequisites=IGNORED_PREREQUISITES):
    """Digest every ignored build input, refusing to key a cache entry on a missing one."""
    repository_root = pathlib.Path(repository_root)
    digests = {}
    for relative in prerequisites:
        path = repository_root / relative
        if not path.exists():
            raise FileNotFoundError(
                f"benchmark build prerequisite is missing: {relative} "
                "(run ./build-lib.sh)"
            )
        digests[relative] = _digest_path(path)
    return digests


def cache_key(*, tree, configuration, toolchain, prerequisites):
    """Bind a build product to every input that can change it."""
    components = {
        "tree": tree,
        "configuration": configuration,
        "toolchain": toolchain,
        "prerequisites": dict(sorted(prerequisites.items())),
    }
    payload = json.dumps(components, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()


def _mach_o_uuid(path):
    return subprocess.run(
        ["dwarfdump", "--uuid", str(path)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split()[1]


def binary_identity(path, *, read_uuid=_mach_o_uuid):
    """Record the two identities that prove which compilation a bundle actually holds."""
    return {"sha256": file_sha256(path), "machOUuid": read_uuid(path)}


def verify_binary_identity(path, recorded, *, read_uuid=_mach_o_uuid):
    """Re-prove a reused binary before it can supply a measured block."""
    actual = binary_identity(path, read_uuid=read_uuid)
    for field in ("sha256", "machOUuid"):
        if actual[field] != recorded[field]:
            raise ValueError(
                f"cached benchmark binary {path} changed {field}: "
                f"recorded {recorded[field]}, found {actual[field]}"
            )
    return actual


def export_snapshot(repository_root, snapshot, destination, prerequisites=IGNORED_PREREQUISITES):
    """Lay down one immutable tree plus its ignored prerequisites as a buildable arm root."""
    repository_root = pathlib.Path(repository_root).resolve()
    destination = pathlib.Path(destination).resolve()
    if destination == repository_root or destination in repository_root.parents:
        raise ValueError(
            f"refusing to export a benchmark arm over the live checkout: {destination}"
        )
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    archive = subprocess.Popen(
        ["git", "archive", "--format=tar", snapshot["tree"]],
        cwd=str(repository_root),
        stdout=subprocess.PIPE,
    )
    extract = subprocess.Popen(
        ["tar", "-x", "-f", "-", "-C", str(destination)], stdin=archive.stdout
    )
    archive.stdout.close()
    if extract.wait() != 0 or archive.wait() != 0:
        raise RuntimeError(f"failed to export tree {snapshot['tree']}")
    for relative in prerequisites:
        source = repository_root / relative
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        _clone_tree(source, target)
    return destination


def _clone_tree(source, target):
    """Prefer APFS clones so one cache entry per candidate stays cheap to materialize."""
    clone = subprocess.run(
        ["cp", "-Rc", str(source), str(target)], capture_output=True, text=True
    )
    if clone.returncode == 0:
        return
    subprocess.run(
        ["cp", "-R", str(source), str(target)], check=True, capture_output=True, text=True
    )


def current_toolchain():
    """Identify the compiler, since the same tree yields different binaries across toolchains."""
    return subprocess.run(
        ["swift", "--version"], check=True, capture_output=True, text=True
    ).stdout.strip()


def build_arm(root):
    """Compile an arm's benchmark products with exactly the flags terminal-benchmark.sh uses."""
    root = pathlib.Path(root)
    build_path = root / BUILD_PATH_SUFFIX
    common = [
        "swift", "build",
        "--package-path", str(root),
        "--build-path", str(build_path),
        "--configuration", CONFIGURATION,
        *BUILD_FLAGS,
    ]
    subprocess.run(common, check=True)
    bin_path = pathlib.Path(
        subprocess.run(
            [*common, "--show-bin-path"], check=True, capture_output=True, text=True
        ).stdout.strip()
    )
    bootstrap = [
        "swift", "build",
        "--package-path", str(root / "lib" / "TerminalPTY"),
        "--build-path", str(build_path / "TerminalPTY"),
        "--configuration", CONFIGURATION,
    ]
    subprocess.run([*bootstrap, "--product", "PTYSessionBootstrap"], check=True)
    bootstrap_bin_path = pathlib.Path(
        subprocess.run(
            [*bootstrap, "--show-bin-path"], check=True, capture_output=True, text=True
        ).stdout.strip()
    )
    return [
        bin_path / "DanTerm",
        bin_path / "DanTermCLI",
        bootstrap_bin_path / "PTYSessionBootstrap",
    ]


def materialize_arm(
    repository_root,
    snapshot,
    *,
    cache_root,
    build=build_arm,
    read_uuid=_mach_o_uuid,
    toolchain=None,
):
    """Return a verified arm root for one snapshot, reusing build products when nothing changed."""
    repository_root = pathlib.Path(repository_root)
    cache_root = pathlib.Path(cache_root)
    key = cache_key(
        tree=snapshot["tree"],
        configuration=CONFIGURATION,
        toolchain=current_toolchain() if toolchain is None else toolchain,
        prerequisites=digest_prerequisites(repository_root),
    )
    entry = cache_root / key
    root = entry / "source"
    identity_path = entry / "identity.json"

    if identity_path.exists():
        recorded = json.loads(identity_path.read_text(encoding="utf-8"))
        if recorded.get("cacheKey") == key:
            for binary in recorded["binaries"]:
                verify_binary_identity(
                    root / binary["path"], binary, read_uuid=read_uuid
                )
            return {
                "role": snapshot["role"],
                "snapshot": snapshot,
                "cacheKey": key,
                "cacheHit": True,
                "root": str(root),
                "binaries": recorded["binaries"],
            }

    if entry.exists():
        shutil.rmtree(entry)
    entry.mkdir(parents=True)
    export_snapshot(repository_root, snapshot, root)
    binaries = [
        {
            "path": pathlib.Path(binary).resolve()
            .relative_to(root.resolve())
            .as_posix(),
            **binary_identity(binary, read_uuid=read_uuid),
        }
        for binary in build(root)
    ]
    _write_json(identity_path, {"cacheKey": key, "binaries": binaries})
    return {
        "role": snapshot["role"],
        "snapshot": snapshot,
        "cacheKey": key,
        "cacheHit": False,
        "root": str(root),
        "binaries": binaries,
    }


def _write_json(path, document):
    """Publish the identity record only once it is complete, so a killed build cannot look cached."""
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    temporary.replace(path)
