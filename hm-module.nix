# Home Manager module for DanTerm
#
# Builds and manages DanTerm as a terminal app on macOS.
# GhosttyKit xcframework is built from source and cached automatically.
#
# Requirements:
#   - macOS with full Xcode (not just CLT) and Metal toolchain
#   - nix with flakes
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.danterm;

  appPath = "${config.home.homeDirectory}/Applications/DanTerm.app";

  ghosttySrc = pkgs.fetchFromGitHub {
    owner = "ghostty-org";
    repo = "ghostty";
    rev = "v1.2.3";
    hash = "sha256-0tmLOJCrrEnVc/ZCp/e646DTddXjv249QcSwkaukL30=";
  };

  zigDeps = pkgs.callPackage ./build.zig.zon.nix {
    name = "ghostty-deps-1.2.3";
  };

  swiftSources = builtins.filter (l: l != "")
    (lib.splitString "\n" (builtins.readFile ./swift-sources.txt));

  appSrc = ./app;
  infoPlist = ./app/Info.plist;

in
{
  options.programs.danterm = {
    enable = mkEnableOption "DanTerm terminal emulator";

    startAtLogin = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to start DanTerm at login.";
    };
  };

  config = mkIf cfg.enable {
    home.activation.buildDanTerm = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      APP_PATH="${appPath}"
      SRC_DIR="${appSrc}"
      CACHE_DIR="$HOME/.cache/danterm/ghosttykit"
      mkdir -p "$CACHE_DIR"

      # --- Preflight checks ---

      if ! /usr/bin/xcrun --find swiftc &>/dev/null; then
        echo "Error: Xcode required. Install from App Store or developer.apple.com"
        exit 1
      fi
      if ! /usr/bin/xcrun --find metal &>/dev/null; then
        echo "Error: Metal toolchain missing. Run: xcodebuild -downloadComponent MetalToolchain"
        exit 1
      fi
      if ! /usr/bin/xcrun --sdk macosx --show-sdk-path &>/dev/null; then
        echo "Error: macOS SDK not found. Run: sudo xcode-select -s /Applications/Xcode.app"
        exit 1
      fi

      # --- Phase 1: GhosttyKit xcframework (cached by content hash) ---

      GHOSTTYKIT_KEY=$(/usr/bin/shasum -a 256 <<EOF | cut -d' ' -f1
      ghostty-src: ${ghosttySrc}
      zig-deps: ${zigDeps}
      zig: ${pkgs.zig_0_14}
      build-flags: -Demit-xcframework -Demit-macos-app=false -Dsentry=false -Doptimize=ReleaseFast
      sdk-version: $(/usr/bin/xcrun --sdk macosx --show-sdk-version)
      xcode-version: $(/usr/bin/xcodebuild -version | head -1)
      clang-version: $(/usr/bin/xcrun clang --version | head -1)
      EOF
      )
      XCFW_CACHE="$CACHE_DIR/$GHOSTTYKIT_KEY"

      if [ ! -d "$XCFW_CACHE/GhosttyKit.xcframework" ]; then
        LOCK_DIR="$CACHE_DIR/.build.lock"
        LOCK_TIMEOUT=600  # 10 minutes
        NEED_BUILD=1

        while ! mkdir "$LOCK_DIR" 2>/dev/null; do
          # Check for stale lock (owner PID stored in lock dir)
          if [ -f "$LOCK_DIR/pid" ]; then
            LOCK_PID=$(cat "$LOCK_DIR/pid")
            if ! kill -0 "$LOCK_PID" 2>/dev/null; then
              echo "Stale lock detected (PID $LOCK_PID no longer running). Removing."
              rm -rf "$LOCK_DIR"
              continue
            fi
          fi
          # Check lock age
          if [ -f "$LOCK_DIR/pid" ]; then
            LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR/pid") ))
            if [ "$LOCK_AGE" -gt "$LOCK_TIMEOUT" ]; then
              echo "Lock held for ''${LOCK_AGE}s (timeout ''${LOCK_TIMEOUT}s). Breaking stale lock."
              rm -rf "$LOCK_DIR"
              continue
            fi
          fi
          echo "Another DanTerm build is in progress. Waiting..."
          sleep 5
          if [ -d "$XCFW_CACHE/GhosttyKit.xcframework" ]; then
            NEED_BUILD=0; break
          fi
        done

        if [ "$NEED_BUILD" -eq 1 ]; then
          echo $$ > "$LOCK_DIR/pid"
          trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT

          if [ ! -d "$XCFW_CACHE/GhosttyKit.xcframework" ]; then
            echo "Building GhosttyKit (this may take several minutes)..."
            WORK_DIR=$(/usr/bin/mktemp -d)

            cp -R "${ghosttySrc}/." "$WORK_DIR/"
            chmod -R u+w "$WORK_DIR"
            cd "$WORK_DIR" || exit 1

            ${pkgs.zig_0_14}/bin/zig build \
              --system "${zigDeps}" \
              -Demit-xcframework \
              -Demit-macos-app=false \
              -Dsentry=false \
              -Doptimize=ReleaseFast

            if [ ! -d "$WORK_DIR/macos/GhosttyKit.xcframework" ]; then
              echo "Error: GhosttyKit build failed -- xcframework not found"
              rm -rf "$WORK_DIR"
              exit 1
            fi

            TEMP_CACHE=$(/usr/bin/mktemp -d "$CACHE_DIR/tmp.XXXXXX")
            cp -R "$WORK_DIR/macos/GhosttyKit.xcframework" "$TEMP_CACHE/"
            mv "$TEMP_CACHE" "$XCFW_CACHE"
            rm -rf "$WORK_DIR"
            echo "GhosttyKit built and cached at $XCFW_CACHE"
          fi

          rm -rf "$LOCK_DIR" 2>/dev/null || true
          trap - EXIT
        fi
      fi

      # --- Phase 2: Swift app (cached by source + GhosttyKit hash) ---

      SWIFT_HASH=$(cat \
        ${concatMapStringsSep " \\\n        " (f: ''"$SRC_DIR/${baseNameOf f}"'') swiftSources} \
        "${infoPlist}" \
        | /usr/bin/shasum -a 256 | cut -d' ' -f1)
      APP_KEY=$(/usr/bin/shasum -a 256 <<EOF | cut -d' ' -f1
      ghosttykit: $GHOSTTYKIT_KEY
      swift: $SWIFT_HASH
      EOF
      )

      BUILT_KEY=""
      if [ -f "$APP_PATH/.build_key" ]; then
        BUILT_KEY=$(cat "$APP_PATH/.build_key")
      fi

      if [ "$APP_KEY" != "$BUILT_KEY" ]; then
        echo "Building DanTerm app..."
        /usr/bin/killall DanTerm 2>/dev/null || true

        # Find macOS slice of xcframework
        MACOS_DIR="$XCFW_CACHE/GhosttyKit.xcframework/macos-arm64_x86_64"
        if [ ! -d "$MACOS_DIR" ]; then
          MACOS_DIR="$XCFW_CACHE/GhosttyKit.xcframework/macos-arm64"
        fi

        # Build into temp dir, then atomic swap
        BUILD_TMP=$(/usr/bin/mktemp -d)
        BUILD_APP="$BUILD_TMP/DanTerm.app"
        mkdir -p "$BUILD_APP/Contents/MacOS"

        /usr/bin/xcrun swiftc -O \
          -o "$BUILD_APP/Contents/MacOS/DanTerm" \
          ${concatMapStringsSep " \\\n          " (f: ''"$SRC_DIR/${baseNameOf f}"'') swiftSources} \
          -I "$MACOS_DIR/Headers" \
          -Xcc -fmodule-map-file="$MACOS_DIR/Headers/module.modulemap" \
          "$MACOS_DIR/libghostty.a" \
          -framework Cocoa \
          -framework Metal \
          -framework MetalKit \
          -framework QuartzCore \
          -framework CoreText \
          -framework IOKit \
          -framework IOSurface \
          -framework Carbon \
          -framework UniformTypeIdentifiers \
          -lc++

        cp "${infoPlist}" "$BUILD_APP/Contents/"
        mkdir -p "$BUILD_APP/Contents/Resources"
        cp "${./icon/AppIcon/AppIcon.icns}" "$BUILD_APP/Contents/Resources/AppIcon.icns"
        cp "${./icon/AppIcon/Assets.car}" "$BUILD_APP/Contents/Resources/Assets.car"
        /usr/bin/codesign --force --deep --sign - "$BUILD_APP"
        echo "$APP_KEY" > "$BUILD_APP/.build_key"

        # Atomic swap: move old aside, rename new into place, then cleanup
        if [ -d "$APP_PATH" ]; then
          mv "$APP_PATH" "$BUILD_TMP/DanTerm.old.app"
        fi
        mv "$BUILD_APP" "$APP_PATH"
        rm -rf "$BUILD_TMP"

        echo "DanTerm app built successfully"
        ${if cfg.startAtLogin then ''/usr/bin/open "$APP_PATH"'' else ""}
      fi
    '';

    launchd.agents.danterm = mkIf cfg.startAtLogin {
      enable = true;
      config = {
        Label = "com.danneu.danterm";
        ProgramArguments = [
          "${appPath}/Contents/MacOS/DanTerm"
        ];
        RunAtLoad = true;
        KeepAlive = false;
      };
    };
  };
}
