#!/usr/bin/env bash
# Contract tests for the dev build scripts' SwiftPM configuration and launcher forwarding.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "dev-build-configuration-contract_test: $*" >&2
    exit 1
}

BUILD_ROOT="$TEST_ROOT/build-root"
FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$BUILD_ROOT/lib/GhosttyKit.xcframework" \
    "$BUILD_ROOT/lib/TerminalPTY" \
    "$BUILD_ROOT/app" \
    "$BUILD_ROOT/icon/AppIcon-dev" \
    "$BUILD_ROOT/integrations/claude-code" \
    "$BUILD_ROOT/integrations/codex" \
    "$BUILD_ROOT/integrations/shell-integration" \
    "$BUILD_ROOT/lib/ghostty-themes" \
    "$BUILD_ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly" \
    "$BUILD_ROOT/scripts" \
    "$BUILD_ROOT/themes" \
    "$FAKE_BIN"
ln -s "$ROOT_DIR/dev-build.sh" "$BUILD_ROOT/dev-build.sh"
cp "$ROOT_DIR/scripts/bundle-theme-resources.sh" "$BUILD_ROOT/scripts/"
cp "$ROOT_DIR/scripts/pack-theme-catalog.py" "$BUILD_ROOT/scripts/"
cp "$ROOT_DIR/themes/0x96f.json" "$BUILD_ROOT/themes/"
: > "$BUILD_ROOT/lib/ghostty-themes/Fixture"
: > "$BUILD_ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf"
: > "$BUILD_ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly/LICENSE"
cp "$ROOT_DIR/app/Info.plist" "$BUILD_ROOT/app/Info.plist"
: > "$BUILD_ROOT/icon/AppIcon-dev/Assets.car"
: > "$BUILD_ROOT/dev-entitlements.plist"
: > "$BUILD_ROOT/integrations/claude-code/claude-notify-osc777.sh"
: > "$BUILD_ROOT/integrations/claude-code/danterm-agent-session.sh"
: > "$BUILD_ROOT/integrations/codex/danterm-agent-session.sh"
for shell in zsh bash fish; do
    printf '# fixture %s integration\n' "$shell" > "$BUILD_ROOT/integrations/shell-integration/danterm.$shell"
done

export SWIFT_ARGV_LOG="$TEST_ROOT/swift-argv.log"
cat > "$FAKE_BIN/swift" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SWIFT_ARGV_LOG"
case " $* " in
    *" --show-bin-path "*)
        case " $* " in
            *"/TerminalPTY "*)
                bin_path="$TEST_ROOT/bootstrap-bin"
                mkdir -p "$bin_path"
                cp /usr/bin/true "$bin_path/PTYSessionBootstrap"
                ;;
            *)
                bin_path="$TEST_ROOT/app-bin"
                mkdir -p "$bin_path"
                cp /usr/bin/true "$bin_path/DanTerm"
                cp /usr/bin/true "$bin_path/DanTermCLI"
                ;;
        esac
        printf '%s\n' "$bin_path"
        ;;
esac
SHIM
chmod +x "$FAKE_BIN/swift"

cat > "$FAKE_BIN/codesign" <<'SHIM'
#!/usr/bin/env bash
# Stop after the bundle has consumed every SwiftPM output. Installation and
# LaunchServices registration are outside this configuration contract.
exit 86
SHIM
chmod +x "$FAKE_BIN/codesign"

run_build() {
    local name="$1"
    shift
    : > "$SWIFT_ARGV_LOG"
    set +e
    HOME="$TEST_ROOT/home-$name" TEST_ROOT="$TEST_ROOT" \
        PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
        "$BUILD_ROOT/dev-build.sh" "$@" \
        > "$TEST_ROOT/$name.out" 2> "$TEST_ROOT/$name.err"
    status=$?
    set -e
    [[ $status -eq 86 ]] \
        || fail "$name build did not reach the signing boundary (status $status): $(cat "$TEST_ROOT/$name.err")"
    cp "$SWIFT_ARGV_LOG" "$TEST_ROOT/$name.swift-argv"
}

# Intent: the existing no-argument interface continues to select SwiftPM debug builds.
# Why it exists: adding an optimized variant must not slow the normal incremental dev loop.
# Scenario: a developer runs ./dev-build.sh or `just build` without an option.
run_build debug
[[ -r "$BUILD_ROOT/.build/DanTerm Dev.app/Contents/Resources/themes/catalog.json" ]] \
    || fail "debug bundle omitted the packed theme catalog"
[[ -r "$BUILD_ROOT/.build/DanTerm Dev.app/Contents/Resources/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf" ]] \
    || fail "debug bundle omitted the Nerd Font symbols face"
[[ -r "$BUILD_ROOT/.build/DanTerm Dev.app/Contents/Resources/NerdFontsSymbolsOnly/LICENSE" ]] \
    || fail "debug bundle omitted the Nerd Font license"
for shell in zsh bash fish; do
    cmp "$BUILD_ROOT/integrations/shell-integration/danterm.$shell" \
        "$BUILD_ROOT/.build/DanTerm Dev.app/Contents/Resources/shell-integration/danterm.$shell" \
        || fail "debug bundle did not preserve the $shell integration"
done
[[ $(wc -l < "$TEST_ROOT/debug.swift-argv") -eq 4 ]] \
    || fail "debug build did not make four SwiftPM build/bin-path calls"
if grep -q -- '--configuration' "$TEST_ROOT/debug.swift-argv"; then
    fail "default build unexpectedly selected an explicit SwiftPM configuration"
fi

# Intent: --release selects release configuration for both application and helper artifacts.
# Why it exists: a missed build or bin-path call can copy stale debug output into the dev bundle.
# Scenario: a developer requests an optimized DanTerm Dev build for interactive performance work.
run_build release --release
[[ $(wc -l < "$TEST_ROOT/release.swift-argv") -eq 4 ]] \
    || fail "release build did not make four SwiftPM build/bin-path calls"
[[ $(grep -c -- '--configuration release' "$TEST_ROOT/release.swift-argv") -eq 4 ]] \
    || fail "--release was not mapped onto every SwiftPM build/bin-path call"
grep -q -- "--package-path $BUILD_ROOT --build-path .* --configuration release$" \
    "$TEST_ROOT/release.swift-argv" \
    || fail "app and CLI build did not select release configuration"
grep -q -- "--package-path $BUILD_ROOT --build-path .* --show-bin-path --configuration release$" \
    "$TEST_ROOT/release.swift-argv" \
    || fail "app and CLI bin-path lookup did not select release configuration"
grep -q -- "--package-path $BUILD_ROOT/lib/TerminalPTY .* --product PTYSessionBootstrap --configuration release$" \
    "$TEST_ROOT/release.swift-argv" \
    || fail "PTYSessionBootstrap build did not select release configuration"
grep -q -- "--package-path $BUILD_ROOT/lib/TerminalPTY .* --show-bin-path --configuration release$" \
    "$TEST_ROOT/release.swift-argv" \
    || fail "PTYSessionBootstrap bin-path lookup did not select release configuration"

if HOME="$TEST_ROOT/home-invalid" TEST_ROOT="$TEST_ROOT" \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$BUILD_ROOT/dev-build.sh" --unknown \
    > "$TEST_ROOT/invalid.out" 2> "$TEST_ROOT/invalid.err"; then
    fail "unknown dev-build.sh option succeeded"
fi
grep -qF 'Usage:' "$TEST_ROOT/invalid.err" \
    || fail "unknown dev-build.sh option did not print usage help"

RUN_ROOT="$TEST_ROOT/run-root"
mkdir -p "$RUN_ROOT"
ln -s "$ROOT_DIR/dev-build-run.sh" "$RUN_ROOT/dev-build-run.sh"
export RUN_BUILD_LOG="$TEST_ROOT/run-build.log"
cat > "$RUN_ROOT/dev-build.sh" <<'SHIM'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*" > "$RUN_BUILD_LOG"
printf 'backend=%s\n' "${DANTERM_TERMINAL_BACKEND-unset}" >> "$RUN_BUILD_LOG"
SHIM
chmod +x "$RUN_ROOT/dev-build.sh"
for command in killall open; do
    cat > "$FAKE_BIN/$command" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
    chmod +x "$FAKE_BIN/$command"
done

# Intent: the build-and-run wrapper passes configuration and backend selection through unchanged.
# Why it exists: the optimized recipe must exercise the requested terminal backend after launch.
# Scenario: a developer launches an optimized Swift-terminal build from one command.
HOME="$TEST_ROOT/run-home" DANTERM_TERMINAL_BACKEND=swift \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$RUN_ROOT/dev-build-run.sh" --release
grep -qFx 'argv=--release' "$RUN_BUILD_LOG" \
    || fail "dev-build-run.sh did not forward --release"
grep -qFx 'backend=swift' "$RUN_BUILD_LOG" \
    || fail "dev-build-run.sh did not preserve DANTERM_TERMINAL_BACKEND"

echo "dev build configuration contract tests passed"
