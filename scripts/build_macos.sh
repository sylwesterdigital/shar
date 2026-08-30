#!/bin/zsh
set -e
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

"$SCRIPT_DIR/sync_ui_icons.sh"

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(python3 - "$VERSION" <<'PY'
import sys
a,b,c=map(int,sys.argv[1].split('.'))
print(a*10000+b*100+c)
PY
)"
BUILD_ROOT="$ROOT/build/macos"
APP="$BUILD_ROOT/LocalWebShare.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
INSTALL_DIR="${MAC_INSTALL_DIR:-$HOME/Applications}"
INSTALL_APP="$INSTALL_DIR/LocalWebShare.app"
NO_LAUNCH=0
[[ "${1:-}" == "--no-launch" ]] && NO_LAUNCH=1

say(){ printf '\n==> %s\n' "$*"; }
fail(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail "macOS build must run on macOS."
for t in xcrun swiftc iconutil codesign ditto plutil open; do command -v "$t" >/dev/null 2>&1 || fail "Missing tool: $t"; done

say "Building macOS LocalWebShare v$VERSION"
rm -rf "$BUILD_ROOT"
mkdir -p "$MACOS" "$RES" "$ROOT/release"

iconutil -c icns "$ROOT/macos/AppIcon.iconset" -o "$RES/AppIcon.icns"
cp "$ROOT/assets/shar-logo-1024.png" "$RES/shar-logo-1024.png"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
case "$ARCH" in arm64|x86_64) ;; *) fail "Unsupported Mac architecture: $ARCH";; esac

xcrun --sdk macosx swiftc \
  -parse-as-library \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos13.0" \
  -o "$MACOS/LocalWebShare" \
  "$ROOT/LocalWebShare/FileStore.swift" \
  "$ROOT/LocalWebShare/MediaSupport.swift" \
  "$ROOT/LocalWebShare/GeneratedUIIcons.swift" \
  "$ROOT/LocalWebShare/LocalWebServer.swift" \
  "$ROOT/macos/LocalWebShareMacApp.swift" \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework AVKit \
  -framework QuickLookUI -framework Network -framework Combine -framework WebKit -framework CoreImage -framework UniformTypeIdentifiers

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>Shar</string>
<key>CFBundleName</key><string>LocalWebShare</string>
<key>CFBundleExecutable</key><string>LocalWebShare</string>
<key>CFBundleIdentifier</key><string>com.localwebshare.macos</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$CONTENTS/Info.plist" >/dev/null
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ZIP="$ROOT/release/LocalWebShare-v${VERSION}-macOS-${ARCH}.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

say "Installing into $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_APP"
ditto "$APP" "$INSTALL_APP"

if (( ! NO_LAUNCH )); then
  say "Launching macOS app"
  open "$INSTALL_APP"
fi

say "Done"
printf 'App: %s\nRelease: %s\nShared files: %s\n' "$INSTALL_APP" "$ZIP" "$HOME/Library/Application Support/LocalWebShare/Shared"
