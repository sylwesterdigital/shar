#!/bin/zsh
set -e
set -o pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/scripts/terminal_style.sh"
cd "$ROOT"
source "$ROOT/scripts/android_env.sh"
shar_android_env
"$ROOT/scripts/sync_ui_icons.sh"
"$ROOT/scripts/prepare_local_whisper.sh" android

VERSION="$(tr -d '[:space:]' < VERSION)"
ANDROID_DIR="$ROOT/android"
BUILD_ROOT="$ROOT/build/android-release-tools"
GRADLE_VERSION="${GRADLE_VERSION:-8.9}"
KEYSTORE_PATH="${SHAR_ANDROID_KEYSTORE:-$HOME/.config/workwork/shar-android-release.keystore}"
KEY_ALIAS="${SHAR_ANDROID_KEY_ALIAS:-shar}"
KEYCHAIN_SERVICE="${SHAR_ANDROID_KEYCHAIN_SERVICE:-workwork.shar.android.keystore}"
KEYCHAIN_ACCOUNT="${SHAR_ANDROID_KEYCHAIN_ACCOUNT:-shar}"
fail(){ shar_error "$*"; exit 1; }
log(){ shar_section "$*"; }

"$ROOT/scripts/check_android_release_credentials.sh" >/dev/null
PASSWORD="$(security find-generic-password -w -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE")"
export SHAR_ANDROID_KEYSTORE="$KEYSTORE_PATH"
export SHAR_ANDROID_KEY_ALIAS="$KEY_ALIAS"
export SHAR_ANDROID_STORE_PASSWORD="$PASSWORD"
export SHAR_ANDROID_KEY_PASSWORD="$PASSWORD"

mkdir -p "$BUILD_ROOT" "$ROOT/release"
GRADLE_HOME="$BUILD_ROOT/gradle-$GRADLE_VERSION"
if [[ ! -x "$GRADLE_HOME/bin/gradle" ]]; then
  ZIP="$BUILD_ROOT/gradle-$GRADLE_VERSION-bin.zip"
  if [[ ! -s "$ZIP" ]]; then
    log "Downloading Gradle $GRADLE_VERSION"
    curl --fail --location --retry 3 "https://services.gradle.org/distributions/gradle-$GRADLE_VERSION-bin.zip" -o "$ZIP"
  fi
  rm -rf "$GRADLE_HOME"
  unzip -q "$ZIP" -d "$BUILD_ROOT"
fi

log "Building signed Android release v$VERSION"
"$GRADLE_HOME/bin/gradle" --no-daemon --console=plain -p "$ANDROID_DIR" clean assembleRelease bundleRelease
APK_SRC="$ANDROID_DIR/app/build/outputs/apk/release/app-release.apk"
AAB_SRC="$ANDROID_DIR/app/build/outputs/bundle/release/app-release.aab"
[[ -s "$APK_SRC" ]] || fail "Signed release APK was not produced."
[[ -s "$AAB_SRC" ]] || fail "Signed release AAB was not produced."

# The bundled Whisper model must remain stored (not deflated). Compressing this
# ~148 MB binary is what previously exhausted the Gradle packaging heap.
python3 - "$APK_SRC" <<'PYMODEL'
import sys, zipfile
apk = sys.argv[1]
entry = "assets/models/ggml-base.bin"
with zipfile.ZipFile(apk) as zf:
    try:
        info = zf.getinfo(entry)
    except KeyError:
        raise SystemExit(f"ERROR: Android APK is missing {entry}")
    if info.compress_type != zipfile.ZIP_STORED:
        raise SystemExit(f"ERROR: {entry} is compressed in the APK; expected ZIP_STORED")
print(f"Android Whisper model packaging verified: {entry} is stored uncompressed ({info.file_size} bytes)")
PYMODEL
APK="$ROOT/release/LocalWebShare-v${VERSION}-android.apk"
AAB="$ROOT/release/LocalWebShare-v${VERSION}-android.aab"
SHA="$ROOT/release/LocalWebShare-v${VERSION}-android-SHA256.txt"
cp "$APK_SRC" "$APK"
cp "$AAB_SRC" "$AAB"

APKSIGNER="$ANDROID_SDK_ROOT/build-tools/$SHAR_ANDROID_BUILD_TOOLS_VERSION/apksigner"
[[ -x "$APKSIGNER" ]] || APKSIGNER="$SHAR_ANDROID_SDK_ROOT/build-tools/$SHAR_ANDROID_BUILD_TOOLS_VERSION/apksigner"
if [[ -x "$APKSIGNER" ]]; then
  "$APKSIGNER" verify --verbose "$APK" >/dev/null || fail "APK signature verification failed."
fi
"$JAVA_HOME/bin/jarsigner" -verify "$AAB" >/dev/null 2>&1 || fail "AAB signature verification failed."
(
  cd "$ROOT/release"
  shasum -a 256 "$(basename "$APK")" "$(basename "$AAB")" > "$(basename "$SHA")"
  shasum -a 256 -c "$(basename "$SHA")"
)
log "Android release complete"
printf 'APK: %s\nAAB: %s\nSHA: %s\n' "$APK" "$AAB" "$SHA"
