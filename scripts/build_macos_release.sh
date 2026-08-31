#!/bin/zsh
set -e
set -o pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/scripts/terminal_style.sh"
cd "$ROOT"
"$ROOT/scripts/sync_ui_icons.sh"
"$ROOT/scripts/prepare_local_whisper.sh" apple
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
FRAMEWORKS="$CONTENTS/Frameworks"
SIGNING_FINGERPRINT="${SHAR_SIGNING_FINGERPRINT:-B97863CA4E17170FCD5FBFA4C76A8DF3D91D5F6B}"
NOTARY_PROFILE="${SHAR_NOTARY_PROFILE:-workwork-caption-notary}"
APPLE_NETWORK_ATTEMPTS="${SHAR_APPLE_NETWORK_ATTEMPTS:-20}"
APPLE_NETWORK_RETRY_DELAY="${SHAR_APPLE_NETWORK_RETRY_DELAY:-15}"
fail(){ shar_error "$*"; exit 1; }
log(){ shar_section "$*"; }
retry(){ local n=1; local max="$1"; local delay="$2"; shift 2; until "$@"; do local rc=$?; (( n >= max )) && return "$rc"; shar_warn "retry $n/$max in ${delay}s: $*"; sleep "$delay"; n=$((n+1)); done; }

json_field(){
  local field="$1"
  python3 -c 'import json,sys; data=json.load(sys.stdin); value=data.get(sys.argv[1], ""); print(value if value is not None else "")' "$field" 2>/dev/null
}

notarize_and_wait(){
  local artifact="$1" label="$2"
  local submit_output submission_id info_output notary_state elapsed=0
  local poll_seconds="${SHAR_NOTARY_POLL_SECONDS:-20}"
  local max_wait="${SHAR_NOTARY_MAX_WAIT_SECONDS:-21600}"
  local submit_attempt=1 submit_max="${SHAR_NOTARY_SUBMIT_ATTEMPTS:-30}"

  shar_section "Submitting $label to Apple notary service"
  while (( submit_attempt <= submit_max )); do
    local submit_rc=0
    if submit_output="$(xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --output-format json 2>&1)"; then
      submit_rc=0
    else
      submit_rc=$?
    fi
    submission_id="$(printf '%s' "$submit_output" | json_field id || true)"
    if [[ -z "$submission_id" ]]; then
      submission_id="$(printf '%s\n' "$submit_output" | sed -nE 's/^[[:space:]]*id:[[:space:]]*([0-9A-Fa-f-]{36}).*/\1/p' | head -n1)"
    fi

    if [[ -n "$submission_id" ]]; then
      shar_success "$label submission accepted by notary service: $submission_id"
      break
    fi

    if (( submit_attempt >= submit_max )); then
      printf '%s\n' "$submit_output" >&2
      fail "Could not submit $label for notarization after $submit_max attempts."
    fi
    local submit_brief="$(printf '%s\n' "$submit_output" | head -n1)"
    shar_warn "$label notarization submit transport failed (attempt $submit_attempt/$submit_max). Retrying in ${poll_seconds}s without changing the artifact.${submit_brief:+  $submit_brief}"
    sleep "$poll_seconds"
    submit_attempt=$((submit_attempt+1))
  done

  shar_section "Waiting for $label notarization: $submission_id"
  while (( elapsed <= max_wait )); do
    local info_rc=0
    if info_output="$(xcrun notarytool info "$submission_id" --keychain-profile "$NOTARY_PROFILE" --output-format json 2>&1)"; then
      info_rc=0
    else
      info_rc=$?
    fi
    if (( info_rc == 0 )); then
      notary_state="$(printf '%s' "$info_output" | json_field status || true)"
      case "$notary_state" in
        Accepted)
          shar_success "$label notarization accepted: $submission_id"
          return 0
          ;;
        Invalid|Rejected)
          printf '%s\n' "$info_output" >&2
          xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" 2>/dev/null || true
          fail "$label notarization was $notary_state: $submission_id"
          ;;
        *)
          printf '%bNotary status:%b %s — %ss elapsed\n' "$SHAR_C_MUTED" "$SHAR_C_RESET" "${notary_state:-In Progress}" "$elapsed"
          ;;
      esac
    else
      local info_brief="$(printf '%s\n' "$info_output" | head -n1)"
      shar_warn "Apple notary status check is temporarily unavailable; retaining submission $submission_id and retrying in ${poll_seconds}s.${info_brief:+  $info_brief}"
    fi

    sleep "$poll_seconds"
    elapsed=$((elapsed+poll_seconds))
  done

  fail "$label notarization did not finish within ${max_wait}s. Submission remains $submission_id; no duplicate submission was created by Shar."
}

log "Using release credentials prevalidated by release_and_deploy.sh"
IDENTITY_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$SIGNING_FINGERPRINT" | head -n1 || true)"
IDENTITY_NAME="$(printf '%s\n' "$IDENTITY_LINE" | sed -nE 's/.*"([^"]+)".*/\1/p')"
[[ -n "$IDENTITY_NAME" ]] || IDENTITY_NAME="$SIGNING_FINGERPRINT"

for t in xcrun swiftc iconutil codesign ditto plutil lipo otool hdiutil shasum find; do command -v "$t" >/dev/null 2>&1 || fail "Missing tool: $t"; done

resolve_macos_whisper_framework() {
  local xcroot="$ROOT/Dependencies/whisper/whisper.xcframework"
  local candidate binary info plist platform
  WHISPER_FRAMEWORK=""
  WHISPER_FRAMEWORK_BINARY=""
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
      WHISPER_FRAMEWORK_BINARY="$binary"
      break
    fi
  done < <(find "$xcroot" -type d -name whisper.framework -print)
  [[ -n "$WHISPER_FRAMEWORK" ]] || fail "No MacOSX whisper.framework containing both arm64 and x86_64 was found inside the prepared XCFramework."
}

log "Preparing macOS bundle + local Whisper runtime"
rm -rf "$BUILD_ROOT" || fail "Could not clear macOS release build directory."
mkdir -p "$MACOS" "$RES" "$FRAMEWORKS" "$BUILD_ROOT/bin/arm64" "$BUILD_ROOT/bin/x86_64" "$ROOT/release" || fail "Could not create macOS release directories."
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
SOURCES=(
  "$ROOT/LocalWebShare/FileStore.swift"
  "$ROOT/LocalWebShare/MediaSupport.swift"
  "$ROOT/LocalWebShare/GeneratedUIIcons.swift"
  "$ROOT/LocalWebShare/LocalWebServer.swift"
  "$ROOT/LocalWebShare/ThreeDPreview.swift"
  "$ROOT/LocalWebShare/LocalMediaIntelligence.swift"
  "$ROOT/macos/LocalWebShareMacApp.swift"
)
for arch in arm64 x86_64; do
  log "Compiling macOS $arch"
  BRIDGE_OBJ="$BUILD_ROOT/bin/$arch/LocalWhisperBridge.o"
  xcrun --sdk macosx clang -c -isysroot "$SDK" -target "${arch}-apple-macos13.3" -F "$WHISPER_FDIR" \
    "$ROOT/LocalWebShare/LocalWhisperBridge.c" -o "$BRIDGE_OBJ"
  xcrun --sdk macosx swiftc -parse-as-library -sdk "$SDK" -target "${arch}-apple-macos13.3" \
    -o "$BUILD_ROOT/bin/$arch/LocalWebShare" "${SOURCES[@]}" "$BRIDGE_OBJ" \
    -F "$WHISPER_FDIR" -Xlinker -weak_framework -Xlinker whisper -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -framework SwiftUI -framework AppKit -framework AVFoundation -framework AVKit -framework QuickLookUI -framework Network -framework Combine -framework WebKit -framework CoreImage -framework UniformTypeIdentifiers -framework SceneKit -framework ModelIO
 done
lipo -create "$BUILD_ROOT/bin/arm64/LocalWebShare" "$BUILD_ROOT/bin/x86_64/LocalWebShare" -output "$MACOS/LocalWebShare"
lipo -info "$MACOS/LocalWebShare"
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
<key>CFBundleIdentifier</key><string>xyz.mojoworks.shar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUM</string>
<key>LSMinimumSystemVersion</key><string>13.3</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Shar uses the local network to share files with nearby devices.</string>
</dict></plist>
PLIST
plutil -lint "$CONTENTS/Info.plist" >/dev/null

log "Signing macOS app: $IDENTITY_NAME"
retry "$APPLE_NETWORK_ATTEMPTS" "$APPLE_NETWORK_RETRY_DELAY" codesign --force --options runtime --timestamp --sign "$SIGNING_FINGERPRINT" "$FRAMEWORKS/whisper.framework"
retry "$APPLE_NETWORK_ATTEMPTS" "$APPLE_NETWORK_RETRY_DELAY" codesign --force --options runtime --timestamp --deep --sign "$SIGNING_FINGERPRINT" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
NOTARY_ZIP="$BUILD_ROOT/LocalWebShare-notary.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"
log "Notarizing macOS app"
notarize_and_wait "$NOTARY_ZIP" "macOS app"
retry 60 20 xcrun stapler staple "$APP"
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
retry "$APPLE_NETWORK_ATTEMPTS" "$APPLE_NETWORK_RETRY_DELAY" codesign --force --timestamp --sign "$SIGNING_FINGERPRINT" "$DMG"
log "Notarizing macOS DMG"
notarize_and_wait "$DMG" "macOS DMG"
retry 60 20 xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
(
  cd "$ROOT/release"
  shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > "$(basename "$SHA")"
  shasum -a 256 -c "$(basename "$SHA")"
)
log "macOS release complete"
printf 'DMG: %s\nZIP: %s\nSHA: %s\n' "$DMG" "$ZIP" "$SHA"
