#!/bin/zsh
set -e
set -o pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
"$ROOT/scripts/sync_ui_icons.sh"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUM="$(python3 - "$VERSION" <<'PY'
import sys
a,b,c=map(int,sys.argv[1].split('.')); print(a*10000+b*100+c)
PY
)"
BUILD_ROOT="$ROOT/build/macos-release"
APP="$BUILD_ROOT/Shar.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
SIGNING_FINGERPRINT="${SHAR_SIGNING_FINGERPRINT:-B97863CA4E17170FCD5FBFA4C76A8DF3D91D5F6B}"
NOTARY_PROFILE="${SHAR_NOTARY_PROFILE:-workwork-caption-notary}"
fail(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
log(){ printf '\n==> %s\n' "$*"; }
retry(){ local n=1; local max="$1"; local delay="$2"; shift 2; until "$@"; do local rc=$?; (( n >= max )) && return "$rc"; printf 'WARNING: retry %d/%d in %ss: %s\n' "$n" "$max" "$delay" "$*" >&2; sleep "$delay"; n=$((n+1)); done; }

"$ROOT/scripts/check_macos_release_credentials.sh" >/dev/null
IDENTITY_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$SIGNING_FINGERPRINT" | head -n1 || true)"
IDENTITY_NAME="$(printf '%s\n' "$IDENTITY_LINE" | sed -nE 's/.*"([^"]+)".*/\1/p')"
[[ -n "$IDENTITY_NAME" ]] || IDENTITY_NAME="$SIGNING_FINGERPRINT"

for t in xcrun swiftc iconutil codesign ditto plutil lipo hdiutil shasum; do command -v "$t" >/dev/null 2>&1 || fail "Missing tool: $t"; done
rm -rf "$BUILD_ROOT"
mkdir -p "$MACOS" "$RES" "$BUILD_ROOT/bin/arm64" "$BUILD_ROOT/bin/x86_64" "$ROOT/release"
iconutil -c icns "$ROOT/macos/AppIcon.iconset" -o "$RES/AppIcon.icns"
cp "$ROOT/assets/shar-logo-1024.png" "$RES/shar-logo-1024.png"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SOURCES=(
  "$ROOT/LocalWebShare/FileStore.swift"
  "$ROOT/LocalWebShare/MediaSupport.swift"
  "$ROOT/LocalWebShare/GeneratedUIIcons.swift"
  "$ROOT/LocalWebShare/LocalWebServer.swift"
  "$ROOT/macos/LocalWebShareMacApp.swift"
)
for arch in arm64 x86_64; do
  log "Compiling macOS $arch"
  xcrun --sdk macosx swiftc -parse-as-library -sdk "$SDK" -target "${arch}-apple-macos13.0" \
    -o "$BUILD_ROOT/bin/$arch/LocalWebShare" "${SOURCES[@]}" \
    -framework SwiftUI -framework AppKit -framework AVFoundation -framework AVKit -framework QuickLookUI -framework Network -framework Combine
 done
lipo -create "$BUILD_ROOT/bin/arm64/LocalWebShare" "$BUILD_ROOT/bin/x86_64/LocalWebShare" -output "$MACOS/LocalWebShare"
lipo -info "$MACOS/LocalWebShare"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>Shar</string>
<key>CFBundleName</key><string>LocalWebShare</string>
<key>CFBundleExecutable</key><string>LocalWebShare</string>
<key>CFBundleIdentifier</key><string>xyz.mojoworks.shar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUM</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Shar uses the local network to share files with nearby devices.</string>
</dict></plist>
PLIST
plutil -lint "$CONTENTS/Info.plist" >/dev/null

log "Signing macOS app: $IDENTITY_NAME"
codesign --force --options runtime --timestamp --deep --sign "$SIGNING_FINGERPRINT" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
NOTARY_ZIP="$BUILD_ROOT/LocalWebShare-notary.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"
log "Notarizing macOS app"
retry 3 12 xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP"

ZIP="$ROOT/release/LocalWebShare-v${VERSION}-macOS-universal2.zip"
DMG="$ROOT/release/LocalWebShare-v${VERSION}-macOS-universal2.dmg"
SHA="$ROOT/release/LocalWebShare-v${VERSION}-macOS-SHA256.txt"
rm -f "$ZIP" "$DMG" "$SHA"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
DMG_STAGE="$(mktemp -d /tmp/shar-dmg.XXXXXX)"
trap 'rm -rf "$DMG_STAGE"' EXIT
ditto "$APP" "$DMG_STAGE/Shar.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "Shar" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGNING_FINGERPRINT" "$DMG"
log "Notarizing macOS DMG"
retry 3 12 xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
(
  cd "$ROOT/release"
  shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > "$(basename "$SHA")"
  shasum -a 256 -c "$(basename "$SHA")"
)
log "macOS release complete"
printf 'DMG: %s\nZIP: %s\nSHA: %s\n' "$DMG" "$ZIP" "$SHA"
