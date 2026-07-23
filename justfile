# Get current version from highest semver tag (regardless of branch reachability)
_current_version := `git tag -l 'v*' | sed 's/^v//' | sort -V | tail -1 || echo "0.0.0"`

default:
    @just --list

# Remove build artifacts
clean:
    rm -rf .spm-build .build lib/DanTermProtocol/.build lib/DanTermCore/.build lib/DanTermSupport/.build lib/TerminalCore/.build lib/TerminalPTY/.build

# Clone/fetch Ghostty source for reference (no xcframework build).
fetch-ghostty:
    ./build-lib.sh fetch

# Fetch Ghostty source and build the GhosttyKit xcframework.
build-lib:
    ./build-lib.sh

# Compile Icon Composer .icon files into Assets.car
build-icons:
    ./icon/gen-dev-icon.sh
    ./icon/gen-readme-icon.sh
    cp icon/raw.svg icon/AppIcon.icon/Assets/raw.svg
    cp icon/raw-dev.svg icon/AppIcon-dev.icon/Assets/raw-dev.svg
    ./icon/build-icns.sh AppIcon
    ./icon/build-icns.sh AppIcon-dev

# Run all tests
test:
    swift test --package-path lib/DanTermProtocol --filter DanTermProtocolTests
    swift test --package-path lib/DanTermCore
    swift test --package-path lib/TerminalCore
    ./scripts/test-terminal-pty.sh
    swift test --package-path lib/DanTermSupport
    ./scripts/core-purity-lint.sh
    ./scripts/core-purity-lint.sh lib/TerminalCore/Sources/TerminalCore
    ./scripts/core-purity-lint.sh --forbid-imports lib/TerminalCore/Sources/TerminalCore
    ./scripts/core-purity-lint.sh lib/TerminalCore/Sources/TerminalRenderPlanning
    ./scripts/core-purity-lint.sh --allow-imports TerminalCore lib/TerminalCore/Sources/TerminalRenderPlanning
    ./scripts/core-purity-lint.sh lib/TerminalPTY/Sources/PaneLifecycle
    ./scripts/core-purity-lint.sh --forbid-imports lib/TerminalPTY/Sources/PaneLifecycle
    ./scripts/core-purity-lint.sh --profile portable lib/DanTermSupport/Sources/DanTermSupport
    ./scripts/tests/core-purity-lint_test.sh
    ./scripts/terminal-backend-boundary-lint.sh
    ./scripts/tests/terminal-backend-boundary-lint_test.sh
    ./scripts/tests/terminal-capture-api-gate_test.sh
    ./scripts/tests/load-ghostty-version_test.sh
    ./scripts/tests/build-lib-stale-guard_test.sh
    ./scripts/tests/build-lib-fetch_test.sh
    ./scripts/tests/build-lib-contract_test.sh
    ./scripts/tests/dev-build-configuration-contract_test.sh
    ./scripts/tests/danterm-cli-connect-errors_test.sh
    ./scripts/tests/terminal-characterization-harness_test.sh
    ./scripts/tests/terminal-viability-harness_test.sh
    ./scripts/tests/terminal-benchmark-harness_test.sh
    python3 ./scripts/tests/terminal_benchmark_producer_test.py
    python3 ./scripts/tests/terminal_benchmark_suite_test.py
    python3 ./scripts/tests/terminal_draw_acceptance_test.py
    ./scripts/tests/test-terminal-pty_test.sh
    ./scripts/tests/shell-integration_test.sh
    ./scripts/tests/agent-notifications-live_test.py

# Run UI tests (AppKit, requires display)
test-ui:
    ./test-ui.sh

# Run opt-in live Claude/Codex notification compatibility tests (authenticated, quota-using).
test-agent-notifications-live agent="all":
    ./scripts/agent-notifications-live.py {{agent}}

# Run opt-in real-Ghostty pane-read and recovery characterization (requires GUI + Accessibility)
test-terminal-characterization:
    ./scripts/terminal-characterization.sh

# Run the opt-in Swift terminal viability gate (requires GUI + Accessibility)
test-terminal-viability:
    ./scripts/terminal-viability.sh

# Benchmark one workload; options accept backend=, workload=, and save= in any order.
benchmark-one *args:
    python3 ./scripts/terminal-benchmark-suite.py default-workload=scrollback-stream {{args}}

# Benchmark the corpus; options accept backend= and save= in any order.
benchmark *args:
    python3 ./scripts/terminal-benchmark-suite.py {{args}}

# Benchmark Terminal.feed headlessly; options accept workload=, comment=, and save=.
benchmark-core *args:
    python3 ./scripts/terminal-benchmark-suite.py backend=swift-core {{args}}

# Benchmark full-frame and damage-clipped CoreText drawing headlessly.
benchmark-draw iterations="15":
    swift run --package-path lib/TerminalCore -c release TerminalDrawBenchmark {{iterations}}

# Build and open the unoptimized system-glyph versus sprite comparison app.
preview-glyphs:
    swift run --package-path lib/TerminalCore GlyphPreview

# Benchmark fixed-row updates through the real optimized AppKit draw path.
benchmark-draw-app batches="15" target_ms="400":
    python3 ./scripts/terminal-draw-acceptance.py {{batches}} {{target_ms}}

# Benchmark serialized complete redraws; options accept workload=, save=, and comment=.
benchmark-redraw *args:
    python3 ./scripts/terminal-draw-acceptance.py redraw=1 {{args}}

# Run one isolated workload continuously and publish its exact app pid.
benchmark-loop workload="scrollback-stream" backend="swift":
    ./scripts/terminal-benchmark-profile.sh loop "{{workload}}" "{{backend}}"

# Capture a textual sample profile from one isolated sustained Swift workload.
benchmark-sample workload="scrollback-stream" seconds="15":
    ./scripts/terminal-benchmark-profile.sh sample "{{workload}}" swift "{{seconds}}"

# Capture and export an xctrace profile from one isolated sustained Swift workload.
benchmark-trace workload="scrollback-stream" template="Time Profiler" seconds="30":
    ./scripts/terminal-benchmark-profile.sh trace "{{workload}}" swift "{{seconds}}" "{{template}}"

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

# Run CLI smoke test (requires GUI access, jq, and DANTERM_CLI_TEST_ALLOW_APP_CONTROL=1)
test-cli:
    ./scripts/tests/danterm-cli_test.sh

# Build local dev app to .build/DanTerm Dev.app
build:
    ./dev-build.sh

# Build an optimized local dev app to .build/DanTerm Dev.app
build-optimized:
    ./dev-build.sh --release

# Build, install to ~/Applications, and run DanTerm Dev
build-run:
    ./dev-build-run.sh

# Build an optimized DanTerm Dev app, install it, and run it
build-run-optimized:
    ./dev-build-run.sh --release

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
    echo "Pushed v$new — release workflow will start"

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
