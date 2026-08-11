#!/usr/bin/env bash
# Attach a command-line profiler to one isolated sustained benchmark app.
set -euo pipefail

terminate_owned_pid() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# Snapshot the app's lifetime draw counters outside the profiling window.
#
# A loop-mode app never completes a block, so its own accepted-draw accounting
# is never written and an attached profiler has no frame count to normalize its
# samples by. These two snapshots supply one. Called before the profiler
# attaches and again after it detaches, so the counted window brackets the
# profiled one rather than sitting inside it.
capture_activity() {
    local label="$1"
    local deadline=$((SECONDS + 5))
    while [[ ! -f "$ACTIVITY_PATH" ]]; do
        (( SECONDS < deadline )) || {
            echo "No draw counters published within 5s; frame accounting will be omitted." >&2
            return 0
        }
        sleep 0.1
    done
    cp "$ACTIVITY_PATH" "$PROFILE_ROOT/activity-$label.json"
}

# Derive the workload's draw rate from the two snapshots, so a profile's node
# costs can be stated per frame.
#
# The rate, not the count, is the usable output. The counted window strictly
# contains the profiled one -- and by much more than the publish cadence, because
# a profiler spends seconds attaching and seconds saving (measured: ~20s counted
# for a 12s xctrace run). Converting the rate back to a count over the profiled
# window is therefore an estimate, and is labelled as one. It is a sound estimate
# only because these are sustained steady-state workloads whose draw rate does not
# trend; nothing here would detect it if one did.
report_frame_accounting() {
    local before="$PROFILE_ROOT/activity-before.json"
    local after="$PROFILE_ROOT/activity-after.json"
    [[ -f "$before" && -f "$after" ]] || return 0
    jq -n --slurpfile before "$before" --slurpfile after "$after" \
        --argjson requestedSeconds "$DURATION" '
        ($before[0]) as $b | ($after[0]) as $a |
        (($a.uptimeNanoseconds - $b.uptimeNanoseconds) / 1000000000) as $elapsed |
        ($a.drawCount - $b.drawCount) as $draws |
        ($a.planFrameCount - $b.planFrameCount) as $planFrames |
        (if $elapsed > 0 then $draws / $elapsed else null end) as $drawsPerSecond |
        {
            schemaVersion: 2,
            clock: $a.clock,
            countsEveryDraw: true,
            measured: {
                countedSeconds: $elapsed,
                draws: $draws,
                planFrames: $planFrames,
                drawsPerSecond: $drawsPerSecond,
                planFramesPerDraw: (
                    if $draws > 0 then $planFrames / $draws else null end
                )
            },
            estimated: {
                profilerSeconds: $requestedSeconds,
                drawsInProfilerWindow: (
                    if $drawsPerSecond == null then null
                    else $drawsPerSecond * $requestedSeconds end
                ),
                basis: "measured draw rate times the profiler window; valid only because the workload is sustained and steady-state"
            },
            windowRelationship: "the counted window strictly contains the profiled one -- both snapshots sit outside it, and a profiler adds seconds of attach and save on top of the 100ms publish cadence. Use the rate; treat `measured.draws` as spanning more than the trace."
        }' >"$PROFILE_ROOT/frame-accounting.json"
    echo "Frame accounting: $PROFILE_ROOT/frame-accounting.json"
    jq . "$PROFILE_ROOT/frame-accounting.json"
}

MODE="${1:-loop}"
WORKLOAD="${2:-scrollback-stream}"
DURATION="${3:-15}"
TEMPLATE="${4:-Time Profiler}"
# Fourth positional is the Instruments template for `trace` and the warmup cutoff
# for `memory`; each mode reads only its own.
WARMUP="${4:-15}"
case "$MODE" in
    loop) max_arguments=2 ;;
    sample) max_arguments=3 ;;
    trace|memory) max_arguments=4 ;;
    *) echo "Unknown profiling mode: $MODE" >&2; exit 2 ;;
esac
(( $# <= max_arguments )) || {
    echo "Too many arguments for $MODE profiling mode" >&2
    exit 2
}
WORKLOAD="${WORKLOAD#workload=}"
DURATION="${DURATION#seconds=}"
TEMPLATE="${TEMPLATE#template=}"
WARMUP="${WARMUP#warmup=}"
for command in jq nm python3; do
    command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
done
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BTOP_WORKLOAD=""
# The live workload's admission and duration bounds are its own, so they are
# decided by the workload module and only reported here. This runs ahead of the
# generic duration check so a rejected btop window is named as one, and ahead of
# everything that costs anything: a refused invocation must not have compiled,
# built, or launched a thing.
if [[ "$WORKLOAD" == "btop-scroll" ]]; then
    BTOP_WORKLOAD=1
    btop_seconds=""
    [[ "$MODE" == "loop" ]] || btop_seconds="$DURATION"
    python3 "$SCRIPT_DIR/terminal_btop_workload.py" admit --mode "$MODE" --seconds "$btop_seconds"
fi
[[ "$DURATION" =~ ^[1-9][0-9]*$ ]] || { echo "Profiling duration must be whole seconds" >&2; exit 2; }
if [[ "$MODE" == memory ]]; then
    [[ "$WARMUP" =~ ^[0-9]+$ ]] || { echo "Memory warmup must be whole seconds" >&2; exit 2; }
    (( DURATION > WARMUP )) || { echo "Profiling duration must exceed the ${WARMUP}s warmup" >&2; exit 2; }
fi

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_ROOT="$REPO_ROOT/.build/terminal-benchmark-profiles/$(date +%Y-%m-%d-%H%M%S)-$$"
IDENTITY_PATH="$PROFILE_ROOT/identity.json"
HARNESS_IDENTITY_PATH="$PROFILE_ROOT/harness-identity.json"
HARNESS_LOG="$PROFILE_ROOT/harness.log"
ACTIVITY_PATH="$PROFILE_ROOT/activity.json"
HARNESS_PID=""
mkdir -p "$PROFILE_ROOT"
trap 'terminate_owned_pid "$HARNESS_PID"' EXIT INT TERM

# The stimulus is generated from the live geometry
# (`terminal-benchmark-producer.py`), so the identity has to name the geometry it
# actually ran at. Hardcoding one made every varied-geometry artifact claim a
# fixture it had not used -- see `research/17/F16`, which varied it deliberately.
geometry_label="${DANTERM_TERMINAL_BENCHMARK_COLUMNS:-179}x${DANTERM_TERMINAL_BENCHMARK_ROWS:-66}"
localized_updates=0
case "$WORKLOAD" in
    scrollback-stream)
        fixture_identity="$(jq -er '.workloads["scrollback-stream"].identity' "$REPO_ROOT/benchmarks/fixtures/terminal-app.json")"
        reset_behavior="fresh deterministic corpus replay; steady-state app/session caches intentionally persist"
        redraw_updates=0
        ;;
    full-screen-content-churn)
        fixture_identity="full-screen-content-churn-v2-serialized-$geometry_label"
        reset_behavior="full-screen deterministic setup plus excluded settling draw before serialized draws"
        redraw_updates=1000000
        ;;
    full-screen-style-churn)
        fixture_identity="full-screen-style-churn-v2-serialized-$geometry_label"
        reset_behavior="full-screen deterministic setup plus excluded settling draw before serialized draws"
        redraw_updates=1000000
        ;;
    full-screen-incremental-mixed-churn)
        fixture_identity="full-screen-incremental-mixed-churn-v3-four-rows-one-span-$geometry_label"
        reset_behavior="dense deterministic setup plus excluded settling draw before four-row content-and-style updates damaging four rows in one span"
        redraw_updates=1000000
        ;;
    btop-scroll)
        # The one workload with no deterministic corpus: its content is whatever
        # the host's process table happens to be, which is why nothing here may
        # reach a verdict and why the reset behavior names live state instead of a
        # fixture reset.
        fixture_identity="btop-scroll-live-process-list-$geometry_label"
        reset_behavior="live btop process list under held-arrow input; no corpus, no reset, no comparable content"
        redraw_updates=0
        ;;
    localized-draw-acceptance)
        # The other sustained workloads republish the whole viewport every frame,
        # which pins per-frame glyph counts at maximum and inflates anything that
        # scales with glyphs drawn. This one damages a single row against a dense
        # screen, so the pair brackets what live use actually costs.
        fixture_identity="localized-draw-acceptance-single-row-$geometry_label"
        reset_behavior="dense deterministic setup plus excluded settling draw before single-row localized updates"
        redraw_updates=0
        localized_updates=1000000
        ;;
    *)
        echo "Unsupported sustained app profiling workload: $WORKLOAD" >&2
        exit 2
        ;;
esac

BTOP_EXECUTABLE=""
BTOP_ARM=""
BTOP_STATE_PROBE=""
if [[ -n "$BTOP_WORKLOAD" ]]; then
    # Everything that can refuse this run cheaply happens here, still ahead of the
    # release build and the app launch: btop must resolve to one executable, and
    # this process must already hold permission to synthesize input.
    btop_preflight_seconds=""
    [[ "$MODE" == "loop" ]] || btop_preflight_seconds="$DURATION"
    python3 "$SCRIPT_DIR/terminal_btop_workload.py" preflight --mode "$MODE" \
        --seconds "$btop_preflight_seconds" --output "$PROFILE_ROOT" >/dev/null
    BTOP_EXECUTABLE="$(jq -er '.executablePath' "$PROFILE_ROOT/btop-preflight.json")"
    BTOP_ARM="$(jq -er '.stimulusArm' "$PROFILE_ROOT/btop-preflight.json")"
    BTOP_STATE_PROBE="$(jq -er '.machineStateProbe' "$PROFILE_ROOT/btop-preflight.json")"
fi

# Runs one profiler invocation. For the corpus workloads that is the profiler
# itself; for the live one the same argv is handed to the capture driver, which
# holds an arrow key across it and records whether the recording window stayed
# wholly inside the measured stimulus lifetime.
run_profiler() {
    if [[ -z "$BTOP_WORKLOAD" ]]; then
        "$@"
        return
    fi
    python3 "$SCRIPT_DIR/terminal_btop_workload.py" capture --mode "$MODE" \
        --seconds "$DURATION" --root "$PROFILE_ROOT" --arm "$BTOP_ARM" \
        --state-probe "$BTOP_STATE_PROBE" --app-pid "$target_pid" -- "$@"
}

# Grades the live workload's bundle. Runs whatever the profiler's own exit status
# was: an invalidated capture must still leave a graded identity naming why, which
# is the only thing an operator can act on after a 20-second GUI run.
grade_btop_capture() {
    [[ -n "$BTOP_WORKLOAD" ]] || return 0
    jq -s '.[0] * {input: .[1].input, version: .[1].version}' \
        "$harness_artifacts/btop-readiness.json" "$PROFILE_ROOT/btop-preflight.json" \
        >"$PROFILE_ROOT/btop-workload.json"
    python3 "$SCRIPT_DIR/terminal_btop_artifacts.py" "$PROFILE_ROOT" --mode "$MODE"
}

DANTERM_TERMINAL_BENCHMARK_BTOP="$BTOP_EXECUTABLE" \
DANTERM_BENCHMARK_MODE=loop DANTERM_BENCHMARK_PROFILING=1 \
    DANTERM_BENCHMARK_IDENTITY_PATH="$HARNESS_IDENTITY_PATH" \
    DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES="$redraw_updates" \
    DANTERM_TERMINAL_BENCHMARK_LOCALIZED_UPDATES="$localized_updates" \
    DANTERM_TERMINAL_BENCHMARK_ACTIVITY_PATH="$ACTIVITY_PATH" \
    "$SCRIPT_DIR/terminal-benchmark.sh" "$WORKLOAD" >"$HARNESS_LOG" 2>&1 &
HARNESS_PID=$!
deadline=$((SECONDS + 120))
while [[ ! -f "$HARNESS_IDENTITY_PATH" ]]; do
    kill -0 "$HARNESS_PID" 2>/dev/null || { echo "Profiling benchmark failed; see $HARNESS_LOG" >&2; exit 1; }
    (( SECONDS < deadline )) || { echo "Timed out waiting for profiling identity; see $HARNESS_LOG" >&2; exit 1; }
    sleep 0.1
done

target_pid="$(jq -er '.pid' "$HARNESS_IDENTITY_PATH")"
binary="$(jq -er '.binary' "$HARNESS_IDENTITY_PATH")"
harness_artifacts="$(jq -er '.artifacts' "$HARNESS_IDENTITY_PATH")"
kill -0 "$target_pid" 2>/dev/null || { echo "Published profiling pid is no longer running" >&2; exit 1; }
cp "$binary" "$PROFILE_ROOT/DanTerm-Benchmark-symbols"
nm -nm "$binary" >"$PROFILE_ROOT/symbols.txt"
binary_sha256="$(shasum -a 256 "$binary" | awk '{print $1}')"
mach_o_uuid="$(dwarfdump --uuid "$binary" | awk 'NR == 1 {print $2}')"
source_commit="$(git -C "$REPO_ROOT" rev-parse HEAD)"
source_tree="$(git -C "$REPO_ROOT" rev-parse "HEAD^{tree}")"
dirty_state_sha256="$(
    {
        git -C "$REPO_ROOT" diff --binary HEAD
        git -C "$REPO_ROOT" ls-files --others --exclude-standard |
            while IFS= read -r path; do
                printf '%s\n' "$path"
                shasum -a 256 "$REPO_ROOT/$path"
            done
    } | shasum -a 256 | awk '{print $1}'
)"
jq --arg fixtureIdentity "$fixture_identity" --arg resetBehavior "$reset_behavior" \
    --arg binarySHA256 "$binary_sha256" --arg machOUUID "$mach_o_uuid" \
    --arg sourceCommit "$source_commit" --arg sourceTree "$source_tree" \
    --arg dirtyStateSHA256 "$dirty_state_sha256" --arg artifactRoot "$PROFILE_ROOT" \
    '. + {
        schemaVersion: 2,
        geometry: .geometry,
        fixtureIdentity: $fixtureIdentity,
        resetBehavior: $resetBehavior,
        binarySHA256: $binarySHA256,
        machOUUID: $machOUUID,
        sourceIdentity: {
            commit: $sourceCommit,
            sourceTree: $sourceTree,
            dirtyStateSHA256: $dirtyStateSHA256
        },
        artifactRoot: $artifactRoot,
        decisionEligible: false,
        historyEligible: false,
        profiledTimingsAreDiagnosticOnly: true
    }' "$HARNESS_IDENTITY_PATH" >"$IDENTITY_PATH"

# The live workload's bundle is graded from a machine-readable report, so it asks
# for one; the corpus workloads keep the artifact set their existing readers know.
report_flags=()
[[ -z "$BTOP_WORKLOAD" ]] || report_flags=(--json "$PROFILE_ROOT/profile-report.json")

case "$MODE" in
    loop)
        cat "$IDENTITY_PATH"
        echo "Sustained benchmark running; artifacts: $PROFILE_ROOT" >&2
        if [[ -n "$BTOP_WORKLOAD" ]]; then
            echo "Live stimulus state: $PROFILE_ROOT/btop-stimulus-live.json" >&2
            python3 "$SCRIPT_DIR/terminal_btop_workload.py" loop --root "$PROFILE_ROOT" \
                --arm "$BTOP_ARM" --app-pid "$target_pid"
        fi
        wait "$HARNESS_PID"
        ;;
    sample)
        command -v sample >/dev/null || { echo "sample is unavailable on this macOS host" >&2; exit 1; }
        printf 'sample %s %s -mayDie -fullPaths -file %s\n' \
            "$target_pid" "$DURATION" "$PROFILE_ROOT/sample.txt" >"$PROFILE_ROOT/profile-command.txt"
        capture_activity before
        profiler_status=0
        run_profiler sample "$target_pid" "$DURATION" -mayDie -fullPaths \
            -file "$PROFILE_ROOT/sample.txt" || profiler_status=$?
        capture_activity after
        if (( profiler_status != 0 )); then
            [[ -n "$BTOP_WORKLOAD" ]] || {
                echo "sample could not attach to pid $target_pid. Grant Developer Tools access to this shell and retry." >&2
                exit 1
            }
            echo "The bounded btop capture exited $profiler_status; grading the partial bundle." >&2
        fi
        if [[ -e "$PROFILE_ROOT/sample.txt" ]]; then
            echo "Sample profile: $PROFILE_ROOT/sample.txt"
            python3 "$SCRIPT_DIR/terminal-profile-report.py" "$PROFILE_ROOT/sample.txt" \
                ${report_flags[@]+"${report_flags[@]}"}
        fi
        report_frame_accounting
        grade_btop_capture
        ;;
    memory)
        for command in footprint leaks heap; do
            command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
        done
        printf 'terminal-memory-profile.py %s --seconds %s --warmup %s\n' \
            "$target_pid" "$DURATION" "$WARMUP" >"$PROFILE_ROOT/profile-command.txt"
        python3 "$SCRIPT_DIR/terminal-memory-profile.py" "$target_pid" \
            --output "$PROFILE_ROOT" --seconds "$DURATION" --warmup "$WARMUP"
        ;;
    trace)
        command -v xcrun >/dev/null || { echo "xcrun is unavailable; install Xcode command-line tools" >&2; exit 1; }
        printf 'xcrun xctrace record --no-prompt --template %s --attach %s --time-limit %ss --output %s\n' \
            "$TEMPLATE" "$target_pid" "$DURATION" "$PROFILE_ROOT/profile.trace" >"$PROFILE_ROOT/profile-command.txt"
        capture_activity before
        profiler_status=0
        run_profiler xcrun xctrace record --no-prompt --template "$TEMPLATE" --attach "$target_pid" \
            --time-limit "${DURATION}s" --output "$PROFILE_ROOT/profile.trace" || profiler_status=$?
        capture_activity after
        if (( profiler_status != 0 )); then
            [[ -n "$BTOP_WORKLOAD" ]] || {
                echo "xctrace could not attach to pid $target_pid. Grant Developer Tools access to this shell and retry." >&2
                exit 1
            }
            echo "The bounded btop capture exited $profiler_status; grading the partial bundle." >&2
        fi
        if [[ -e "$PROFILE_ROOT/profile.trace" ]]; then
            xcrun xctrace export --input "$PROFILE_ROOT/profile.trace" --toc --output "$PROFILE_ROOT/trace-toc.xml"
        fi
        # Only the CPU templates record a time-profile table. Recording with a
        # memory template succeeds and then exports nothing, so name the mismatch
        # here rather than leaving an empty export to be read as an idle process.
        # The live workload does not exit on it: its grader owns every verdict, and
        # it can only name this one from a bundle that survived.
        if [[ ! -e "$PROFILE_ROOT/trace-toc.xml" ]] || \
            ! grep -q 'schema="time-profile"' "$PROFILE_ROOT/trace-toc.xml"; then
            echo "Template '$TEMPLATE' recorded no time-profile table; nothing to export." >&2
            if [[ -e "$PROFILE_ROOT/trace-toc.xml" ]]; then
                echo "Schemas present in $PROFILE_ROOT/trace-toc.xml:" >&2
                grep -o 'schema="[a-z0-9-]*"' "$PROFILE_ROOT/trace-toc.xml" | sort -u >&2
            fi
            echo "For memory, use: just benchmark-memory $WORKLOAD" >&2
            [[ -n "$BTOP_WORKLOAD" ]] || exit 1
        else
            # The .trace bundle opens only in Instruments and the table of contents
            # carries no samples, so export the time-profile rows themselves; that
            # table is the only artifact here a non-interactive reader can use.
            xcrun xctrace export --input "$PROFILE_ROOT/profile.trace" \
                --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
                --output "$PROFILE_ROOT/time-profile.xml"
            echo "Trace profile: $PROFILE_ROOT/profile.trace"
            echo "Trace export: $PROFILE_ROOT/trace-toc.xml"
            echo "Sample export: $PROFILE_ROOT/time-profile.xml"
            python3 "$SCRIPT_DIR/terminal-profile-report.py" "$PROFILE_ROOT/time-profile.xml" \
                ${report_flags[@]+"${report_flags[@]}"}
        fi
        report_frame_accounting
        grade_btop_capture
        ;;
esac
