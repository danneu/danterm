# Get current version from highest semver tag (regardless of branch reachability)
_current_version := `git tag -l 'v*' | sed 's/^v//' | sort -V | tail -1 || echo "0.0.0"`

default:
    @just --list

# Remove build artifacts
clean:
    rm -rf .spm-build .build lib/DanTermProtocol/.build lib/DanTermCore/.build lib/DanTermSupport/.build lib/TerminalCore/.build lib/TerminalPTY/.build

# Link cached external prerequisites from the primary checkout into this worktree.
provision-worktree:
    ./scripts/provision-worktree.sh

# Materialize all pinned references, one named reference, or list them with:
# `just fetch-references`, `just fetch-references alacritty`, or `just fetch-references --list`.
fetch-references *args:
    python3 ./scripts/fetch-references.py {{args}}

# Refresh tracked JSON themes from DanTerm's pinned iTerm2-Color-Schemes release.
update-themes:
    python3 ./scripts/import-themes.py

# Compile Icon Composer .icon files into Assets.car
build-icons:
    ./icon/gen-dev-icon.sh
    ./icon/gen-readme-icon.sh
    cp icon/raw.svg icon/AppIcon.icon/Assets/raw.svg
    cp icon/raw-dev.svg icon/AppIcon-dev.icon/Assets/raw-dev.svg
    ./icon/build-icns.sh AppIcon
    ./icon/build-icns.sh AppIcon-dev

# Run all tests. Steps run as a bounded parallel pool; the step list lives in
# scripts/run-test-suite.sh. Pass a job count to override (default: half the cores).
test jobs="":
    ./scripts/run-test-suite.sh {{jobs}}

# Run all tests one at a time, for when parallel output or scheduling is in the way.
test-serial:
    JOBS=1 ./scripts/run-test-suite.sh

# Run UI tests (AppKit, requires display)
test-ui:
    ./test-ui.sh

# Run opt-in live Claude/Codex notification compatibility tests (authenticated, quota-using).
test-agent-notifications-live agent="all":
    ./scripts/agent-notifications-live.py {{agent}}

# Run the opt-in Swift terminal viability gate (requires GUI + Accessibility)
test-terminal-viability:
    ./scripts/terminal-viability.sh

# Run the opt-in paired-benchmark GUI contract proof (requires GUI + Accessibility)
test-terminal-benchmark-gui:
    python3 ./scripts/terminal-benchmark-gui-contract.py

# Run the opt-in live btop-scroll diagnostic proof (requires GUI + Accessibility + btop)
test-terminal-btop-gui *phases:
    python3 ./scripts/terminal-btop-gui-proof.py {{phases}}

# Compare one workload between a named baseline revision and the working tree.
benchmark-quick baseline workload:
    python3 ./scripts/terminal-benchmark-compare.py quick \
        --baseline "{{ trim_start_matches(baseline, 'baseline=') }}" \
        --workload "{{ trim_start_matches(workload, 'workload=') }}"

# Compare all five routine workloads between a named baseline revision and the working tree.
benchmark-confirm baseline:
    python3 ./scripts/terminal-benchmark-compare.py confirm \
        --baseline "{{ trim_start_matches(baseline, 'baseline=') }}"

# Measure what terminal state costs, headlessly and exactly, across the payload matrix.
#
# Use this -- not `benchmark-memory` -- for any question of the form "did this change reduce
# resident bytes". It builds a fresh Terminal per payload and reports exact MemoryLayout stride
# arithmetic, so two runs are comparable; `benchmark-memory` samples GUI process footprint and
# cannot resolve a representation change at all (`research/15/F6`).
#
#   just terminal-memory-probe                              # full matrix, 179x66
#   just terminal-memory-probe "--json"                     # machine-readable
#   just terminal-memory-probe "--payload scrollback-plain" # one payload, attributable footprint
#   just terminal-memory-probe "--columns 80 --rows 24"
terminal-memory-probe flags="":
    swift build -c release --package-path lib/TerminalCore --product TerminalMemoryProbe
    lib/TerminalCore/.build/release/TerminalMemoryProbe {{flags}}

# Measure how long a single job holds TerminalPTYHost's serial queue, at a saturated history.
#
# Use this -- not `benchmark-quick` -- for any question of the form "can the main thread's
# drain fence end up waiting behind this". No calibrated workload searches, selects, or
# resizes at all, so none of the frozen benchmark rules apply to these jobs and none can
# (`research/19/D2`). Reports wall-clock, not CPU: a job that blocks holds the queue
# exactly as hard as one that burns CPU, so an on-CPU instrument would understate precisely
# the jobs worth finding (19's inverted rule).
#
# Compares across revisions by hand -- run it, stash or check out the other revision, run it
# again. There is no paired arm here and no threshold; at the 5x-50x effect sizes this file
# deals in, that is enough (research/19/D2).
#
#   just terminal-occupancy-probe                          # full case list, 179x66
#   just terminal-occupancy-probe "--json"                 # machine-readable
#   just terminal-occupancy-probe "--iterations 10"        # quicker, noisier
#   just terminal-occupancy-probe "--columns 80 --rows 24"
terminal-occupancy-probe flags="":
    swift build -c release --package-path lib/TerminalCore --product TerminalOccupancyProbe
    lib/TerminalCore/.build/release/TerminalOccupancyProbe {{flags}}

# Time width changes on a budget-saturated scrollback, and report the spread.
#
# A probe, not a benchmark: `research/28/D1` pitch 2 refused to admit this as a candidate workload
# because `research/28/H1`'s question is absolute ("does a saturated resize fit in a frame budget,
# and where does its time go"), not comparative, and doc 28's evidence floor forbids
# wanting a pre-trim arm to pair against. So there is no threshold here, no verdict, and
# no second arm -- it prints a distribution and a reader interprets it.
#
# It is committed rather than run-and-deleted on purpose. `research/15/F18`'s browsing probe was
# deleted right after it was read, which cost doc 28 an entire re-implementation task
# (`research/28/F5`) to get the same measurement back.
#
# Upgrading it to a paired candidate workload is a separate decision, and `D1` states its
# gate: a change that is *expected* to move resize cost, which is what finally gives the
# comparison two arms.
#
# Two frozen recipes. `standard` (`saturated-resize-v1`) is `F7`'s: 10,000 lines, which
# saturated the pre-packing representation. `saturating` (`saturated-resize-v2`) feeds
# 120,000 so the byte budget decides depth again -- packed retained rows admit ~14x more
# rows at the same 10 MiB, so v1's history is no longer budget-bounded and its samples
# cover a fraction of the depth a real saturated pane holds. The versions are distinct
# names, not an edit in place, because their numbers are not comparable.
#
# `sparse` (`saturated-sparse-resize-v1`) is `v2`'s geometry and budget fed short
# shell-history lines instead of program output. Retained rows are content-sized, so
# the same 10 MiB buys ~19x more of them -- which makes the dense payload the shallow
# end of the depth range rather than a representative point, in both representations.
#
#   just terminal-resize-probe                             # v1, 40 samples, 179x66 <-> 100
#   just terminal-resize-probe "--recipe saturating"       # v2, budget-saturated, 20 samples
#   just terminal-resize-probe "--recipe sparse"           # sparse-v1, budget-saturated
#   just terminal-resize-probe "--samples 100"             # tighter tail
#   just terminal-resize-probe "--alternate-columns 80"
terminal-resize-probe flags="":
    swift build -c release --package-path lib/TerminalCore --product TerminalResizeProbe
    lib/TerminalCore/.build/release/TerminalResizeProbe {{flags}}

# Report the shape of retained rows across the committed stimulus corpus: how many are
# blank, how long the rest are, what their cells contain, and what malloc's size classes
# charge for them -- then price each candidate packing representation against those exact
# rows.
#
# The instrument behind `research/28/F9` (blank-row frequency, sizing
# `research/28/H2`'s ceiling), `research/28/F10` (whether ragged rows' paper savings survive the
# allocator) and `research/28/F11` (what
# retained rows are made of, and what a packing scheme can therefore charge). A probe,
# not a benchmark: one arm, no threshold, no verdict.
#
# Pass `--saturated` to also replay each stimulus until its retained history fills the
# production budget. That is how styled and multi-scalar content is read *at depth*: the
# corpus's styled content lives in recordings that retain a screenful or less per pass.
# Repeated replays are pooled separately, because repetition manufactures depth and would
# otherwise be read as evidence about how often such content reaches history.
#
# The stimulus is supplied from committed bytes -- the five benchmark-corpus workloads
# and every neutral recording fixture -- rather than generated, so the blank-row number
# cannot be shaped after the fact. Two generated stimuli are reported and excluded from
# the pools: `bound/all-blank-saturation` (`H2`'s best case, which flatters it maximally
# and is labelled as a ceiling) and `reference/scrollback-plain` (`F8`'s payload,
# replayed so its measured per-row residual can be re-explained from size classes).
#
#   just terminal-retained-row-probe               # table
#   just terminal-retained-row-probe "--json"      # machine-readable
#   just terminal-retained-row-probe "--saturated" # + depth by replay
terminal-retained-row-probe flags="":
    swift build -c release --package-path lib/TerminalCore --product TerminalRetainedRowProbe
    python3 ./scripts/terminal-retained-row-shape.py {{flags}}

# Benchmark full-frame and damage-clipped CoreText drawing headlessly.
benchmark-draw iterations="15":
    swift run --package-path lib/TerminalCore -c release TerminalDrawBenchmark {{iterations}}

# Compare two draw-path revisions headlessly, interleaved in one process. Measures drawing
# an already-scoped plan only -- not damage generation, which stays with benchmark-quick.
# Both parameters are positional (they have defaults, so `name=value` does not bind here):
#   just benchmark-headless-draw                      # A/A control against this tree
#   just benchmark-headless-draw 8                    # 8 rounds
#   just benchmark-headless-draw 8 /path/TerminalCore # compare against another checkout
# Content and scenario are script-level flags: pass --workload text-shaped to measure the
# CoreText glyph path (the default sprite workload never reaches it) and --clip-rows 0 for
# full-frame draws.
benchmark-headless-draw rounds="8" candidate_core="":
    python3 ./scripts/terminal-headless-draw-compare.py --rounds {{rounds}} \
      {{ if candidate_core != "" { "--both-directions --candidate-core " + candidate_core } else { "" } }}

# Build and open the unoptimized system-glyph versus sprite comparison app.
preview-glyphs:
    swift run --package-path lib/TerminalCore GlyphPreview

# Benchmark fixed-row updates through the real optimized AppKit draw path.
benchmark-draw-app batches="15" target_ms="400":
    python3 ./scripts/terminal-draw-acceptance.py {{batches}} {{target_ms}}

# Run one isolated workload continuously and publish its exact app pid.
benchmark-loop workload="scrollback-stream":
    ./scripts/terminal-benchmark-profile.sh loop "{{workload}}"

# Capture a textual sample profile of Terminal.feed alone, headless and without a
# display. Isolates parse/grid cost from planning and drawing, which share the app's
# main thread in benchmark-sample. Attribution only -- never a directional verdict.
#   just benchmark-feed-sample                                # styled-screen-redraw, 20s
#   just benchmark-feed-sample incremental-screen-updates 30
benchmark-feed-sample workload="styled-screen-redraw" seconds="20":
    python3 ./scripts/terminal-feed-profile.py "{{ trim_start_matches(workload, 'workload=') }}" \
        --seconds "{{ trim_start_matches(seconds, 'seconds=') }}"

# Capture a textual sample profile from one isolated sustained Swift workload.
benchmark-sample workload="scrollback-stream" seconds="15":
    ./scripts/terminal-benchmark-profile.sh sample "{{workload}}" "{{seconds}}"

# Capture and export an xctrace profile from one isolated sustained Swift workload.
benchmark-trace workload="scrollback-stream" template="Time Profiler" seconds="30":
    ./scripts/terminal-benchmark-profile.sh trace "{{workload}}" "{{seconds}}" "{{template}}"

# Measure sustained memory growth of one isolated Swift workload. Polls footprint
# and brackets the measured window with memory graphs so heap can name what grew.
# Growth is measured after the warmup, so seconds must exceed it.
#   just benchmark-memory scrollback-stream 90 15
benchmark-memory workload="scrollback-stream" seconds="90" warmup="15":
    ./scripts/terminal-benchmark-profile.sh memory "{{workload}}" "{{seconds}}" "{{warmup}}"

# Re-report an existing profile artifact as folded stacks plus JSON. Accepts a
# profile directory, a .trace bundle, an exported time-profile XML, or a sample.txt;
# a bare .trace is exported first, so no Instruments session is needed to read it.
#   just benchmark-report .build/terminal-benchmark-profiles/2026-07-29-100006-58468
#   just benchmark-report <dir> '--state Running --thread Main --top 40'
benchmark-report input flags="":
    python3 ./scripts/terminal-profile-report.py "{{input}}" {{flags}}

# Run the opt-in headless shell/application compatibility workflows.
# Needs asciinema/fish/fzf: nix develop .#terminal-workflows -c just test-terminal-workflows
test-terminal-workflows:
    ./scripts/terminal-workflows.sh

# Run the opt-in pinned protocol probes through a real pane session.
test-terminal-protocol-probes:
    ./scripts/terminal-protocol-probes.sh

# Run opt-in PTY teardown proofs (requires tmux and passwordless localhost ssh).
test-pty-external:
    @command -v tmux >/dev/null || { echo "test-pty-external requires tmux on PATH"; exit 1; }
    @/usr/bin/ssh -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no localhost true >/dev/null || { echo "test-pty-external requires Remote Login and passwordless localhost ssh"; exit 1; }
    DANTERM_PTY_EXTERNAL=1 DANTERM_TMUX_PATH="$(command -v tmux)" swift test --package-path lib/TerminalPTY --filter TerminalPTYExternalTests

# Run CLI smoke test in an isolated development slot (requires GUI access and jq)
test-cli:
    ./scripts/tests/danterm-cli_test.sh

# Build local dev app to .build/DanTerm Dev.app
build:
    ./dev-build.sh

# Build an optimized local dev app to .build/DanTerm Dev.app
build-optimized:
    ./dev-build.sh --release

# Replace the canonical ~/Applications DanTerm Dev app and run it
replace-dev:
    ./dev-build-run.sh

# Replace the canonical DanTerm Dev app with an optimized build and run it
replace-dev-optimized:
    ./dev-build-run.sh --release

# Launch an isolated unattended development slot, leaving the canonical app alone
launch-slot:
    ./scripts/dev-slot-launcher.py

# Launch an isolated unattended optimized development slot
launch-slot-optimized:
    ./scripts/dev-slot-launcher.py --release

# Launch an isolated slot that activates, to grant notification authorization once
launch-slot-prime:
    ./scripts/dev-slot-launcher.py --foreground

# Show current version
version:
    @echo "v{{_current_version}}"

# Create initial v0.0.0 tag (no-op if already exists)
init:
    git tag v0.0.0 2>/dev/null || true
    git push origin v0.0.0 2>/dev/null || true
    @echo "v0.0.0 tag exists"

# Bump and release: just release patch|minor|major
release bump:
    #!/usr/bin/env bash
    set -euo pipefail
    git pull --rebase || { echo "Pull failed — resolve conflicts first"; exit 1; }
    current="{{_current_version}}"
    IFS='.' read -r major minor patch <<< "$current"
    case "{{bump}}" in
        major) major=$((major + 1)); minor=0; patch=0 ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        patch) patch=$((patch + 1)) ;;
        *) echo "Usage: just release patch|minor|major"; exit 1 ;;
    esac
    new="$major.$minor.$patch"
    echo "v$current -> v$new"
    read -p "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
    plutil -replace CFBundleVersion -string "$new" app/Info.plist
    plutil -replace CFBundleShortVersionString -string "$new" app/Info.plist
    git add app/Info.plist
    git commit -m "release v$new"
    git tag "v$new"
    git push origin HEAD "v$new"
    echo "Pushed v$new -- release workflow will start"
    ./scripts/watch-release-workflow.sh "$(git rev-parse HEAD)"

# Build, launch, screenshot the window, kill the app
screenshot:
    #!/usr/bin/env bash
    set -euo pipefail

    # Build and install
    ./dev-build.sh

    app_name="DanTerm Dev"
    app_path="$HOME/Applications/$app_name.app"
    output_dir="docs/screenshot"
    mkdir -p "$output_dir"

    # Kill any existing instance
    pkill -x "$app_name" 2>/dev/null || true
    sleep 0.5

    # Launch the saved layout, then populate panes through the same CLI input
    # path users invoke. Snapshot restore never executes saved command text.
    init_json="$(pwd)/docs/screenshot/init.json"
    open -a "$app_path" --args --init "$init_json"

    danterm_cli="$app_path/Contents/Helpers/danterm"
    export DANTERM_SOCK="$HOME/Library/Caches/com.danneu.danterm-dev/control.sock"
    echo "Waiting for control socket..."
    for i in $(seq 1 20); do
        if "$danterm_cli" ls >/dev/null 2>&1; then
            break
        fi
        if [[ "$i" -eq 20 ]]; then
            echo "Timed out waiting for DanTerm control socket"
            pkill -x "$app_name" 2>/dev/null || true
            exit 1
        fi
        sleep 0.25
    done

    "$danterm_cli" pane input --pane 2A5C2AF9-CBE2-4934-8573-8204875F079D -- "lazygit" Enter
    "$danterm_cli" pane input --pane 4A53A920-BC2E-4C8E-8242-267DC4F9BC2D -- "htop" Enter
    "$danterm_cli" pane input --pane 2F69A409-70D6-4E73-A5F8-E54022AA327C -- "vim README.md" Enter
    "$danterm_cli" pane input --pane D4E5F6A7-B8C9-4D0E-AF12-3B4C5D6E7F80 -- 'claude "Say cheese"' Enter
    "$danterm_cli" pane input --pane F6A7B8C9-D0E1-4F20-C134-5D6E7F8A91B2 -- "vim README.md" Enter
    "$danterm_cli" pane input --pane E5F6A7B8-C9D0-4E1F-B023-4C5D6E7F8A91 -- "ssh dan@silverstone.local" Enter
    "$danterm_cli" pane input --pane A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D -- "lazygit" Enter

    # Resize window to exact screenshot dimensions
    sleep 1
    osascript -e '
    tell application "System Events"
        tell process "DanTerm Dev"
            tell window 1
                set position to {100, 100}
                set size to {1334, 750}
            end tell
        end tell
    end tell
    '

    outfile="$output_dir/screenshot1.png"
    captured=0

    # Poll + capture loop: once per second for up to 10 seconds.
    # Window selection is deterministic: largest visible DanTerm Dev layer-0 window.
    echo "Waiting for capturable window..."
    for i in $(seq 1 10); do
        wid=$(swift -e '
            import CoreGraphics
            import Foundation

            let target = "DanTerm Dev"
            let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            let windows = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []

            let candidates = windows.compactMap { w -> (id: UInt32, area: Double)? in
                guard (w[String(kCGWindowOwnerName)] as? String) == target else { return nil }
                guard ((w[String(kCGWindowLayer)] as? Int) ?? -1) == 0 else { return nil }
                guard ((w[String(kCGWindowAlpha)] as? Double) ?? 0) > 0 else { return nil }
                guard let bounds = w[String(kCGWindowBounds)] as? [String: Any] else { return nil }
                let width = (bounds["Width"] as? Double) ?? 0
                let height = (bounds["Height"] as? Double) ?? 0
                guard width > 0, height > 0 else { return nil }
                guard let idNum = w[String(kCGWindowNumber)] as? NSNumber else { return nil }
                return (id: idNum.uint32Value, area: width * height)
            }

            if let best = candidates.sorted(by: { a, b in
                if a.area != b.area { return a.area > b.area }
                return a.id < b.id
            }).first {
                print(best.id)
            }
        ' || true)

        if [[ -n "$wid" ]]; then
            echo "Window found (ID: $wid), waiting 10s for content to settle..."
            sleep 10
            if screencapture -x -l"$wid" "$outfile"; then
                captured=1
                break
            else
                WID="$wid" swift -e '
                    import CoreGraphics
                    import Foundation

                    guard let widStr = ProcessInfo.processInfo.environment["WID"],
                          let wid = UInt32(widStr) else {
                        print("[debug] invalid WID env")
                        exit(0)
                    }
                    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
                    let windows = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
                    if let w = windows.first(where: {
                        guard let n = $0[String(kCGWindowNumber)] as? NSNumber else { return false }
                        return n.uint32Value == wid
                    }) {
                        let owner = (w[String(kCGWindowOwnerName)] as? String) ?? "?"
                        let name = (w[String(kCGWindowName)] as? String) ?? ""
                        let layer = (w[String(kCGWindowLayer)] as? Int) ?? -1
                        let alpha = (w[String(kCGWindowAlpha)] as? Double) ?? -1
                        let sharing = (w[String(kCGWindowSharingState)] as? Int) ?? -1
                        let bounds = (w[String(kCGWindowBounds)] as? [String: Any]) ?? [:]
                        print("[debug] wid=\(wid) owner=\(owner) name=\(name) layer=\(layer) alpha=\(alpha) sharing=\(sharing) bounds=\(bounds)")
                    } else {
                        print("[debug] wid=\(wid) no longer present")
                    }
                ' || true
            fi
        fi

        sleep 1
    done

    if [[ "$captured" -ne 1 ]]; then
        echo "Timed out waiting for a capturable window"
        echo "Hint: Add your current terminal app to macOS Screen Recording permissions, then restart that terminal and retry."
        pkill -x "$app_name" 2>/dev/null || true
        exit 1
    fi

    echo "Saved: $(cd "$(dirname "$outfile")" && pwd)/$(basename "$outfile")"

    # Open theme panel (Cmd+Shift+T) and take screenshot2
    osascript -e '
    tell application "System Events"
        tell process "DanTerm Dev"
            keystroke "T" using {command down, shift down}
        end tell
    end tell
    '
    sleep 2
    outfile2="$output_dir/screenshot2.png"
    if screencapture -x -l"$wid" "$outfile2"; then
        echo "Saved: $(cd "$(dirname "$outfile2")" && pwd)/$(basename "$outfile2")"
    else
        echo "Failed to capture screenshot2"
    fi

    # Kill the app
    pkill -x "$app_name" 2>/dev/null || true

    # Open the screenshots
    open "$outfile"
    open "$outfile2"
