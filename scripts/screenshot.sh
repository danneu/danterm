#!/usr/bin/env bash
# Produces the two README screenshots: builds and installs the dev app, restores
# the saved layout in docs/screenshot/init.json, drives each pane through the
# `danterm` CLI, and captures the window before and after the theme browser
# opens. Needs a logged-in GUI session, plus Accessibility and Screen Recording
# permission for the terminal that runs it.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

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
init_json="$root/docs/screenshot/init.json"
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
# Long prompt on purpose: codex must still be working when the capture fires,
# so the pane shows its busy indicator.
"$danterm_cli" pane input --pane AC5D792A-BD88-433E-9E3D-C71D3DC961DE -- 'codex "write me a long story"' Enter
"$danterm_cli" pane input --pane 2F69A409-70D6-4E73-A5F8-E54022AA327C -- "vim README.md" Enter
"$danterm_cli" pane input --pane D4E5F6A7-B8C9-4D0E-AF12-3B4C5D6E7F80 -- 'claude "Say cheese"' Enter
"$danterm_cli" pane input --pane F6A7B8C9-D0E1-4F20-C134-5D6E7F8A91B2 -- "vim README.md" Enter
# Public SSH endpoint, so the remote-theme pane needs no host of our own.
# The key is seeded first: an unknown host would leave the pane sitting on
# the fingerprint prompt instead of the remote theme we want to show.
ssh_demo_host="terminal.shop"
mkdir -p "$HOME/.ssh"
if ! ssh-keygen -F "$ssh_demo_host" >/dev/null 2>&1; then
    ssh-keyscan -T 5 "$ssh_demo_host" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
fi
"$danterm_cli" pane input --pane E5F6A7B8-C9D0-4E1F-B023-4C5D6E7F8A91 -- "ssh $ssh_demo_host" Enter
"$danterm_cli" pane input --pane A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D -- "lazygit" Enter

# Fit the window to the screen the app opened on. This is a plain resize, not
# native fullscreen: fullscreen hides the menu bar and moves the window to its
# own Space, which changes the chrome the screenshot is meant to show.
sleep 1
read -r fit_x fit_y fit_w fit_h <<<"$(swift -e '
    import AppKit

    // AppKit measures from the bottom-left of the primary display; System
    // Events measures from its top-left, so the y origin has to be flipped.
    // visibleFrame is what excludes the menu bar and the Dock.
    let screen = NSScreen.main ?? NSScreen.screens.first
    guard let screen, let primary = NSScreen.screens.first else { exit(1) }
    let visible = screen.visibleFrame
    print(Int(visible.minX.rounded()),
          Int((primary.frame.maxY - visible.maxY).rounded()),
          Int(visible.width.rounded()),
          Int(visible.height.rounded()))
')"

echo "Fitting window to ${fit_w}x${fit_h} at ${fit_x},${fit_y}"
osascript \
    -e 'on run argv' \
    -e '    tell application "System Events" to tell process "DanTerm Dev"' \
    -e '        tell window 1' \
    -e '            set position to {item 1 of argv as integer, item 2 of argv as integer}' \
    -e '            set size to {item 3 of argv as integer, item 4 of argv as integer}' \
    -e '        end tell' \
    -e '    end tell' \
    -e 'end run' \
    "$fit_x" "$fit_y" "$fit_w" "$fit_h"

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
            # shellcheck disable=SC2016  # Swift string interpolation, not shell
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

# Open the theme browser (View > Toggle Theme Browser, Cmd+Shift+B) for screenshot2
osascript -e '
tell application "System Events"
    tell process "DanTerm Dev"
        keystroke "b" using {command down, shift down}
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
