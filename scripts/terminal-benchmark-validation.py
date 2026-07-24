#!/usr/bin/env python3
"""Predeclare and evaluate held-out trials for the frozen paired benchmark rule."""
import argparse
import hashlib
import json
import os
import pathlib
import random
import subprocess


WORKLOADS = (
    "terminal-feed",
    "scrollback-stream",
    "content-churn",
    "style-churn",
    "incremental-mixed",
)
DIRECTIONS = ("aa", "slower", "faster")
CANONICAL_GEOMETRY = {"columns": 179, "rows": 66}
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
                "directionalThresholdPercent": 2.5,
            },
            "scrollback-stream": {
                "pairCount": 2,
                "directionalThresholdPercent": 2.5,
            },
            "content-churn": {
                "pairCount": 4,
                "directionalThresholdPercent": 3.2,
            },
            "style-churn": {
                "pairCount": 4,
                "directionalThresholdPercent": 3.25,
            },
            "incremental-mixed": {
                "pairCount": 12,
                "directionalThresholdPercent": 3.25,
            },
        },
    },
    "confirm": {
        "effectPercent": 3,
        "estimator": "winsorized-mean-20",
        "equivalenceBandPercent": 0.75,
        "workloads": {
            "terminal-feed": {
                "pairCount": 2,
                "directionalThresholdPercent": 2.5,
            },
            "scrollback-stream": {
                "pairCount": 4,
                "directionalThresholdPercent": 2.15,
            },
            "content-churn": {
                "pairCount": 48,
                "directionalThresholdPercent": 1.65,
            },
            "style-churn": {
                "pairCount": 32,
                "directionalThresholdPercent": 2.0,
            },
            "incremental-mixed": {
                "pairCount": 40,
                "directionalThresholdPercent": 2.1,
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


def next_attempt(trial, ledger):
    """Consume one trial's primary and replacement seeds strictly in declaration order."""
    attempts = [entry for entry in ledger if entry["trialId"] == trial["id"]]
    if any(entry["valid"] for entry in attempts):
        raise ValueError(f"{trial['id']} already has a valid result")
    seeds = [trial["seed"], *trial["replacementSeeds"]]
    if len(attempts) >= len(seeds):
        raise ValueError(f"{trial['id']} replacement schedule exhausted")
    return {"attempt": len(attempts), "seed": seeds[len(attempts)]}


def record_attempt(
    ledger, *, trial, seed, valid, evidence, invalidation_reasons
):
    """Append raw evidence without deleting invalid attempts or permitting seed skips."""
    expected = next_attempt(trial, ledger)
    if seed != expected["seed"]:
        raise ValueError(
            f"{trial['id']} expected seed {expected['seed']}, received {seed}"
        )
    if valid and invalidation_reasons:
        raise ValueError("valid attempts cannot have invalidation reasons")
    if not valid and not invalidation_reasons:
        raise ValueError("invalid attempts require an invalidation reason")
    entry = {
        "trialId": trial["id"],
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


def _trials_by_id(manifest):
    trials = {}
    for mode in ("quick", "confirm"):
        for trial in manifest[mode]:
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
    trials = _trials_by_id(manifest)
    ledger = []
    ledger_path = pathlib.Path(ledger_path)
    if ledger_path.exists():
        for line_number, line in enumerate(
            ledger_path.read_text(encoding="utf-8").splitlines(), 1
        ):
            try:
                entry = json.loads(line)
                trial = trials[entry["trialId"]]
            except (json.JSONDecodeError, KeyError) as error:
                raise ValueError(
                    f"invalid ledger entry on line {line_number}"
                ) from error
            expected_entry = record_attempt(
                ledger,
                trial=trial,
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
    valid_trial_ids = {
        entry["trialId"] for entry in ledger if entry["valid"]
    }
    for mode in ("quick", "confirm"):
        for trial in manifest[mode]:
            if trial["id"] not in valid_trial_ids:
                attempt = next_attempt(trial, ledger)
                return {
                    "trial": trial,
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
        elif start_state["powerSource"] != "AC Power":
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
    """Bind each arm to a fresh optimized app harness invocation per block."""
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


def collect_content_churn(blocks, *, run_block):
    """Collect persistent serialized redraws at the post-settling measurement seam."""
    if not blocks:
        raise ValueError("content-churn collection requires at least one block")
    raw_blocks = []
    reasons = []
    arm_identities = {}
    process_owners = {}
    session_owners = {}
    expected_sequences = list(range(1, 51))
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
        block = {
            "index": index,
            **planned,
            "processId": artifact.get("processId"),
            "sessionId": artifact.get("sessionId"),
            "resetEvidence": reset,
            "drawCount": draw.get("drawCount"),
            "drawNanosecondsPerDraw": normalized,
            "machineStateSamples": draw.get("machineStateSamples", []),
            "artifact": artifact,
        }
        raw_blocks.append(block)

        if artifact.get("backend") != "swift":
            _append_reason(reasons, f"{prefix}-wrong-backend")
        if artifact.get("workload") != "full-screen-content-churn":
            _append_reason(reasons, f"{prefix}-wrong-workload")
        if artifact.get("fixtureIdentity") != "full-screen-content-churn":
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
        expected_dirty_rows = artifact.get("geometry", {}).get("rows")
        if (
            expected_dirty_rows != CANONICAL_GEOMETRY["rows"]
            or len(dirty_rows) != 50
            or any(value != expected_dirty_rows for value in dirty_rows)
        ):
            _append_reason(reasons, f"{prefix}-incomplete-full-row-damage")
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
        "workload": "content-churn",
        "fixtureIdentity": "full-screen-content-churn",
        "rawBlocks": raw_blocks,
        "valid": not reasons,
        "invalidationReasons": reasons,
    }


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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--seed", type=int, default=2026072404)
    arguments = parser.parse_args()
    manifest = make_manifest(seed=arguments.seed)
    arguments.output.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
