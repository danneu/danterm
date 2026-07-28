#!/usr/bin/env python3
"""Predeclare and evaluate held-out trials for the frozen paired benchmark rule."""
import argparse
import hashlib
import json
import os
import pathlib
import random
import shlex
import signal
import subprocess
import sys
import time


WORKLOADS = (
    "terminal-feed",
    "scrollback-stream",
    "content-churn",
    "style-churn",
    "incremental-mixed",
)
DIRECTIONS = ("aa", "slower", "faster")
CANONICAL_GEOMETRY = {"columns": 179, "rows": 66}
TERMINAL_FEED_STATE_PROBE = (
    pathlib.Path(__file__).with_name("terminal-benchmark-state-probe.swift")
)
BLOCK_CONTRACTS = {
    "terminal-feed": {
        "metric": "feed-nanoseconds-per-fresh-terminal-execution",
        "measuredUnit": "duration-stable-fixed-execution-batch",
        "minimumBlockNanoseconds": 1_000_000_000,
        "reset": "fresh-179x66-terminal-per-execution",
    },
    "scrollback-stream": {
        "metric": "final-draw-nanoseconds-per-fixture-replay",
        "measuredUnit": "one-25000-line-fixture-replay",
        "reset": "fresh-optimized-app-and-terminal-session-per-block",
    },
    "content-churn": {
        "metric": "draw-nanoseconds-per-draw",
        "measuredUnit": "serialized-completed-draw",
        "exactCompletedDraws": 50,
        "reset": "settled-dense-screen-before-block",
    },
    "style-churn": {
        "metric": "draw-nanoseconds-per-draw",
        "measuredUnit": "serialized-completed-draw",
        "exactCompletedDraws": 50,
        "reset": "settled-dense-screen-before-block",
    },
    "incremental-mixed": {
        "metric": "draw-nanoseconds-per-draw",
        "measuredUnit": "serialized-completed-draw",
        "exactCompletedDraws": 50,
        "reset": "settled-dense-screen-before-block",
    },
}
DECISION_RULES = {
    "quick": {
        "effectPercent": 5,
        "estimator": "median",
        "equivalenceBandPercent": 1.0,
        "workloads": {
            "terminal-feed": {
                "pairCount": 2,
                "directionalThresholdPercent": 4.5,
            },
            "scrollback-stream": {
                "pairCount": 2,
                "directionalThresholdPercent": 4.05,
            },
            "content-churn": {
                "pairCount": 2,
                "directionalThresholdPercent": 4.05,
            },
            "style-churn": {
                "pairCount": 2,
                "directionalThresholdPercent": 4.05,
            },
            "incremental-mixed": {
                "pairCount": 2,
                "directionalThresholdPercent": 3.8,
            },
        },
        # Plan-time rules, calibrated separately from the draw rules above and
        # applied to the same blocks. A workload appears here only if a threshold
        # cleared the accuracy gates at the pair count its draw rule already
        # collects -- plan time rides those blocks and cannot buy more of them.
        # `incremental-mixed` is absent because its plan-time A/A spread (SD
        # 5.75%) clears nothing; see agent-docs/terminal-performance.md.
        #
        # Source: 24-pair A/A series at tree e72190b4d542, zero quartets
        # discarded, 50,000 resampling trials per condition:
        #   content-churn median -0.58%, SD 1.48%, range -3.06%..+1.49%
        #     -> +/-2.5%, A/A false positives 0.0000, detection 1.0000 at 5%
        #   style-churn   median -0.72%, SD 1.22%, range -2.67%..+1.46%
        #     -> +/-2.5%, A/A false positives 0.0000, detection 0.9573 at 5%
        "planWorkloads": {
            "content-churn": {
                "pairCount": 2,
                "directionalThresholdPercent": 2.5,
                "equivalenceBandPercent": 1.0,
            },
            "style-churn": {
                "pairCount": 2,
                "directionalThresholdPercent": 2.5,
                "equivalenceBandPercent": 1.0,
            },
        },
    },
    "confirm": {
        "effectPercent": 3,
        "estimator": "median",
        "equivalenceBandPercent": 0.75,
        "workloads": {
            "terminal-feed": {
                "pairCount": 2,
                "directionalThresholdPercent": 2.5,
            },
            "scrollback-stream": {
                "pairCount": 4,
                "directionalThresholdPercent": 1.85,
            },
            "content-churn": {
                "pairCount": 4,
                "directionalThresholdPercent": 2.15,
            },
            "style-churn": {
                "pairCount": 4,
                "directionalThresholdPercent": 2.0,
            },
            "incremental-mixed": {
                "pairCount": 6,
                "directionalThresholdPercent": 1.85,
            },
        },
    },
}


def _trial(*, mode, workload, condition, index, seed, physical_arm):
    return {
        "id": f"{mode}:{workload}:{condition}:{index:02d}",
        "mode": mode,
        "workload": workload,
        "condition": condition,
        "index": index,
        "seed": seed,
        "physicalCandidateArm": physical_arm,
    }


def make_manifest(*, seed, trials_per_cell=60, replacements_per_trial=8):
    """Freeze trial order, seeds, and physical-arm assignment before collection."""
    generator = random.Random(seed)
    used_seeds = set()

    def fresh_seed():
        value = generator.randrange(1, 2**63)
        while value in used_seeds:
            value = generator.randrange(1, 2**63)
        used_seeds.add(value)
        return value

    def cell(mode, workload, condition):
        trials = []
        for index in range(trials_per_cell):
            trial = _trial(
                mode=mode,
                workload=workload,
                condition=condition,
                index=index,
                seed=fresh_seed(),
                physical_arm="a" if index % 2 == 0 else "b",
            )
            trial["replacementSeeds"] = [
                fresh_seed() for _ in range(replacements_per_trial)
            ]
            trials.append(trial)
        generator.shuffle(trials)
        return trials

    quick = []
    for workload in WORKLOADS:
        for condition in DIRECTIONS:
            quick.extend(cell("quick", workload, condition))

    confirm = cell("confirm", "suite", "aa")
    for workload in WORKLOADS:
        for condition in ("slower", "faster"):
            confirm.extend(cell("confirm", workload, condition))
    return {
        "schemaVersion": 2,
        "manifestSeed": seed,
        "trialsPerCell": trials_per_cell,
        "replacementsPerTrial": replacements_per_trial,
        "blockContracts": BLOCK_CONTRACTS,
        "decisionRules": DECISION_RULES,
        "quick": quick,
        "confirm": confirm,
    }


def next_attempt(trial, ledger, *, collection_index):
    """Consume one trial's primary and replacement seeds strictly in declaration order."""
    attempts = [
        entry for entry in ledger
        if entry["collectionIndex"] == collection_index
    ]
    if any(entry["valid"] for entry in attempts):
        raise ValueError("collection identity already has a valid result")
    seeds = [trial["seed"], *trial["replacementSeeds"]]
    if len(attempts) >= len(seeds):
        raise ValueError("collection identity replacement schedule exhausted")
    return {"attempt": len(attempts), "seed": seeds[len(attempts)]}


def record_attempt(
    ledger,
    *,
    trial,
    collection_index,
    seed,
    valid,
    evidence,
    invalidation_reasons,
):
    """Append raw evidence without deleting invalid attempts or permitting seed skips."""
    expected = next_attempt(
        trial, ledger, collection_index=collection_index
    )
    if seed != expected["seed"]:
        raise ValueError(
            f"collection identity expected seed {expected['seed']}, "
            f"received {seed}"
        )
    if valid and invalidation_reasons:
        raise ValueError("valid attempts cannot have invalidation reasons")
    if not valid and not invalidation_reasons:
        raise ValueError("invalid attempts require an invalidation reason")
    entry = {
        "collectionIndex": collection_index,
        "attempt": expected["attempt"],
        "seed": seed,
        "valid": valid,
        "evidence": evidence,
        "invalidationReasons": list(invalidation_reasons),
    }
    ledger.append(entry)
    return entry


def make_collection_plan(manifest, trial, seed):
    """Derive raw block work without carrying the held-out condition into collection."""
    if seed not in [trial["seed"], *trial["replacementSeeds"]]:
        raise ValueError(f"{trial['id']} received an undeclared seed")
    if trial["mode"] == "quick":
        workloads = (trial["workload"],)
    elif trial["mode"] == "confirm":
        workloads = WORKLOADS
    else:
        raise ValueError(f"unknown trial mode {trial['mode']}")

    generator = random.Random(seed)
    plan = {}
    for workload in workloads:
        pair_count = manifest["decisionRules"][trial["mode"]]["workloads"][
            workload
        ]["pairCount"]
        if pair_count % 2:
            raise ValueError(f"{workload} pair count must form complete quartets")
        blocks = []
        for _ in range(pair_count // 2):
            schedule = generator.choice(("ABBA", "BAAB"))
            for role in schedule:
                physical_arm = (
                    trial["physicalCandidateArm"]
                    if role == "B"
                    else ("b" if trial["physicalCandidateArm"] == "a" else "a")
                )
                blocks.append({
                    "measurementRole": role,
                    "physicalArm": physical_arm,
                })
        plan[workload] = blocks
    return plan


def _ordered_trials(manifest):
    return [
        trial
        for mode in ("quick", "confirm")
        for trial in manifest[mode]
    ]


def _trials_by_id(manifest):
    trials = {}
    for trial in _ordered_trials(manifest):
            if trial["id"] in trials:
                raise ValueError(f"duplicate manifest trial id {trial['id']}")
            trials[trial["id"]] = trial
    return trials


def load_collection(manifest_path, ledger_path, *, expected_manifest_sha256=None):
    """Load a hash-pinned manifest and replay its append-only attempt ledger."""
    manifest_path = pathlib.Path(manifest_path)
    manifest_bytes = manifest_path.read_bytes()
    actual_hash = hashlib.sha256(manifest_bytes).hexdigest()
    if (
        expected_manifest_sha256 is not None
        and actual_hash != expected_manifest_sha256
    ):
        raise ValueError(
            "manifest SHA-256 mismatch: "
            f"expected {expected_manifest_sha256}, received {actual_hash}"
        )
    manifest = json.loads(manifest_bytes)
    trials = _ordered_trials(manifest)
    _trials_by_id(manifest)
    ledger = []
    ledger_path = pathlib.Path(ledger_path)
    if ledger_path.exists():
        for line_number, line in enumerate(
            ledger_path.read_text(encoding="utf-8").splitlines(), 1
        ):
            try:
                entry = json.loads(line)
                collection_index = entry["collectionIndex"]
                trial = trials[collection_index]
            except (json.JSONDecodeError, KeyError, IndexError, TypeError) as error:
                raise ValueError(
                    f"invalid ledger entry on line {line_number}"
                ) from error
            expected_entry = record_attempt(
                ledger,
                trial=trial,
                collection_index=collection_index,
                seed=entry["seed"],
                valid=entry["valid"],
                evidence=entry["evidence"],
                invalidation_reasons=entry["invalidationReasons"],
            )
            if entry != expected_entry:
                raise ValueError(
                    f"ledger entry on line {line_number} was modified"
                )
    return {
        "manifest": manifest,
        "manifestSha256": actual_hash,
        "ledger": ledger,
    }


def next_collection_attempt(manifest, ledger):
    """Resume the first incomplete manifest identity in its frozen order."""
    valid_collection_indices = {
        entry["collectionIndex"] for entry in ledger if entry["valid"]
    }
    for collection_index, trial in enumerate(_ordered_trials(manifest)):
        if collection_index not in valid_collection_indices:
            attempt = next_attempt(
                trial, ledger, collection_index=collection_index
            )
            return {
                "trial": trial,
                "collectionIndex": collection_index,
                "attempt": attempt["attempt"],
                "seed": attempt["seed"],
                "plan": make_collection_plan(
                    manifest, trial, attempt["seed"]
                ),
            }
    return None


def append_collection_attempt(
    ledger_path,
    ledger,
    *,
    trial,
    collection_index,
    seed,
    valid,
    evidence,
    invalidation_reasons,
):
    """Durably append one attempt only after validating its declared seed order."""
    prospective = list(ledger)
    entry = record_attempt(
        prospective,
        trial=trial,
        collection_index=collection_index,
        seed=seed,
        valid=valid,
        evidence=evidence,
        invalidation_reasons=invalidation_reasons,
    )
    ledger_path = pathlib.Path(ledger_path)
    ledger_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(
        ledger_path,
        os.O_APPEND | os.O_CREAT | os.O_WRONLY,
        0o600,
    )
    try:
        with os.fdopen(descriptor, "a", encoding="utf-8") as output:
            output.write(json.dumps(entry, sort_keys=True) + "\n")
            output.flush()
            os.fsync(output.fileno())
    except BaseException:
        raise
    ledger.append(entry)
    return entry


def _append_reason(reasons, reason):
    if reason not in reasons:
        reasons.append(reason)


def _battery_runs_allowed():
    """Whether a run on battery still counts, per explicit opt-in.

    Off by default because the decision thresholds are calibrated on AC power, and
    battery throttling widens the distribution they are compared against. The
    position-balanced schedule means a steady slowdown hits both arms alike and
    leaves the symmetric median unbiased, so the opt-in is defensible for reading
    direction -- but it does not restore the thresholds' calibrated error rates,
    which is why it must be asked for rather than assumed. Only `terminal-feed`
    ever enforced this; the four render collectors already accept battery.
    """
    return os.environ.get("DANTERM_BENCHMARK_ALLOW_BATTERY") == "1"


def collect_terminal_feed(
    blocks,
    *,
    minimum_block_nanoseconds,
    run_benchmark,
    sample_state,
):
    """Collect one planned feed series with a single discarded calibration."""
    if not blocks:
        raise ValueError("terminal-feed collection requires at least one block")
    calibration_arm = blocks[0]["physicalArm"]
    calibration = run_benchmark(calibration_arm, execution_count=None)
    batch_count = calibration["batchCount"]
    if batch_count < 1:
        raise ValueError("terminal-feed calibration returned an invalid batch count")

    raw_blocks = []
    reasons = []
    for index, planned in enumerate(blocks):
        start_state = sample_state()
        measured = run_benchmark(
            planned["physicalArm"], execution_count=batch_count
        )
        completion_state = sample_state()
        if measured["batchCount"] != batch_count:
            raise ValueError("terminal-feed runner changed the fixed batch count")
        if (
            len(measured["feedDurationNanoseconds"]) != 1
            or len(measured["sampleDurationNanoseconds"]) != 1
        ):
            raise ValueError("terminal-feed block must contain exactly one sample")
        duration = measured["sampleDurationNanoseconds"][0]
        normalized = measured["feedDurationNanoseconds"][0]
        raw_blocks.append({
            "index": index,
            **planned,
            "batchCount": batch_count,
            "feedDurationNanoseconds": normalized,
            "sampleDurationNanoseconds": duration,
            "machineStateSamples": [start_state, completion_state],
        })
        prefix = f"block-{index}"
        if duration < minimum_block_nanoseconds:
            _append_reason(reasons, f"{prefix}-below-duration-floor")
        if start_state["powerSource"] != completion_state["powerSource"]:
            _append_reason(reasons, f"{prefix}-power-source-changed")
        elif start_state["powerSource"] != "AC Power" and not _battery_runs_allowed():
            _append_reason(reasons, f"{prefix}-not-on-ac-power")
        for state in (start_state, completion_state):
            if state["lowPowerMode"]:
                _append_reason(reasons, f"{prefix}-low-power-mode")
            if state["thermalState"] != "nominal":
                _append_reason(
                    reasons,
                    f"{prefix}-thermal-pressure-{state['thermalState']}",
                )

    return {
        "workload": "terminal-feed",
        "calibration": {
            "physicalArm": calibration_arm,
            "batchCount": batch_count,
            "discardedSamples": [
                {
                    "feedDurationNanoseconds": feed,
                    "sampleDurationNanoseconds": duration,
                }
                for feed, duration in zip(
                    calibration["feedDurationNanoseconds"],
                    calibration["sampleDurationNanoseconds"],
                )
            ],
        },
        "rawBlocks": raw_blocks,
        "valid": not reasons,
        "invalidationReasons": reasons,
    }


def _power_source(pmset_output):
    marker = "Now drawing from '"
    for line in pmset_output.splitlines():
        if line.startswith(marker) and line.endswith("'"):
            power_source = line[len(marker):-1]
            if power_source:
                return power_source
    raise ValueError("pmset did not report a recognizable power source")


def make_terminal_feed_state_sampler(
    output_directory,
    *,
    source_path=TERMINAL_FEED_STATE_PROBE,
    run_command=subprocess.run,
):
    """Compile one native probe, then sample feed-block state outside the app."""
    output_directory = pathlib.Path(output_directory)
    output_directory.mkdir(parents=True, exist_ok=True)
    binary = output_directory / "terminal-feed-state-probe"
    run_command(
        [
            "xcrun",
            "swiftc",
            str(source_path),
            "-O",
            "-o",
            str(binary),
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    def sample():
        process_result = run_command(
            [str(binary)],
            check=True,
            capture_output=True,
            text=True,
        )
        try:
            process_state = json.loads(process_result.stdout)
        except json.JSONDecodeError as error:
            raise ValueError("state probe returned invalid JSON") from error
        thermal = process_state.get("thermalState")
        low_power = process_state.get("lowPowerMode")
        if thermal not in {"nominal", "fair", "serious", "critical", "unknown"}:
            raise ValueError("state probe returned an invalid thermal state")
        if not isinstance(low_power, bool):
            raise ValueError("state probe returned an invalid low-power state")
        power_result = run_command(
            ["pmset", "-g", "batt"],
            check=True,
            capture_output=True,
            text=True,
        )
        return {
            "powerSource": _power_source(power_result.stdout),
            "thermalState": thermal,
            "lowPowerMode": low_power,
        }

    return sample


def terminal_feed_fixture(root):
    """Frame the committed four-stream corpus exactly as the Swift harness expects."""
    from terminal_benchmark_fixtures import iter_bytes, load_corpus

    root = pathlib.Path(root)
    framed = bytearray()
    for workload in load_corpus(root).values():
        for chunk in iter_bytes(root, workload):
            framed.extend(len(chunk).to_bytes(8, byteorder="big"))
            framed.extend(chunk)
    return bytes(framed)


def make_terminal_feed_runner(arm_roots, framed_fixture):
    """Bind physical arms to release harnesses while leaving scheduling to the manifest."""
    roots = {arm: pathlib.Path(root) for arm, root in arm_roots.items()}
    if set(roots) != {"a", "b"}:
        raise ValueError("terminal-feed runner requires physical arms a and b")

    def run(arm, *, execution_count):
        if arm not in roots:
            raise ValueError(f"unknown terminal-feed physical arm {arm}")
        arguments = ["2"] if execution_count is None else [
            "--fixed", str(execution_count), "1",
        ]
        command = [
            "swift", "run",
            "--package-path", str(roots[arm] / "lib" / "TerminalCore"),
            "--configuration", "release",
            "TerminalCoreBenchmark",
            *arguments,
        ]
        completed = subprocess.run(
            command,
            input=framed_fixture,
            capture_output=True,
        )
        if completed.returncode != 0:
            message = completed.stderr.decode(errors="replace").strip()
            raise RuntimeError(
                f"terminal-feed arm {arm} benchmark failed: {message}"
            )
        try:
            return json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise RuntimeError(
                f"terminal-feed arm {arm} returned invalid JSON"
            ) from error

    return run


def collect_scrollback_stream(blocks, *, run_block):
    """Collect fresh app replays and validate their exact marker-to-draw boundary."""
    if not blocks:
        raise ValueError("scrollback-stream collection requires at least one block")
    raw_blocks = []
    reasons = []
    process_ids = set()
    session_ids = set()
    for index, planned in enumerate(blocks):
        artifact = run_block(planned["physicalArm"])
        prefix = f"block-{index}"
        draw = artifact.get("finalDraw", {})
        producer = artifact.get("producerWrite", {})
        process_id = artifact.get("processId")
        session_id = artifact.get("sessionId")
        block = {
            "index": index,
            **planned,
            "processId": process_id,
            "sessionId": session_id,
            "startMarker": draw.get("startMarker"),
            "expectedFinalState": draw.get("expectedFinalState"),
            "producerWriteNanoseconds": producer.get("elapsedNanoseconds"),
            "finalDrawNanoseconds": draw.get("elapsedNanoseconds"),
            "machineStateSamples": draw.get("machineStateSamples", []),
            "artifact": artifact,
        }
        raw_blocks.append(block)

        if artifact.get("backend") != "swift":
            _append_reason(reasons, f"{prefix}-wrong-backend")
        if artifact.get("workload") != "scrollback-stream":
            _append_reason(reasons, f"{prefix}-wrong-workload")
        if artifact.get("fixtureIdentity") != (
            "scrollback-stream-v1-25000-lines"
        ):
            _append_reason(reasons, f"{prefix}-wrong-fixture")
        if artifact.get("geometry") != CANONICAL_GEOMETRY:
            _append_reason(reasons, f"{prefix}-wrong-geometry")
        if process_id is None or process_id in process_ids:
            _append_reason(reasons, f"{prefix}-app-process-not-fresh")
        if session_id is None or session_id in session_ids:
            _append_reason(reasons, f"{prefix}-terminal-session-not-fresh")
        process_ids.add(process_id)
        session_ids.add(session_id)
        if producer.get("event") != "producer-final-write-returned":
            _append_reason(reasons, f"{prefix}-missing-producer-write")
        valid_start_marker = (
            isinstance(draw.get("startMarker"), str)
            and draw["startMarker"].startswith("DANTERM-BENCH-START-")
        )
        if not valid_start_marker:
            _append_reason(reasons, f"{prefix}-invalid-start-marker")
        valid_final_marker = (
            isinstance(draw.get("expectedFinalState"), str)
            and draw["expectedFinalState"].startswith(
                "DANTERM-BENCH-FINAL-STATE-"
            )
        )
        if not valid_final_marker:
            _append_reason(reasons, f"{prefix}-invalid-final-state-marker")
        if (
            valid_start_marker
            and valid_final_marker
            and draw["startMarker"].removeprefix("DANTERM-BENCH-START-")
            != draw["expectedFinalState"].removeprefix(
                "DANTERM-BENCH-FINAL-STATE-"
            )
        ):
            _append_reason(reasons, f"{prefix}-marker-identity-mismatch")
        if (
            not draw.get("available")
            or draw.get("event") != "final-draw-completed"
            or not isinstance(draw.get("elapsedNanoseconds"), int)
        ):
            _append_reason(reasons, f"{prefix}-missing-final-completed-draw")
        if (
            isinstance(producer.get("elapsedNanoseconds"), int)
            and isinstance(draw.get("elapsedNanoseconds"), int)
            and draw["elapsedNanoseconds"] < producer["elapsedNanoseconds"]
        ):
            _append_reason(
                reasons, f"{prefix}-final-draw-preceded-producer-write"
            )
        for sample in draw.get("machineStateSamples", []):
            if sample.get("activeSpaceChanged", False):
                _append_reason(reasons, f"{prefix}-active-space-changed")
            if not sample.get("visible", False):
                _append_reason(reasons, f"{prefix}-window-occluded")
            thermal = sample.get("thermalState")
            if thermal != "nominal":
                _append_reason(
                    reasons, f"{prefix}-thermal-pressure-{thermal}"
                )
            if sample.get("lowPowerMode", False):
                _append_reason(reasons, f"{prefix}-low-power-mode")
        if not draw.get("machineStateSamples"):
            _append_reason(reasons, f"{prefix}-missing-machine-state")

    return {
        "workload": "scrollback-stream",
        "fixtureIdentity": "scrollback-stream-v1-25000-lines",
        "rawBlocks": raw_blocks,
        "valid": not reasons,
        "invalidationReasons": reasons,
    }


def make_scrollback_stream_runner(arm_roots):
    """Bind each arm to a fresh optimized app harness invocation per block.

    The per-arm `.a`/`.b` bundle namespace is deliberate and calibrated, not an
    oversight. The shared-namespace correction that the persistent draw arms use
    exists because those arms coexist; these blocks run one fresh app at a time.
    The A/A pilot that fed scrollback's screened pair count and threshold was
    collected through this same per-arm namespace, so its residual offset is
    already inside the frozen envelope -- switching to a shared namespace would
    move scrollback off the distribution its threshold was screened against.
    """
    roots = {arm: pathlib.Path(root) for arm, root in arm_roots.items()}
    if set(roots) != {"a", "b"}:
        raise ValueError("scrollback-stream runner requires physical arms a and b")

    def run(arm):
        if arm not in roots:
            raise ValueError(f"unknown scrollback-stream physical arm {arm}")
        environment = dict(os.environ)
        environment.update({
            "DANTERM_BENCHMARK_BUNDLE_SUFFIX": f".{arm}",
            "DANTERM_TERMINAL_BENCHMARK_COLUMNS": str(CANONICAL_GEOMETRY["columns"]),
            "DANTERM_TERMINAL_BENCHMARK_ROWS": str(CANONICAL_GEOMETRY["rows"]),
        })
        completed = subprocess.run(
            [
                str(roots[arm] / "scripts" / "terminal-benchmark.sh"),
                "scrollback-stream",
                "swift",
            ],
            cwd=roots[arm],
            env=environment,
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            raise RuntimeError(
                f"scrollback-stream arm {arm} benchmark failed: "
                f"{completed.stderr.strip()}"
            )
        try:
            return json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise RuntimeError(
                f"scrollback-stream arm {arm} returned invalid JSON"
            ) from error

    return run


# A measured block's acknowledgment is seconds of work, so 30s means "the app
# stopped answering". Arm startup is a different question: the harness compiles,
# signs, launches, and converges geometry before it writes its identity, which is
# minutes on a cold cache. Sharing one budget silently made a cold build a
# failure, so startup gets its own ceiling and relies on `abort_if` -- not on a
# short timeout -- to notice an arm that died.
PERSISTENT_STARTUP_TIMEOUT_SECONDS = 600


def _wait_for_path(path, timeout_seconds=30, abort_if=None):
    """Bound every persistent block so a lost app acknowledgment cannot hang a trial."""
    deadline = time.monotonic() + timeout_seconds
    while not path.exists():
        if abort_if is not None and abort_if():
            raise RuntimeError(f"process exited before writing {path}")
        if time.monotonic() >= deadline:
            raise TimeoutError(str(path))
        time.sleep(0.02)


def _read_block_artifact(path, wait_for_path):
    """Read one block artifact, turning an expired wait into recorded evidence.

    The caller's contract is that an unreadable artifact invalidates its block,
    not that it aborts the invocation -- so the absence is returned in the shape
    the block assertions already judge.
    """
    try:
        wait_for_path(path)
    except TimeoutError:
        return {"waitExpired": str(path)}
    return json.loads(path.read_text())


def _persistent_cli(identity, *arguments):
    """Address only the isolated app described by a persistent harness identity."""
    binary = pathlib.Path(identity["binary"])
    cli = binary.parent.parent / "Helpers" / "danterm"
    probe = json.loads(
        (pathlib.Path(identity["artifacts"]) / "path-probe.json").read_text()
    )
    environment = dict(os.environ)
    environment["DANTERM_SOCK"] = probe["socket"]
    return subprocess.run(
        [str(cli), *arguments],
        env=environment,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def _persistent_pane(identity):
    """Resolve the live focused pane instead of carrying a stale session identifier."""
    model = json.loads(_persistent_cli(identity, "ls"))
    selected = model["selectedTabId"]
    for group in model["groups"]:
        for tab in group["tabs"]:
            if tab["id"] == selected:
                return tab["focusedPaneId"]
    raise RuntimeError("persistent benchmark pane not found")


def _send_persistent_input(identity, pane, arguments):
    """Inject one producer command through the owning benchmark app's CLI socket."""
    _persistent_cli(identity, "pane", "input", "--pane", pane, *arguments)


def _front_persistent_app(pid):
    """Make the owned benchmark window visible before sampling machine state."""
    subprocess.run(
        [
            "/usr/bin/osascript",
            "-e",
            "tell application \"System Events\" to set frontmost of first process "
            f"whose unix id is {pid} to true",
        ],
        check=True,
        capture_output=True,
        text=True,
    )


class PersistentDrawArms:
    """Own two isolated persistent harnesses that share the calibrated bundle identity."""

    def __init__(
        self,
        arm_roots,
        *,
        workload,
        output,
        popen=subprocess.Popen,
        wait_for_path=_wait_for_path,
        kill=os.kill,
    ):
        self.roots = {
            arm: pathlib.Path(root) for arm, root in arm_roots.items()
        }
        if set(self.roots) != {"a", "b"}:
            raise ValueError("persistent lifecycle requires physical arms a and b")
        if workload not in (
            "full-screen-content-churn",
            "full-screen-style-churn",
            "full-screen-incremental-mixed-churn",
        ):
            raise ValueError(f"unsupported persistent draw workload {workload}")
        self.workload = workload
        self.output = pathlib.Path(output)
        self.popen = popen
        self.wait_for_path = wait_for_path
        self.kill = kill
        self.processes = {}
        self.logs = {}
        self.identities = {}

    def start(self):
        """Launch and validate both arms before exposing either to collection."""
        if self.processes:
            raise RuntimeError("persistent lifecycle already started")
        self.output.mkdir(parents=True, exist_ok=True)
        try:
            for arm in ("a", "b"):
                identity_path = self.output / f"{arm}-identity.json"
                identity_path.unlink(missing_ok=True)
                log = (self.output / f"{arm}-harness.log").open(
                    "w", encoding="utf-8"
                )
                environment = dict(os.environ)
                environment.update({
                    "DANTERM_BENCHMARK_MODE": "persistent",
                    # The frozen calibration removed the stable .a/.b namespace
                    # offset while retaining per-launch homes, sockets, and paths.
                    "DANTERM_BENCHMARK_BUNDLE_SUFFIX": "",
                    "DANTERM_BENCHMARK_IDENTITY_PATH": str(identity_path),
                    "DANTERM_TERMINAL_BENCHMARK_COLUMNS": str(
                        CANONICAL_GEOMETRY["columns"]
                    ),
                    "DANTERM_TERMINAL_BENCHMARK_ROWS": str(
                        CANONICAL_GEOMETRY["rows"]
                    ),
                    "DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES": "50",
                })
                process = self.popen(
                    [
                        str(
                            self.roots[arm]
                            / "scripts"
                            / "terminal-benchmark.sh"
                        ),
                        self.workload,
                        "swift",
                    ],
                    cwd=self.roots[arm],
                    env=environment,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
                self.processes[arm] = process
                self.logs[arm] = log
                self.wait_for_path(
                    identity_path,
                    timeout_seconds=PERSISTENT_STARTUP_TIMEOUT_SECONDS,
                    abort_if=lambda: process.poll() is not None,
                )
                identity = json.loads(identity_path.read_text())
                if process.poll() is not None:
                    raise RuntimeError(
                        f"persistent arm {arm} exited during startup"
                    )
                if identity.get("backend") != "swift":
                    raise ValueError(f"persistent arm {arm} has wrong backend")
                if identity.get("workload") != self.workload:
                    raise ValueError(f"persistent arm {arm} has wrong workload")
                if identity.get("geometry") != CANONICAL_GEOMETRY:
                    raise ValueError(f"persistent arm {arm} has wrong geometry")
                if not isinstance(identity.get("pid"), int):
                    raise ValueError(f"persistent arm {arm} has invalid pid")
                self.identities[arm] = identity
            if (
                self.identities["a"]["pid"]
                == self.identities["b"]["pid"]
            ):
                raise ValueError("persistent arms share an app process")
            return dict(self.identities)
        except BaseException:
            self.close()
            raise

    def close(self):
        """Stop only harness processes launched by this lifecycle owner."""
        for process in self.processes.values():
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
        for process in self.processes.values():
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        self._stop_orphaned_apps()
        for log in self.logs.values():
            log.close()
        self.processes.clear()
        self.logs.clear()

    def _stop_orphaned_apps(self):
        """Stop any benchmark app whose wrapper died without tearing it down.

        `close()` SIGKILLs a wrapper that outlives its grace period, and a
        SIGKILLed shell never runs the EXIT trap that would stop the app it
        launched. Ownership survives that because the identity file records the
        app's own pid, which `start()` has already validated -- so this reaps
        exactly the processes this lifecycle created and nothing else.

        Liveness is probed first so a wrapper that did tear its app down is left
        alone, which keeps a recycled pid from being signalled.
        """
        for identity in self.identities.values():
            pid = identity.get("pid")
            if not isinstance(pid, int):
                continue
            try:
                self.kill(pid, 0)
            except OSError:
                continue
            try:
                self.kill(pid, signal.SIGKILL)
            except OSError:
                pass


def make_persistent_draw_runner(
    identities,
    *,
    workload,
    root,
    resolve_pane=_persistent_pane,
    send_input=_send_persistent_input,
    front_app=_front_persistent_app,
    wait_for_path=_wait_for_path,
):
    """Bind redraw blocks to two already-converged persistent app arms."""
    if set(identities) != {"a", "b"}:
        raise ValueError("persistent draw runner requires physical arms a and b")
    fixture_identities = {
        "full-screen-content-churn": "full-screen-content-churn",
        "full-screen-style-churn": "full-screen-style-churn",
        "full-screen-incremental-mixed-churn": (
            "full-screen-incremental-mixed-churn-"
            "v2-four-rows-six-damage-179x66"
        ),
    }
    if workload not in fixture_identities:
        raise ValueError(f"unsupported persistent draw workload {workload}")
    root = pathlib.Path(root)

    def run(arm):
        if arm not in identities:
            raise ValueError(f"unknown persistent draw physical arm {arm}")
        identity = identities[arm]
        artifacts = pathlib.Path(identity["artifacts"])
        for name in (
            "start-ack",
            "start-draw-ack",
            "ready-draw-ack",
            "final-draw.json",
            "block-state.json",
            "producer-write.json",
        ):
            (artifacts / name).unlink(missing_ok=True)
        for path in artifacts.glob("localized-draw-*"):
            path.unlink()

        front_app(identity["pid"])
        pane = resolve_pane(identity)
        command = (
            "DANTERM_BENCHMARK_MODE=measure "
            "DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES=50 "
            f"python3 {shlex.quote(str(root / 'scripts' / 'terminal-benchmark-producer.py'))}"
        )
        send_input(identity, pane, ["--literal", "--", command])
        # `--` is required: the CLI's `pane input` grammar ends its options there,
        # and without it the key token is rejected as a usage error.
        send_input(identity, pane, ["--", "Enter"])

        result_path = artifacts / "final-draw.json"
        producer_path = artifacts / "producer-write.json"
        # An expired wait means the app or the producer stopped answering, which
        # is exactly the failure the block's evidence exists to explain. Raising
        # here would discard every other block in the invocation along with it,
        # so the artifact records the absence instead: `available: false` fails
        # `missing-final-completed-draw`, and an absent producer result fails
        # `missing-producer-write`, so the block is still invalid either way.
        draw = _read_block_artifact(result_path, wait_for_path)
        producer = _read_block_artifact(producer_path, wait_for_path)
        return {
            "schemaVersion": 1,
            "backend": "swift",
            "workload": workload,
            "fixtureIdentity": fixture_identities[workload],
            "processId": identity["pid"],
            "sessionId": pane,
            "geometry": identity["geometry"],
            "resetEvidence": {
                "denseSetupAndStartDrawCompleted":
                    (artifacts / "start-draw-ack").exists(),
                "settlingDrawCompleted":
                    (artifacts / "ready-draw-ack").exists(),
            },
            "producerWrite": producer,
            "finalDraw": {**draw, "available": "waitExpired" not in draw},
        }

    return run


def _collect_draw_churn(
    blocks,
    *,
    workload,
    artifact_workload,
    fixture_identity,
    expected_dirty_rows,
    damage_reason,
    run_block,
):
    """Enforce the shared serialized-draw contract with workload-specific damage."""
    if not blocks:
        raise ValueError(f"{workload} collection requires at least one block")
    raw_blocks = []
    reasons = []
    arm_identities = {}
    process_owners = {}
    session_owners = {}
    expected_sequences = list(range(50))
    for index, planned in enumerate(blocks):
        artifact = run_block(planned["physicalArm"])
        prefix = f"block-{index}"
        draw = artifact.get("finalDraw", {})
        producer = artifact.get("producerWrite", {})
        reset = artifact.get("resetEvidence", {})
        durations = draw.get("drawDurationsNanoseconds", [])
        dirty_rows = draw.get("dirtyRowCounts", [])
        cumulative = draw.get("cumulativeDrawNanoseconds")
        normalized = (
            cumulative // 50
            if isinstance(cumulative, int) and draw.get("drawCount") == 50
            else None
        )
        # Reported, never validated. Planning happens on the PTY-output path, so
        # the serialized-draw contract above says nothing about it, and an arm
        # built before the plan timer existed legitimately reports none of these
        # fields -- making its absence a block failure would void every
        # comparison whose baseline predates it.
        cumulative_plan = draw.get("cumulativePlanNanoseconds")
        normalized_plan = (
            cumulative_plan // 50
            if isinstance(cumulative_plan, int) and draw.get("planCount") == 50
            else None
        )
        block = {
            "index": index,
            **planned,
            "processId": artifact.get("processId"),
            "sessionId": artifact.get("sessionId"),
            "resetEvidence": reset,
            "drawCount": draw.get("drawCount"),
            "drawNanosecondsPerDraw": normalized,
            "planNanosecondsPerDraw": normalized_plan,
            "machineStateSamples": draw.get("machineStateSamples", []),
            "artifact": artifact,
        }
        raw_blocks.append(block)

        if artifact.get("backend") != "swift":
            _append_reason(reasons, f"{prefix}-wrong-backend")
        if artifact.get("workload") != artifact_workload:
            _append_reason(reasons, f"{prefix}-wrong-workload")
        if artifact.get("fixtureIdentity") != fixture_identity:
            _append_reason(reasons, f"{prefix}-wrong-fixture")
        if artifact.get("geometry") != CANONICAL_GEOMETRY:
            _append_reason(reasons, f"{prefix}-wrong-geometry")

        arm = planned["physicalArm"]
        identity = (artifact.get("processId"), artifact.get("sessionId"))
        if None in identity:
            _append_reason(reasons, f"{prefix}-missing-persistent-identity")
        elif arm in arm_identities and arm_identities[arm] != identity:
            _append_reason(reasons, f"{prefix}-persistent-identity-changed")
        else:
            arm_identities[arm] = identity
            for value, owners, label in (
                (identity[0], process_owners, "process"),
                (identity[1], session_owners, "session"),
            ):
                owner = owners.setdefault(value, arm)
                if owner != arm:
                    _append_reason(
                        reasons, f"{prefix}-{label}-shared-between-arms"
                    )

        if not all((
            reset.get("denseSetupAndStartDrawCompleted") is True,
            reset.get("settlingDrawCompleted") is True,
        )):
            _append_reason(reasons, f"{prefix}-reset-not-settled")
        if (
            not draw.get("available")
            or draw.get("event") != "final-draw-completed"
        ):
            _append_reason(reasons, f"{prefix}-missing-final-completed-draw")
        if draw.get("drawCount") != 50:
            _append_reason(reasons, f"{prefix}-wrong-draw-count")
        if draw.get("drawSequences") != expected_sequences:
            _append_reason(reasons, f"{prefix}-draw-sequence-contract-violated")
        if (
            not isinstance(cumulative, int)
            or not isinstance(durations, list)
            or cumulative != sum(
                value for value in durations if isinstance(value, int)
            )
            or any(not isinstance(value, int) for value in durations)
        ):
            _append_reason(reasons, f"{prefix}-cumulative-draw-mismatch")
        if (
            len(dirty_rows) != 50
            or any(value != expected_dirty_rows for value in dirty_rows)
        ):
            _append_reason(reasons, f"{prefix}-{damage_reason}")
        if producer.get("event") != "producer-final-write-returned":
            _append_reason(reasons, f"{prefix}-missing-producer-write")
        for sample in draw.get("machineStateSamples", []):
            if sample.get("activeSpaceChanged", False):
                _append_reason(reasons, f"{prefix}-active-space-changed")
            if not sample.get("visible", False):
                _append_reason(reasons, f"{prefix}-window-occluded")
            thermal = sample.get("thermalState")
            if thermal != "nominal":
                _append_reason(
                    reasons, f"{prefix}-thermal-pressure-{thermal}"
                )
            if sample.get("lowPowerMode", False):
                _append_reason(reasons, f"{prefix}-low-power-mode")
        if not draw.get("machineStateSamples"):
            _append_reason(reasons, f"{prefix}-missing-machine-state")

    return {
        "workload": workload,
        "fixtureIdentity": fixture_identity,
        "rawBlocks": raw_blocks,
        "valid": not reasons,
        "invalidationReasons": reasons,
    }


def collect_content_churn(blocks, *, run_block):
    """Collect persistent content redraws at the post-settling measurement seam."""
    return _collect_draw_churn(
        blocks,
        workload="content-churn",
        artifact_workload="full-screen-content-churn",
        fixture_identity="full-screen-content-churn",
        expected_dirty_rows=CANONICAL_GEOMETRY["rows"],
        damage_reason="incomplete-full-row-damage",
        run_block=run_block,
    )


def collect_style_churn(blocks, *, run_block):
    """Collect persistent style-only redraws with complete viewport damage."""
    return _collect_draw_churn(
        blocks,
        workload="style-churn",
        artifact_workload="full-screen-style-churn",
        fixture_identity="full-screen-style-churn",
        expected_dirty_rows=CANONICAL_GEOMETRY["rows"],
        damage_reason="incomplete-full-row-damage",
        run_block=run_block,
    )


def collect_incremental_mixed(blocks, *, run_block):
    """Collect persistent incremental redraws with the fixed glyph-halo damage."""
    return _collect_draw_churn(
        blocks,
        workload="incremental-mixed",
        artifact_workload="full-screen-incremental-mixed-churn",
        fixture_identity=(
            "full-screen-incremental-mixed-churn-"
            "v2-four-rows-six-damage-179x66"
        ),
        expected_dirty_rows=6,
        damage_reason="wrong-damage-row-count",
        run_block=run_block,
    )


def collect_attempt(plan, *, collectors):
    """Collect one condition-free manifest plan and preserve all workload evidence."""
    unknown = set(plan) - set(WORKLOADS)
    missing = set(plan) - set(collectors)
    if unknown:
        raise ValueError(f"unknown planned workloads: {sorted(unknown)}")
    if missing:
        raise ValueError(f"missing workload collectors: {sorted(missing)}")
    evidence = {}
    reasons = []
    for workload, blocks in plan.items():
        workload_evidence = collectors[workload](blocks)
        if workload_evidence.get("workload") != workload:
            raise ValueError(f"{workload} collector returned mismatched evidence")
        evidence[workload] = workload_evidence
        for reason in workload_evidence.get("invalidationReasons", []):
            reasons.append(f"{workload}:{reason}")
    return {
        "workloads": evidence,
        "valid": not reasons,
        "invalidationReasons": reasons,
    }


def collect_next_attempt(
    manifest_path,
    ledger_path,
    *,
    expected_manifest_sha256,
    artifacts_root,
    make_collectors,
):
    """Collect and durably record exactly one hash-pinned resumable attempt."""
    collection = load_collection(
        manifest_path,
        ledger_path,
        expected_manifest_sha256=expected_manifest_sha256,
    )
    pending = next_collection_attempt(
        collection["manifest"], collection["ledger"]
    )
    if pending is None:
        return {"complete": True}

    attempt_name = (
        f"collection-{pending['collectionIndex']:06d}"
        f"-attempt-{pending['attempt']:02d}"
    )
    attempt_directory = pathlib.Path(artifacts_root) / attempt_name
    attempt_directory.mkdir(parents=True, exist_ok=True)
    collectors, close = make_collectors(
        pending["plan"], attempt_directory
    )
    try:
        evidence = collect_attempt(
            pending["plan"], collectors=collectors
        )
    finally:
        close()

    entry = append_collection_attempt(
        ledger_path,
        collection["ledger"],
        trial=pending["trial"],
        collection_index=pending["collectionIndex"],
        seed=pending["seed"],
        valid=evidence["valid"],
        evidence=evidence,
        invalidation_reasons=evidence["invalidationReasons"],
    )
    return {
        "complete": False,
        "collectionIndex": entry["collectionIndex"],
        "attempt": entry["attempt"],
        "seed": entry["seed"],
        "valid": entry["valid"],
        "invalidationReasons": entry["invalidationReasons"],
    }


def make_production_collectors(
    plan,
    attempt_directory,
    *,
    arm_roots,
    repository_root,
    sample_state,
    load_feed_fixture=terminal_feed_fixture,
    feed_runner_factory=make_terminal_feed_runner,
    scrollback_runner_factory=make_scrollback_stream_runner,
    lifecycle_factory=PersistentDrawArms,
    draw_runner_factory=make_persistent_draw_runner,
):
    """Bind a pending plan to production runners while owning all persistent apps."""
    unknown = set(plan) - set(WORKLOADS)
    if unknown:
        raise ValueError(f"unknown planned workloads: {sorted(unknown)}")
    attempt_directory = pathlib.Path(attempt_directory)
    repository_root = pathlib.Path(repository_root)
    collectors = {}
    lifecycles = []

    def close():
        for lifecycle in reversed(lifecycles):
            lifecycle.close()

    draw_workloads = {
        "content-churn": (
            "full-screen-content-churn",
            collect_content_churn,
        ),
        "style-churn": (
            "full-screen-style-churn",
            collect_style_churn,
        ),
        "incremental-mixed": (
            "full-screen-incremental-mixed-churn",
            collect_incremental_mixed,
        ),
    }
    try:
        if "terminal-feed" in plan:
            feed_runner = feed_runner_factory(
                arm_roots, load_feed_fixture(repository_root)
            )
            collectors["terminal-feed"] = lambda blocks: collect_terminal_feed(
                blocks,
                minimum_block_nanoseconds=BLOCK_CONTRACTS[
                    "terminal-feed"
                ]["minimumBlockNanoseconds"],
                run_benchmark=feed_runner,
                sample_state=sample_state,
            )
        if "scrollback-stream" in plan:
            scrollback_runner = scrollback_runner_factory(arm_roots)
            collectors["scrollback-stream"] = (
                lambda blocks: collect_scrollback_stream(
                    blocks, run_block=scrollback_runner
                )
            )
        for planned_workload, (app_workload, collector) in draw_workloads.items():
            if planned_workload not in plan:
                continue
            lifecycle = lifecycle_factory(
                arm_roots,
                workload=app_workload,
                output=attempt_directory / planned_workload,
            )
            lifecycles.append(lifecycle)
            identities = lifecycle.start()
            runner = draw_runner_factory(
                identities,
                workload=app_workload,
                root=repository_root,
            )
            collectors[planned_workload] = (
                lambda blocks, collect=collector, run=runner: collect(
                    blocks, run_block=run
                )
            )
    except BaseException:
        close()
        raise
    return collectors, close


def _counts(decisions, expected_direction):
    correct = sum(value == expected_direction for value in decisions)
    inconclusive = sum(value in ("inconclusive", "equivalent") for value in decisions)
    wrong = sum(
        value in ("slower", "faster") and value != expected_direction
        for value in decisions
    )
    return {
        "correctCount": correct,
        "inconclusiveCount": inconclusive,
        "wrongDirectionCount": wrong,
    }


def evaluate_quick_cell(decisions, *, expected_direction):
    """Apply D1's exact 60-trial quick acceptance rule."""
    if len(decisions) != 60:
        raise ValueError("quick cells require exactly 60 decisions")
    if expected_direction == "aa":
        directional = sum(value in ("slower", "faster") for value in decisions)
        return {"pass": directional == 0, "directionalCount": directional}
    counts = _counts(decisions, expected_direction)
    return {
        "pass": (
            counts["correctCount"] >= 54
            and counts["inconclusiveCount"] <= 6
            and counts["wrongDirectionCount"] == 0
        ),
        **counts,
    }


def evaluate_confirm_effect_cell(
    trials, *, injected_workload, expected_direction
):
    """Require the injected decision and no directional unchanged-workload claim."""
    if len(trials) != 60:
        raise ValueError("confirm cells require exactly 60 suite decisions")
    injected = [trial[injected_workload] for trial in trials]
    counts = _counts(injected, expected_direction)
    unchanged_directional = sum(
        decision in ("slower", "faster")
        for trial in trials
        for workload, decision in trial.items()
        if workload != injected_workload
    )
    return {
        "pass": (
            counts["correctCount"] >= 59
            and counts["inconclusiveCount"] <= 1
            and counts["wrongDirectionCount"] == 0
            and unchanged_directional == 0
        ),
        **counts,
        "unchangedDirectionalCount": unchanged_directional,
    }


def validate_results(manifest, results, *, calibration_seeds):
    """Reject reused seeds and any partial or selectively extended held-out set."""
    expected = {
        trial["id"]: trial
        for mode in ("quick", "confirm")
        for trial in manifest[mode]
    }
    actual = {trial["id"]: trial for trial in results}
    reused = {
        trial["seed"]
        for trial in results
        if trial["seed"] in calibration_seeds
    }
    if reused:
        raise ValueError(f"held-out result uses calibration seed: {min(reused)}")
    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    if missing or extra or len(actual) != len(results):
        raise ValueError(
            f"held-out result set mismatch: missing={len(missing)} extra={len(extra)}"
        )
    result_seeds = [trial["seed"] for trial in results]
    if len(result_seeds) != len(set(result_seeds)):
        raise ValueError("held-out result seed reused")
    for trial_id, planned in expected.items():
        for field in (
            "mode", "workload", "condition", "index",
            "physicalCandidateArm",
        ):
            if actual[trial_id].get(field) != planned[field]:
                raise ValueError(f"{trial_id} changed predeclared field {field}")
        allowed_seeds = {planned["seed"], *planned["replacementSeeds"]}
        if actual[trial_id]["seed"] not in allowed_seeds:
            raise ValueError(f"{trial_id} uses undeclared seed")
    return True


def _collect_one(
    arguments,
    *,
    collect_next,
    state_sampler_factory,
    production_collectors_factory,
):
    def bind_collectors(plan, attempt_directory):
        if "terminal-feed" in plan:
            sample_state = state_sampler_factory(
                attempt_directory / "terminal-feed-state"
            )
        else:
            sample_state = lambda: {}
        return production_collectors_factory(
            plan,
            attempt_directory,
            arm_roots={
                "a": arguments.arm_a_root,
                "b": arguments.arm_b_root,
            },
            repository_root=arguments.repository_root,
            sample_state=sample_state,
        )

    return collect_next(
        arguments.manifest,
        arguments.ledger,
        expected_manifest_sha256=arguments.manifest_sha256,
        artifacts_root=arguments.artifacts,
        make_collectors=bind_collectors,
    )


def main(
    argv=None,
    *,
    collect_next=collect_next_attempt,
    state_sampler_factory=make_terminal_feed_state_sampler,
    production_collectors_factory=make_production_collectors,
    stdout=None,
):
    """Generate a manifest or collect one hash-pinned production attempt."""
    argv = list(sys.argv[1:] if argv is None else argv)
    stdout = sys.stdout if stdout is None else stdout
    if not argv or argv[0] != "collect-one":
        parser = argparse.ArgumentParser()
        parser.add_argument("output", type=pathlib.Path)
        parser.add_argument("--seed", type=int, default=2026072404)
        arguments = parser.parse_args(argv)
        manifest = make_manifest(seed=arguments.seed)
        arguments.output.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        return 0

    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("collect-one",))
    parser.add_argument("--manifest", type=pathlib.Path, required=True)
    parser.add_argument("--manifest-sha256", required=True)
    parser.add_argument("--ledger", type=pathlib.Path, required=True)
    parser.add_argument("--artifacts", type=pathlib.Path, required=True)
    parser.add_argument("--arm-a-root", type=pathlib.Path, required=True)
    parser.add_argument("--arm-b-root", type=pathlib.Path, required=True)
    parser.add_argument(
        "--repository-root",
        type=pathlib.Path,
        default=pathlib.Path.cwd(),
    )
    arguments = parser.parse_args(argv)
    status = _collect_one(
        arguments,
        collect_next=collect_next,
        state_sampler_factory=state_sampler_factory,
        production_collectors_factory=production_collectors_factory,
    )
    stdout.write(json.dumps(status, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    main()
