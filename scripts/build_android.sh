#!/bin/zsh
set -e
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

"$SCRIPT_DIR/sync_ui_icons.sh"

VERSION="$(tr -d '[:space:]' < VERSION)"
ANDROID_DIR="$ROOT/android"
BUILD_ROOT="$ROOT/build/android-tools"
GRADLE_VERSION="${GRADLE_VERSION:-8.9}"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
NO_INSTALL=0
[[ "${1:-}" == "--no-install" ]] && NO_INSTALL=1

say(){ printf '\n==> %s\n' "$*"; }
fail(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail "Android build script is configured for the macOS release host."
command -v curl >/dev/null 2>&1 || fail "curl is required."
command -v unzip >/dev/null 2>&1 || fail "unzip is required."
[[ -f "$ANDROID_DIR/settings.gradle" ]] || fail "Android project is missing."

# Java 17: explicit override -> Homebrew -> macOS registered JDK -> Android Studio.
JAVA_HOME_CANDIDATES=(
  "${JAVA_HOME:-}"
  "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
  "/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
  "$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
  "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
)
FOUND_JAVA=""
for j in "${JAVA_HOME_CANDIDATES[@]}"; do
  if [[ -n "$j" && -x "$j/bin/java" ]]; then
    major="$($j/bin/java -version 2>&1 | awk -F'[".]' '/version/ { if ($2 == "1") print $3; else print $2; exit }')"
    if [[ "$major" == "17" ]]; then FOUND_JAVA="$j"; break; fi
  fi
done
[[ -n "$FOUND_JAVA" ]] || fail "JDK 17 not found. Install Android Studio or Homebrew openjdk@17."
export JAVA_HOME="$FOUND_JAVA"
export PATH="$JAVA_HOME/bin:$PATH"

export ANDROID_SDK_ROOT="$SDK_ROOT"
export ANDROID_HOME="$SDK_ROOT"

SDKMANAGER=""
for c in \
  "$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" \
  "$SDK_ROOT/cmdline-tools/bin/sdkmanager" \
  "/opt/homebrew/share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager" \
  "/usr/local/share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager"; do
  [[ -x "$c" ]] && { SDKMANAGER="$c"; break; }
done

if [[ ! -d "$SDK_ROOT/platforms/android-35" || ! -d "$SDK_ROOT/build-tools/35.0.0" ]]; then
  [[ -n "$SDKMANAGER" ]] || fail "Android SDK API 35/build-tools 35.0.0 missing and sdkmanager was not found."
  say "Installing required Android SDK packages"
  yes | "$SDKMANAGER" --sdk_root="$SDK_ROOT" --licenses >/dev/null 2>&1 || true
  "$SDKMANAGER" --sdk_root="$SDK_ROOT" "platform-tools" "platforms;android-35" "build-tools;35.0.0"
fi

mkdir -p "$BUILD_ROOT" "$ROOT/release"
GRADLE_HOME="$BUILD_ROOT/gradle-$GRADLE_VERSION"
if [[ ! -x "$GRADLE_HOME/bin/gradle" ]]; then
  ZIP="$BUILD_ROOT/gradle-$GRADLE_VERSION-bin.zip"
  if [[ ! -s "$ZIP" ]]; then
    say "Downloading Gradle $GRADLE_VERSION"
    curl --fail --location --retry 3 "https://services.gradle.org/distributions/gradle-$GRADLE_VERSION-bin.zip" -o "$ZIP"
  fi
  rm -rf "$GRADLE_HOME"
  unzip -q "$ZIP" -d "$BUILD_ROOT"
fi

say "Building Android APK v$VERSION"
"$GRADLE_HOME/bin/gradle" --no-daemon --console=plain -p "$ANDROID_DIR" clean assembleDebug
APK_SRC="$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
[[ -s "$APK_SRC" ]] || fail "Android APK was not produced."
APK="$ROOT/release/LocalWebShare-v${VERSION}-android-debug.apk"
cp "$APK_SRC" "$APK"
shasum -a 256 "$APK" > "$APK.sha256"

ADB="$SDK_ROOT/platform-tools/adb"
if (( ! NO_INSTALL )) && [[ -x "$ADB" ]]; then
  DEVICE="$($ADB devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
  if [[ -n "$DEVICE" ]]; then
    say "Installing on Android device $DEVICE"
    "$ADB" -s "$DEVICE" install -r "$APK"
    "$ADB" -s "$DEVICE" shell am force-stop com.localwebshare.app || true
    "$ADB" -s "$DEVICE" shell am start -n com.localwebshare.app/.MainActivity
  else
    say "No authorised Android device attached; APK built without installation"
  fi
fi

say "Done"
printf 'APK: %s\n' "$APK"
