#!/bin/zsh
set -e
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/terminal_style.sh"
cd "$ROOT"

"$SCRIPT_DIR/sync_ui_icons.sh"
"$SCRIPT_DIR/prepare_local_whisper.sh" apple

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(python3 - "$VERSION" <<'PY'
import sys
a,b,c=map(int,sys.argv[1].split('.'))
print(a*10000+b*100+c)
PY
)"
BUILD_ROOT="$ROOT/build/macos"
APP="$BUILD_ROOT/Shar.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
INSTALL_DIR="${MAC_INSTALL_DIR:-$HOME/Applications}"
INSTALL_APP="$INSTALL_DIR/Shar.app"
LEGACY_INSTALL_APP="$INSTALL_DIR/LocalWebShare.app"
NO_LAUNCH=0
[[ "${1:-}" == "--no-launch" ]] && NO_LAUNCH=1

say(){ shar_section "$*"; }
fail(){ shar_error "$*"; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail "macOS build must run on macOS."
for t in xcrun swiftc iconutil codesign ditto plutil open lipo otool find; do command -v "$t" >/dev/null 2>&1 || fail "Missing tool: $t"; done

resolve_macos_whisper_framework() {
  local xcroot="$ROOT/Dependencies/whisper/whisper.xcframework"
  local candidate binary info plist platform
  WHISPER_FRAMEWORK=""
  [[ -d "$xcroot" ]] || fail "Prepared whisper.xcframework is missing: $xcroot"
  while IFS= read -r candidate; do
    [[ -d "$candidate" ]] || continue
    if [[ -f "$candidate/Versions/Current/whisper" ]]; then
      binary="$candidate/Versions/Current/whisper"
    elif [[ -f "$candidate/Versions/A/whisper" ]]; then
      binary="$candidate/Versions/A/whisper"
    elif [[ -f "$candidate/whisper" ]]; then
      binary="$candidate/whisper"
    else
      continue
    fi
    if [[ -f "$candidate/Versions/A/Resources/Info.plist" ]]; then
      plist="$candidate/Versions/A/Resources/Info.plist"
    elif [[ -f "$candidate/Resources/Info.plist" ]]; then
      plist="$candidate/Resources/Info.plist"
    elif [[ -f "$candidate/Info.plist" ]]; then
      plist="$candidate/Info.plist"
    else
      printf 'Whisper framework candidate: %s\n  skipped: framework Info.plist missing\n' "$candidate"
      continue
    fi
    platform="$(plutil -extract CFBundleSupportedPlatforms.0 raw -o - "$plist" 2>/dev/null || true)"
    info="$(lipo -info "$binary" 2>&1 || true)"
    printf 'Whisper framework candidate: %s\n  platform: %s\n  %s\n' "$candidate" "${platform:-unknown}" "$info"
    [[ "$platform" == "MacOSX" ]] || continue
    if [[ "$info" == *arm64* && "$info" == *x86_64* ]]; then
      WHISPER_FRAMEWORK="$candidate"
      break
    fi
  done < <(find "$xcroot" -type d -name whisper.framework -print)
  [[ -n "$WHISPER_FRAMEWORK" ]] || fail "No MacOSX whisper.framework containing both arm64 and x86_64 was found inside the prepared XCFramework."
}

say "Building macOS Shar v$VERSION"
rm -rf "$BUILD_ROOT" || fail "Could not clear macOS development build directory."
mkdir -p "$MACOS" "$RES" "$FRAMEWORKS" "$ROOT/release" || fail "Could not create macOS development directories."

iconutil -c icns "$ROOT/macos/AppIcon.iconset" -o "$RES/AppIcon.icns" || fail "Could not build the macOS app icon."
cp "$ROOT/assets/shar-logo-1024.png" "$RES/shar-logo-1024.png" || fail "Could not copy the Shar logo resource."
[[ -f "$ROOT/Dependencies/whisper/models/ggml-base.bin" ]] || fail "Prepared local Whisper model is missing."
cp "$ROOT/Dependencies/whisper/models/ggml-base.bin" "$RES/ggml-base.bin" || fail "Could not bundle the local Whisper model."
resolve_macos_whisper_framework
WHISPER_FDIR="$(dirname "$WHISPER_FRAMEWORK")"
printf 'Using macOS Whisper framework: %s\n' "$WHISPER_FRAMEWORK"
ditto "$WHISPER_FRAMEWORK" "$FRAMEWORKS/whisper.framework" || fail "Could not bundle macOS whisper.framework."
[[ -e "$FRAMEWORKS/whisper.framework/whisper" || -e "$FRAMEWORKS/whisper.framework/Versions/Current/whisper" || -e "$FRAMEWORKS/whisper.framework/Versions/A/whisper" ]] || fail "Bundled macOS whisper.framework has no executable."

SDK="$(xcrun --sdk macosx --show-sdk-path)" || fail "Could not resolve the macOS SDK."
ARCH="$(uname -m)"
case "$ARCH" in arm64|x86_64) ;; *) fail "Unsupported Mac architecture: $ARCH";; esac

BRIDGE_OBJ="$BUILD_ROOT/LocalWhisperBridge.o"
xcrun --sdk macosx clang -c -isysroot "$SDK" -target "${ARCH}-apple-macos13.3" -F "$WHISPER_FDIR" \
  "$ROOT/LocalWebShare/LocalWhisperBridge.c" -o "$BRIDGE_OBJ"
xcrun --sdk macosx swiftc \
  -parse-as-library \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos13.3" \
  -o "$MACOS/LocalWebShare" \
  "$ROOT/LocalWebShare/FileStore.swift" \
  "$ROOT/LocalWebShare/MediaSupport.swift" \
  "$ROOT/LocalWebShare/GeneratedUIIcons.swift" \
  "$ROOT/LocalWebShare/LocalWebServer.swift" \
  "$ROOT/LocalWebShare/ThreeDPreview.swift" \
  "$ROOT/LocalWebShare/LocalMediaIntelligence.swift" \
  "$ROOT/macos/LocalWebShareMacApp.swift" "$BRIDGE_OBJ" \
  -F "$WHISPER_FDIR" -Xlinker -weak_framework -Xlinker whisper -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework AVKit \
  -framework QuickLookUI -framework Network -framework Combine -framework WebKit -framework CoreImage -framework UniformTypeIdentifiers -framework SceneKit -framework ModelIO

if ! otool -l "$MACOS/LocalWebShare" | awk '
  /cmd LC_LOAD_WEAK_DYLIB/ { weak=1; next }
  weak && /name @rpath\/whisper\.framework\/Versions\/Current\/whisper/ { found=1 }
  /Load command/ { weak=0 }
  END { exit(found ? 0 : 1) }
'; then
  fail "macOS executable does not weak-link whisper.framework; refusing a build that can die during dyld startup."
fi
shar_success "macOS Whisper launch dependency is weak-linked"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>Shar</string>
<key>CFBundleName</key><string>Shar</string>
<key>CFBundleExecutable</key><string>LocalWebShare</string>
<key>CFBundleIdentifier</key><string>com.localwebshare.macos</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>13.3</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$CONTENTS/Info.plist" >/dev/null
codesign --force --sign - "$FRAMEWORKS/whisper.framework"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ZIP="$ROOT/release/LocalWebShare-v${VERSION}-macOS-${ARCH}.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

say "Installing into $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_APP" "$LEGACY_INSTALL_APP"
ditto "$APP" "$INSTALL_APP"

if (( ! NO_LAUNCH )); then
  say "Launching macOS app"
  open "$INSTALL_APP"
fi

say "Done"
printf 'App: %s\nRelease: %s\nShared files: %s\n' "$INSTALL_APP" "$ZIP" "$HOME/Library/Application Support/LocalWebShare/Shared"
