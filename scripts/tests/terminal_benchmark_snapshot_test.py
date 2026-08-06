#!/usr/bin/env python3
"""Behavioral tests for immutable benchmark source snapshots and the build cache."""
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "terminal_benchmark_snapshot",
    ROOT / "scripts" / "terminal_benchmark_snapshot.py",
)
SNAPSHOT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SNAPSHOT)
HARNESS_PATH = ROOT / "scripts" / "terminal-benchmark.sh"


def git(repository, *arguments):
    return subprocess.run(
        ["git", *arguments],
        cwd=repository,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def make_repository(directory):
    """Build a miniature repo shaped like DanTerm: tracked sources plus an ignored build directory."""
    repository = pathlib.Path(directory)
    git(repository, "init", "--quiet", "-b", "main")
    git(repository, "config", "user.email", "test@example.com")
    git(repository, "config", "user.name", "Test")
    (repository / ".gitignore").write_text(".build/\n", encoding="utf-8")
    (repository / "app").mkdir()
    (repository / "app" / "main.swift").write_text("baseline\n", encoding="utf-8")
    git(repository, "add", "-A")
    git(repository, "commit", "--quiet", "-m", "baseline")
    ignored = repository / ".build" / "stale"
    ignored.mkdir(parents=True)
    (ignored / "artifact").write_text("stale\n", encoding="utf-8")
    return repository


class BaselineResolutionTests(unittest.TestCase):
    def test_baseline_must_be_named_explicitly(self):
        # Intent: the comparison commands can never invent a baseline.
        # Why it exists: I1 requires the operator to name the baseline; inferring it
        #   from HEAD, a merge-base, or the candidate would silently restore the
        #   history-vs-now decision the paired workflow replaces.
        # Scenario: an operator runs a comparison without passing baseline=.
        with tempfile.TemporaryDirectory() as directory:
            repository = make_repository(directory)
            for missing in (None, "", "   "):
                with self.assertRaises(ValueError):
                    SNAPSHOT.resolve_baseline(repository, missing)

    def test_baseline_resolves_to_an_immutable_commit_and_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = make_repository(directory)
            (repository / "app" / "main.swift").write_text("second\n", encoding="utf-8")
            git(repository, "commit", "--quiet", "-am", "second")

            baseline = SNAPSHOT.resolve_baseline(repository, "HEAD~1")

            self.assertEqual(baseline["role"], "baseline")
            self.assertEqual(baseline["revision"], "HEAD~1")
            self.assertEqual(
                baseline["commit"],
                git(repository, "rev-parse", "HEAD~1").strip(),
            )
            self.assertEqual(
                baseline["tree"],
                git(repository, "rev-parse", "HEAD~1^{tree}").strip(),
            )

    def test_unknown_baseline_revision_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = make_repository(directory)
            with self.assertRaises(ValueError):
                SNAPSHOT.resolve_baseline(repository, "no-such-revision")


class CandidateSnapshotTests(unittest.TestCase):
    def test_candidate_captures_the_complete_working_tree(self):
        # Intent: the candidate tree is the operator's complete working state.
        # Why it exists: I1 defines the candidate as tracked changes plus every
        #   non-ignored untracked file. A candidate built from HEAD alone would
        #   measure code the operator never wrote.
        # Scenario: an in-progress optimization has one edited tracked file and one
        #   brand-new untracked file, alongside an ignored build directory.
        with tempfile.TemporaryDirectory() as directory:
            repository = make_repository(directory)
            (repository / "app" / "main.swift").write_text("candidate\n", encoding="utf-8")
            (repository / "app" / "new.swift").write_text("added\n", encoding="utf-8")

            candidate = SNAPSHOT.snapshot_candidate(repository)

            self.assertEqual(candidate["role"], "candidate")
            self.assertEqual(
                candidate["baseCommit"], git(repository, "rev-parse", "HEAD").strip()
            )
            self.assertEqual(
                candidate["paths"], ["app/main.swift", "app/new.swift"]
            )
            listing = git(
                repository, "ls-tree", "-r", "--name-only", candidate["tree"]
            ).split()
            self.assertIn("app/new.swift", listing)
            self.assertNotIn(".build/stale/artifact", listing)

    def test_candidate_captures_deletions(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = make_repository(directory)
            (repository / "app" / "main.swift").unlink()

            candidate = SNAPSHOT.snapshot_candidate(repository)

            self.assertEqual(candidate["paths"], ["app/main.swift"])
            self.assertNotIn(
                "app/main.swift",
                git(repository, "ls-tree", "-r", "--name-only", candidate["tree"]).split(),
            )

    def test_candidate_snapshot_leaves_the_caller_index_untouched(self):
        # Intent: snapshotting never disturbs the operator's staged work.
        # Why it exists: the snapshot is taken mid-session, often with a partially
        #   staged commit in flight; a `git add -A` against the real index would
        #   silently destroy that staging.
        # Scenario: the operator has one file staged and another left unstaged, then
        #   runs a comparison from that state.
        with tempfile.TemporaryDirectory() as directory:
            repository = make_repository(directory)
            (repository / "app" / "main.swift").write_text("staged\n", encoding="utf-8")
            git(repository, "add", "app/main.swift")
            (repository / "app" / "unstaged.swift").write_text("loose\n", encoding="utf-8")
            before = git(repository, "status", "--short")

            SNAPSHOT.snapshot_candidate(repository)

            self.assertEqual(git(repository, "status", "--short"), before)

    def test_candidate_snapshot_works_in_a_linked_worktree(self):
        # Intent: snapshotting works wherever the operator actually develops.
        # Why it exists: DanTerm's terminal-engine work happens in a linked worktree,
        #   where `.git` is a file rather than a directory. A scratch index placed
        #   under `<root>/.git/` fails outright there.
        # Scenario: running a comparison from a `git worktree add` checkout -- the
        #   exact configuration this branch is developed in.
        with tempfile.TemporaryDirectory() as directory:
            repository = make_repository(directory)
            worktree = pathlib.Path(directory) / "linked"
            git(repository, "worktree", "add", "--quiet", str(worktree), "-b", "linked")
            self.assertTrue((worktree / ".git").is_file())
            (worktree / "app" / "main.swift").write_text("linked\n", encoding="utf-8")

            candidate = SNAPSHOT.snapshot_candidate(worktree)

            self.assertEqual(candidate["paths"], ["app/main.swift"])
            self.assertEqual(git(worktree, "status", "--short"), " M app/main.swift\n")

    def test_clean_tree_snapshot_matches_head_and_reports_no_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = make_repository(directory)

            candidate = SNAPSHOT.snapshot_candidate(repository)

            self.assertEqual(
                candidate["tree"], git(repository, "rev-parse", "HEAD^{tree}").strip()
            )
            self.assertEqual(candidate["paths"], [])


class SourceReportTests(unittest.TestCase):
    def test_report_names_both_identities_and_every_candidate_path(self):
        # Intent: the operator sees exactly what is about to be compared.
        # Why it exists: PO1 requires both tree identities and the captured candidate
        #   paths to be reported before either build begins, so a stray untracked file
        #   cannot silently enter a measured arm.
        # Scenario: a comparison starts against HEAD~1 with two working-tree edits.
        baseline = {
            "role": "baseline",
            "revision": "HEAD~1",
            "commit": "a" * 40,
            "tree": "b" * 40,
        }
        candidate = {
            "role": "candidate",
            "baseCommit": "c" * 40,
            "tree": "d" * 40,
            "paths": ["app/main.swift", "app/new.swift"],
        }

        report = SNAPSHOT.describe_sources(baseline, candidate)

        for expected in (
            "HEAD~1",
            "a" * 40,
            "b" * 40,
            "c" * 40,
            "d" * 40,
            "app/main.swift",
            "app/new.swift",
        ):
            self.assertIn(expected, report)

    def test_report_states_that_a_clean_candidate_captured_no_paths(self):
        report = SNAPSHOT.describe_sources(
            {"role": "baseline", "revision": "v1", "commit": "a" * 40, "tree": "b" * 40},
            {"role": "candidate", "baseCommit": "c" * 40, "tree": "b" * 40, "paths": []},
        )
        self.assertIn("no working-tree changes", report)


class ExportTests(unittest.TestCase):
    def test_export_materializes_the_tree_and_nothing_the_operator_ignored(self):
        # Intent: an arm root is exactly the immutable tree, with no untracked
        #   working-tree state leaking in beside it.
        # Why it exists: every build input is tracked now that libghostty is gone,
        #   so an arm builds from `git archive` output alone. Copying ignored paths
        #   in would reintroduce mutable, unversioned content into a measured arm.
        # Scenario: exporting the candidate snapshot into its own arm root while
        #   the checkout holds a stale ignored build directory.
        with tempfile.TemporaryDirectory() as directory:
            repository = make_repository(directory)
            candidate = SNAPSHOT.snapshot_candidate(repository)
            destination = pathlib.Path(directory) / "arm"

            SNAPSHOT.export_snapshot(repository, candidate, destination)

            self.assertEqual(
                (destination / "app" / "main.swift").read_text(encoding="utf-8"),
                "baseline\n",
            )
            self.assertFalse((destination / ".build").exists())

    def test_export_refuses_to_write_into_the_live_checkout(self):
        # Intent: an export can never overwrite the operator's checkout.
        # Why it exists: I6 limits benchmark commands to the files they create;
        #   exporting onto the repository root would destroy uncommitted work.
        with tempfile.TemporaryDirectory() as directory:
            repository = make_repository(directory)
            candidate = SNAPSHOT.snapshot_candidate(repository)
            with self.assertRaises(ValueError):
                SNAPSHOT.export_snapshot(repository, candidate, repository)


class CacheKeyTests(unittest.TestCase):
    def key(self, **overrides):
        components = {
            "tree": "b" * 40,
            "configuration": "release",
            "toolchain": "swift-6.1",
        }
        components.update(overrides)
        return SNAPSHOT.cache_key(**components)

    def test_identical_components_reuse_one_cache_entry(self):
        self.assertEqual(self.key(), self.key())

    def test_every_key_component_repopulates_instead_of_reusing(self):
        # Intent: a cache hit requires an exact match on every key component.
        # Why it exists: PO1 forbids reusing build products across a changed source
        #   tree, build configuration, or toolchain -- each of those changes the
        #   binary, so a stale reuse would measure the wrong code.
        # Scenario: one component changes at a time while the rest stay fixed.
        original = self.key()
        self.assertNotEqual(original, self.key(tree="e" * 40))
        self.assertNotEqual(original, self.key(configuration="debug"))
        self.assertNotEqual(original, self.key(toolchain="swift-6.2"))


class BinaryIdentityTests(unittest.TestCase):
    def test_identity_records_the_executable_digest_and_mach_o_uuid(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = pathlib.Path(directory) / "DanTerm"
            binary.write_bytes(b"binary")
            identity = SNAPSHOT.binary_identity(
                binary, read_uuid=lambda path: "F" * 8
            )
            self.assertEqual(identity["sha256"], SNAPSHOT.file_sha256(binary))
            self.assertEqual(identity["machOUuid"], "F" * 8)

    def test_a_changed_binary_fails_reverification(self):
        # Intent: a reused cache entry proves it still holds the binary it recorded.
        # Why it exists: PO1 requires the recorded executable SHA-256 and Mach-O UUID
        #   to be re-verified before the timed comparison, so a hand-edited or
        #   partially rebuilt cache entry cannot silently supply the measured code.
        # Scenario: a cached arm's executable is replaced between two comparisons.
        with tempfile.TemporaryDirectory() as directory:
            binary = pathlib.Path(directory) / "DanTerm"
            binary.write_bytes(b"binary")
            recorded = SNAPSHOT.binary_identity(binary, read_uuid=lambda path: "F" * 8)

            SNAPSHOT.verify_binary_identity(
                binary, recorded, read_uuid=lambda path: "F" * 8
            )

            binary.write_bytes(b"tampered")
            with self.assertRaises(ValueError):
                SNAPSHOT.verify_binary_identity(
                    binary, recorded, read_uuid=lambda path: "F" * 8
                )

    def test_a_changed_mach_o_uuid_fails_reverification(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = pathlib.Path(directory) / "DanTerm"
            binary.write_bytes(b"binary")
            recorded = SNAPSHOT.binary_identity(binary, read_uuid=lambda path: "F" * 8)
            with self.assertRaises(ValueError):
                SNAPSHOT.verify_binary_identity(
                    binary, recorded, read_uuid=lambda path: "0" * 8
                )


class ArmMaterializationTests(unittest.TestCase):
    def materialize(self, repository, snapshot, cache_root, builds, **overrides):
        def build(root):
            builds.append(pathlib.Path(root))
            binary = pathlib.Path(root) / ".build" / "bin" / "DanTerm"
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(b"compiled")
            return [binary]

        options = {
            "build": build,
            "read_uuid": lambda path: "F" * 8,
            "toolchain": "swift-6.1",
        }
        options.update(overrides)
        return SNAPSHOT.materialize_arm(
            repository, snapshot, cache_root=cache_root, **options
        )

    def test_a_cache_miss_populates_and_records_binary_identities(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = make_repository(directory)
            cache_root = pathlib.Path(directory) / "cache"
            builds = []

            arm = self.materialize(
                repository, SNAPSHOT.snapshot_candidate(repository), cache_root, builds
            )

            self.assertFalse(arm["cacheHit"])
            self.assertEqual(builds, [pathlib.Path(arm["root"])])
            recorded = json.loads(
                (pathlib.Path(arm["root"]).parent / "identity.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(recorded["cacheKey"], arm["cacheKey"])
            self.assertEqual(len(recorded["binaries"]), 1)

    def test_an_exact_repeat_reuses_the_entry_without_rebuilding(self):
        # Intent: the second comparison of an unchanged tree pays no compile cost.
        # Why it exists: the under-60-second quick budget only holds on the cached
        #   path, so an exact repeat must skip compilation entirely.
        # Scenario: an operator runs quick twice against the same baseline.
        with tempfile.TemporaryDirectory() as directory:
            repository = make_repository(directory)
            cache_root = pathlib.Path(directory) / "cache"
            snapshot = SNAPSHOT.snapshot_candidate(repository)
            builds = []

            first = self.materialize(repository, snapshot, cache_root, builds)
            second = self.materialize(repository, snapshot, cache_root, builds)

            self.assertFalse(first["cacheHit"])
            self.assertTrue(second["cacheHit"])
            self.assertEqual(first["cacheKey"], second["cacheKey"])
            self.assertEqual(first["root"], second["root"])
            self.assertEqual(len(builds), 1)

    def test_a_changed_toolchain_repopulates_a_separate_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = make_repository(directory)
            cache_root = pathlib.Path(directory) / "cache"
            snapshot = SNAPSHOT.snapshot_candidate(repository)
            builds = []

            first = self.materialize(repository, snapshot, cache_root, builds)
            second = self.materialize(
                repository, snapshot, cache_root, builds, toolchain="swift-6.2"
            )

            self.assertNotEqual(first["cacheKey"], second["cacheKey"])
            self.assertNotEqual(second["root"], first["root"])
            self.assertEqual(len(builds), 2)

    def test_reuse_reverifies_the_recorded_binaries_before_measuring(self):
        # Intent: a tampered cache entry is rejected, not measured.
        # Why it exists: PO1 requires re-verification of a reused bundle's recorded
        #   identities before the timed comparison begins.
        # Scenario: a cached arm's executable is overwritten between two runs.
        with tempfile.TemporaryDirectory() as directory:
            repository = make_repository(directory)
            cache_root = pathlib.Path(directory) / "cache"
            snapshot = SNAPSHOT.snapshot_candidate(repository)
            builds = []

            first = self.materialize(repository, snapshot, cache_root, builds)
            binary = pathlib.Path(first["root"]) / ".build" / "bin" / "DanTerm"
            binary.write_bytes(b"tampered")

            with self.assertRaises(ValueError):
                self.materialize(repository, snapshot, cache_root, builds)

    def test_arms_of_different_sources_never_share_a_root(self):
        # Intent: baseline and candidate build in disjoint source and build trees.
        # Why it exists: a shared checkout or shared SwiftPM build directory would let
        #   one arm's compilation define the other arm's binary, destroying the whole
        #   directional claim.
        # Scenario: a comparison of HEAD~1 against an edited working tree.
        with tempfile.TemporaryDirectory() as directory:
            repository = make_repository(directory)
            (repository / "app" / "main.swift").write_text("candidate\n", encoding="utf-8")
            cache_root = pathlib.Path(directory) / "cache"
            builds = []

            baseline = self.materialize(
                repository, SNAPSHOT.resolve_baseline(repository, "HEAD"), cache_root, builds
            )
            candidate = self.materialize(
                repository, SNAPSHOT.snapshot_candidate(repository), cache_root, builds
            )

            self.assertNotEqual(baseline["root"], candidate["root"])
            self.assertEqual(
                (pathlib.Path(baseline["root"]) / "app" / "main.swift").read_text(
                    encoding="utf-8"
                ),
                "baseline\n",
            )
            self.assertEqual(
                (pathlib.Path(candidate["root"]) / "app" / "main.swift").read_text(
                    encoding="utf-8"
                ),
                "candidate\n",
            )


class HarnessBuildContractTests(unittest.TestCase):
    def test_prebuild_uses_the_same_flags_as_the_benchmark_harness(self):
        # Intent: the cache prebuild produces the exact products the harness expects.
        # Why it exists: the harness rebuilds into the arm's own SwiftPM build path.
        #   If the prebuild used different flags the harness would recompile on every
        #   supposed cache hit, silently breaking the 60-second quick budget.
        # Scenario: someone changes the harness's release/benchmark build flags.
        harness = HARNESS_PATH.read_text(encoding="utf-8")
        self.assertIn(
            "--build-path \"$BUILD_PATH\" --configuration release", harness
        )
        self.assertIn("-Xswiftc -DDANTERM_TERMINAL_BENCHMARK", harness)
        self.assertEqual(
            SNAPSHOT.BUILD_PATH_SUFFIX, ".build/terminal-benchmark-swiftpm"
        )
        self.assertIn("$REPO_ROOT/.build/terminal-benchmark-swiftpm", harness)
        self.assertEqual(SNAPSHOT.CONFIGURATION, "release")
        self.assertIn("-DDANTERM_TERMINAL_BENCHMARK", SNAPSHOT.BUILD_FLAGS)


if __name__ == "__main__":
    unittest.main()
