#!/usr/bin/env python3
"""Behavioral tests for reproducible local reference checkouts.

The suite uses local git origins so pin, sparse-checkout, cache, failure, and
interrupt behavior remain offline and CI-portable. It loads the hyphenated
entry point directly, matching the other Python script tests in this directory.
"""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "fetch-references.py"
SPEC = importlib.util.spec_from_file_location("fetch_references", SCRIPT)
FETCH_REFERENCES = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = FETCH_REFERENCES
SPEC.loader.exec_module(FETCH_REFERENCES)


def git(*args, cwd=None, capture_output=False):
    return subprocess.run(
        ["git", *args],
        cwd=cwd,
        check=True,
        text=True,
        capture_output=capture_output,
    )


class FetchReferencesTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.origin = self.root / "origin"
        self.references = self.root / "references"
        self.origin.mkdir()
        git("init", "-q", cwd=self.origin)
        git("config", "user.email", "test@example.invalid", cwd=self.origin)
        git("config", "user.name", "Test User", cwd=self.origin)
        git("config", "uploadpack.allowFilter", "true", cwd=self.origin)
        git("config", "uploadpack.allowAnySHA1InWant", "true", cwd=self.origin)

        self.write("cone-a/inside.txt", "pinned\n")
        self.write("cone-b/other.txt", "other cone\n")
        self.write("outside-dir/outside.txt", "outside\n")
        self.write("deep/path/file.txt", "deep\n")
        git("add", ".", cwd=self.origin)
        git("commit", "-q", "-m", "pinned", cwd=self.origin)
        self.pinned_sha = self.rev_parse("HEAD")

        self.write("cone-a/inside.txt", "newer\n")
        git("add", ".", cwd=self.origin)
        git("commit", "-q", "-m", "newer", cwd=self.origin)
        self.newer_sha = self.rev_parse("HEAD")
        git("tag", "release-points-elsewhere", cwd=self.origin)

    def tearDown(self):
        self.temporary_directory.cleanup()

    def write(self, relative_path, content):
        path = self.origin / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def rev_parse(self, revision, cwd=None):
        result = git(
            "rev-parse",
            f"{revision}^{{commit}}",
            cwd=cwd or self.origin,
            capture_output=True,
        )
        return result.stdout.strip()

    def entry(self, *, name="fixture", pin=None, sparse_cone=("cone-a",)):
        return FETCH_REFERENCES.Reference(
            name=name,
            url=str(self.origin),
            pin=pin or self.pinned_sha,
            sparse_cone=tuple(sparse_cone),
            why="Exercises the local reference fetcher.",
            release_tag=None,
        )

    def fetch(self, entry=None, *, force=False):
        FETCH_REFERENCES.fetch_reference(
            entry or self.entry(),
            references_dir=self.references,
            force=force,
        )

    def test_sparse_entry_materializes_only_its_cone(self):
        self.fetch()
        checkout = self.references / "fixture"
        self.assertEqual((checkout / "cone-a/inside.txt").read_text(), "pinned\n")
        self.assertFalse((checkout / "outside-dir").exists())
        self.assertFalse((checkout / "cone-b").exists())

    def test_whole_repo_entry_materializes_files_at_any_depth(self):
        self.fetch(self.entry(sparse_cone=()))
        checkout = self.references / "fixture"
        self.assertEqual((checkout / "deep/path/file.txt").read_text(), "deep\n")
        self.assertEqual((checkout / "outside-dir/outside.txt").read_text(), "outside\n")

    def test_sha_pin_wins_when_a_release_tag_points_elsewhere(self):
        self.fetch()
        self.assertEqual(
            (self.references / "fixture/cone-a/inside.txt").read_text(),
            "pinned\n",
        )

    def test_up_to_date_checkout_is_left_untouched(self):
        self.fetch()
        sentinel = self.references / "fixture/local-sentinel"
        sentinel.write_text("keep\n")
        self.fetch()
        self.assertEqual(sentinel.read_text(), "keep\n")

    def test_checkout_without_cone_record_is_refetched(self):
        checkout = self.references / "fixture"
        checkout.parent.mkdir()
        git("clone", "-q", str(self.origin), str(checkout))
        git("checkout", "-q", "--detach", self.pinned_sha, cwd=checkout)
        git("sparse-checkout", "init", "--cone", cwd=checkout)
        git("sparse-checkout", "set", "cone-b", cwd=checkout)

        self.fetch()

        self.assertTrue((checkout / "cone-a/inside.txt").exists())
        self.assertFalse((checkout / "cone-b").exists())
        self.assertTrue((checkout / FETCH_REFERENCES.CONE_RECORD).exists())

    def test_checkout_with_moved_head_is_refetched(self):
        self.fetch()
        checkout = self.references / "fixture"
        git("fetch", "-q", "origin", self.newer_sha, cwd=checkout)
        git("checkout", "-q", "--detach", self.newer_sha, cwd=checkout)
        self.assertEqual((checkout / "cone-a/inside.txt").read_text(), "newer\n")

        self.fetch()

        self.assertEqual((checkout / "cone-a/inside.txt").read_text(), "pinned\n")
        self.assertEqual(self.rev_parse("HEAD", cwd=checkout), self.pinned_sha)

    def test_changing_only_the_sparse_cone_refetches(self):
        self.fetch()
        sentinel = self.references / "fixture/local-sentinel"
        sentinel.write_text("remove\n")

        self.fetch(self.entry(sparse_cone=("cone-b",)))

        checkout = self.references / "fixture"
        self.assertFalse(sentinel.exists())
        self.assertFalse((checkout / "cone-a").exists())
        self.assertEqual((checkout / "cone-b/other.txt").read_text(), "other cone\n")

    def test_force_refetches_an_up_to_date_entry(self):
        self.fetch()
        sentinel = self.references / "fixture/local-sentinel"
        sentinel.write_text("remove\n")

        self.fetch(force=True)

        self.assertFalse(sentinel.exists())

    def test_failed_fetch_leaves_the_previous_tree_intact(self):
        self.fetch()
        checkout = self.references / "fixture"

        with self.assertRaises(subprocess.CalledProcessError):
            self.fetch(self.entry(pin="f" * 40), force=True)

        self.assertEqual((checkout / "cone-a/inside.txt").read_text(), "pinned\n")
        self.assertEqual(self.rev_parse("HEAD", cwd=checkout), self.pinned_sha)

    def test_interrupt_during_transfer_leaves_the_previous_tree_intact(self):
        self.fetch()
        checkout = self.references / "fixture"
        marker = self.root / "fetch-started"
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        real_git = shutil.which("git")
        wrapper = fake_bin / "git"
        wrapper.write_text(
            textwrap.dedent(
                f"""\
                #!/bin/sh
                case " $* " in
                  *" fetch "*)
                    : > {marker}
                    sleep 30
                    ;;
                esac
                exec {real_git} "$@"
                """
            )
        )
        wrapper.chmod(0o755)
        code = self.subprocess_driver(force=True)
        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
        process = subprocess.Popen(
            [sys.executable, "-c", code],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
            text=True,
        )
        # Liveness bound, not a deadline the test asserts on: the loop exits the moment
        # the marker appears, so a generous budget costs nothing on the happy path and
        # only bounds a genuine hang. Sized for a saturated machine -- `just test` runs
        # its steps in parallel, and 2s was too tight for a git subprocess to reach
        # transfer under that load.
        for _ in range(3000):
            if marker.exists():
                break
            process.poll()
            if process.returncode is not None:
                break
            time.sleep(0.01)
        if not marker.exists():
            process.kill()
            output = process.communicate(timeout=60)
            self.fail(f"fetch subprocess never entered transfer: {output}")

        os.killpg(process.pid, signal.SIGINT)
        # Same liveness-bound reasoning as the marker poll above. Unwinding the
        # interrupt means the child restores the previous tree before exiting, and
        # under the parallel gate that cleanup is not guaranteed a prompt slice.
        process.communicate(timeout=60)

        self.assertNotEqual(process.returncode, 0)
        self.assertEqual((checkout / "cone-a/inside.txt").read_text(), "pinned\n")
        self.assertEqual(self.rev_parse("HEAD", cwd=checkout), self.pinned_sha)

    def test_interrupt_inside_swap_never_leaves_target_absent(self):
        target = self.references / "fixture"
        staged = self.root / "staged"
        target.mkdir(parents=True)
        staged.mkdir()
        (target / "old.txt").write_text("old\n")
        (staged / "new.txt").write_text("new\n")

        def interrupt_between_renames():
            os.kill(os.getpid(), signal.SIGINT)

        with self.assertRaises(KeyboardInterrupt):
            FETCH_REFERENCES.swap_reference(
                staged,
                target,
                between_renames=interrupt_between_renames,
            )

        self.assertTrue(target.is_dir())
        complete_old = (
            (target / "old.txt").read_text() == "old\n"
            if (target / "old.txt").exists()
            else False
        )
        complete_new = (
            (target / "new.txt").read_text() == "new\n"
            if (target / "new.txt").exists()
            else False
        )
        self.assertNotEqual(complete_old, complete_new)

    def test_unknown_name_exits_one_and_lists_valid_entries(self):
        entries = [self.entry(name="alpha"), self.entry(name="beta")]
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            status = FETCH_REFERENCES.main(["missing"], manifest=entries)
        self.assertEqual(status, 1)
        self.assertIn("alpha", stderr.getvalue())
        self.assertIn("beta", stderr.getvalue())

    def test_list_prints_every_manifest_entry_name(self):
        entries = [self.entry(name="alpha"), self.entry(name="beta")]
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            status = FETCH_REFERENCES.main(["--list"], manifest=entries)
        self.assertEqual(status, 0)
        self.assertIn("alpha", stdout.getvalue())
        self.assertIn("beta", stdout.getvalue())

    def subprocess_driver(self, *, force):
        return textwrap.dedent(
            f"""\
            import importlib.util
            import pathlib
            import sys
            spec = importlib.util.spec_from_file_location("fetch_references_child", {str(SCRIPT)!r})
            module = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = module
            spec.loader.exec_module(module)
            entry = module.Reference(
                name="fixture",
                url={str(self.origin)!r},
                pin={self.pinned_sha!r},
                sparse_cone=("cone-a",),
                why="fixture",
                release_tag=None,
            )
            module.fetch_reference(
                entry,
                references_dir=pathlib.Path({str(self.references)!r}),
                force={force!r},
            )
            """
        )


if __name__ == "__main__":
    unittest.main()
