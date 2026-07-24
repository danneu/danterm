#!/usr/bin/env python3
"""Prove the GUI-dependent half of the paired benchmark contract on a real session.

`just test-terminal-benchmark-gui` runs this. The hermetic suites in `just test`
can prove how block evidence is judged, but not that a real DanTerm window
actually reaches 179x66, stays fully contained and unoccluded across measured
blocks, produces its workload's reset and damage evidence, and that teardown
terminates exactly the apps the run launched and nothing else. Those need a
logged-in GUI session, so they live here.

It drives the same `production_collectors` binding `benchmark-quick` uses, with
both physical arms pointing at this checkout: the point is the workload contract
and process ownership, not a comparison, so one source tree is enough and no
decision is produced.
"""
import argparse
import contextlib
import importlib.util
import json
import os
import pathlib
import signal
import subprocess
import sys
import time


ROOT = pathlib.Path(__file__).resolve().parents[1]


def _load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


COMPARE = _load("terminal_benchmark_compare", "scripts/terminal-benchmark-compare.py")
VALIDATION = COMPARE.VALIDATION
# The bystander stands in for any DanTerm the operator already had running: a
# separate bundle namespace the run neither owns nor may disturb.
BYSTANDER_SUFFIX = ".bystander"


def make_schedule(workloads):
    """Give every workload one block per physical arm, the smallest contract-bearing run."""
    return {
        workload: [
            {"measurementRole": "A", "physicalArm": "a", "quartet": 0},
            {"measurementRole": "B", "physicalArm": "b", "quartet": 0},
        ]
        for workload in workloads
    }


def _wait_for_path(path, timeout_seconds):
    deadline = time.monotonic() + timeout_seconds
    while not path.exists():
        if time.monotonic() >= deadline:
            raise TimeoutError(f"timed out waiting for {path}")
        time.sleep(0.05)


def _process_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


@contextlib.contextmanager
def bystander_app(output):
    """Run an unrelated benchmark app for the whole contract run and stop only it."""
    output.mkdir(parents=True, exist_ok=True)
    identity_path = output / "bystander-identity.json"
    identity_path.unlink(missing_ok=True)
    environment = dict(os.environ)
    environment.update({
        "DANTERM_BENCHMARK_MODE": "persistent",
        "DANTERM_BENCHMARK_BUNDLE_SUFFIX": BYSTANDER_SUFFIX,
        "DANTERM_BENCHMARK_IDENTITY_PATH": str(identity_path),
        "DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES": "50",
    })
    log = (output / "bystander-harness.log").open("w", encoding="utf-8")
    process = subprocess.Popen(
        [
            str(ROOT / "scripts" / "terminal-benchmark.sh"),
            "full-screen-content-churn",
            "swift",
        ],
        cwd=ROOT,
        env=environment,
        stdout=log,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        _wait_for_path(identity_path, timeout_seconds=600)
        identity = json.loads(identity_path.read_text())
        yield identity
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        log.close()


def owned_app_pids(evidence):
    """Collect every app process the measured blocks reported as their own."""
    pids = set()
    for workload_evidence in evidence["workloads"].values():
        for block in workload_evidence["rawBlocks"]:
            pid = block.get("processId")
            if isinstance(pid, int):
                pids.add(pid)
    return pids


def check_geometry(evidence):
    """Every app-backed block must report the canonical grid it was required to reach."""
    failures = []
    for workload, workload_evidence in evidence["workloads"].items():
        for block in workload_evidence["rawBlocks"]:
            artifact = block.get("artifact")
            if artifact is None:
                continue
            if artifact.get("geometry") != VALIDATION.CANONICAL_GEOMETRY:
                failures.append(
                    f"{workload} block {block['index']} reported geometry "
                    f"{artifact.get('geometry')}"
                )
    return failures


def check_containment(evidence):
    """Containment and non-occlusion must hold in every sample of every measured block."""
    failures = []
    for workload, workload_evidence in evidence["workloads"].items():
        for block in workload_evidence["rawBlocks"]:
            samples = block.get("machineStateSamples", [])
            if workload == "terminal-feed":
                # The feed workload has no window; its samples carry machine state only.
                continue
            if not samples:
                failures.append(f"{workload} block {block['index']} sampled no window state")
            for position, sample in enumerate(samples):
                if not sample.get("visible", False):
                    failures.append(
                        f"{workload} block {block['index']} sample {position} "
                        "was occluded or not fully contained"
                    )
    return failures


def check_ownership(evidence, bystander_pid):
    """Teardown must end the run's own apps and leave an unrelated instance running."""
    failures = []
    for pid in sorted(owned_app_pids(evidence)):
        if _process_alive(pid):
            failures.append(f"benchmark app {pid} survived teardown")
    if bystander_pid in owned_app_pids(evidence):
        failures.append("the run measured the unrelated bystander app")
    if not _process_alive(bystander_pid):
        failures.append(f"unrelated app {bystander_pid} was terminated by the run")
    return failures


def run_contract(workloads, output):
    """Drive the production collectors once and judge the GUI contract they produced."""
    output.mkdir(parents=True, exist_ok=True)
    schedule = make_schedule(workloads)
    with bystander_app(output) as bystander:
        collectors, close = COMPARE.production_collectors(
            schedule,
            output,
            arm_roots={"a": ROOT, "b": ROOT},
            repository_root=ROOT,
        )
        try:
            evidence = VALIDATION.collect_attempt(schedule, collectors=collectors)
        finally:
            close()
        # Give the harnesses their SIGINT teardown before asking who is still alive.
        time.sleep(2)
        failures = check_ownership(evidence, bystander["pid"])
    failures.extend(check_geometry(evidence))
    failures.extend(check_containment(evidence))
    failures.extend(
        f"invalid block evidence: {reason}"
        for reason in evidence["invalidationReasons"]
    )
    report = {
        "schemaVersion": 1,
        "decisionEligible": False,
        "historyEligible": False,
        "workloads": list(workloads),
        "bystanderPid": bystander["pid"],
        "ownedAppPids": sorted(owned_app_pids(evidence)),
        "evidence": evidence,
        "failures": failures,
    }
    (output / "gui-contract.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return failures, output


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "workloads",
        nargs="*",
        default=None,
        help="workloads to prove; defaults to the complete ladder",
    )
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=ROOT / ".build" / "terminal-benchmark-gui-contract",
    )
    arguments = parser.parse_args(argv)
    workloads = tuple(arguments.workloads or VALIDATION.WORKLOADS)
    unknown = [name for name in workloads if name not in VALIDATION.WORKLOADS]
    if unknown:
        print(f"unknown workloads: {', '.join(unknown)}", file=sys.stderr)
        return 2

    failures, output = run_contract(workloads, arguments.output)
    if failures:
        print(f"terminal benchmark GUI contract FAILED; evidence: {output}")
        for failure in failures:
            print(f"  {failure}")
        return 1
    print(f"terminal benchmark GUI contract: ok; evidence: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
