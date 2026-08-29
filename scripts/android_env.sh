#!/bin/zsh
# Shared JDK 17 + Android SDK discovery for Shar release scripts.

SHAR_ANDROID_API_LEVEL="${SHAR_ANDROID_API_LEVEL:-35}"
SHAR_ANDROID_BUILD_TOOLS_VERSION="${SHAR_ANDROID_BUILD_TOOLS_VERSION:-35.0.0}"
SHAR_ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"

shar_android_fail(){ printf 'ERROR: %s\n' "$*" >&2; return 1; }
shar_android_log(){ printf '\n==> %s\n' "$*"; }

shar_java_major(){
  "$1" -version 2>&1 | awk -F'[".]' '/version/ { if ($2 == "1") print $3; else print $2; exit }'
}

shar_android_select_java(){
  local j major
  local candidates
  candidates=(
    "${SHAR_ANDROID_JAVA_HOME:-}"
    "${JAVA_HOME:-}"
    "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
    "/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
    "$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  )
  for j in "${candidates[@]}"; do
    [[ -n "$j" && -x "$j/bin/java" ]] || continue
    major="$(shar_java_major "$j/bin/java")"
    if [[ "$major" == 17 ]]; then
      export JAVA_HOME="$j"
      export PATH="$JAVA_HOME/bin:$PATH"
      return 0
    fi
  done
  if command -v brew >/dev/null 2>&1 && [[ "${SHAR_ANDROID_AUTO_INSTALL_TOOLS:-1}" == 1 ]]; then
    shar_android_log "Installing Homebrew OpenJDK 17"
    brew list --versions openjdk@17 >/dev/null 2>&1 || brew install openjdk@17
    for j in \
      "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home" \
      "/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"; do
      if [[ -x "$j/bin/java" && "$(shar_java_major "$j/bin/java")" == 17 ]]; then
        export JAVA_HOME="$j"
        export PATH="$JAVA_HOME/bin:$PATH"
        return 0
      fi
    done
  fi
  shar_android_fail "JDK 17 not found. Existing Android Studio or Homebrew openjdk@17 is required."
}

shar_android_find_sdkmanager(){
  local c
  for c in \
    "$SHAR_ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" \
    "$SHAR_ANDROID_SDK_ROOT/cmdline-tools/bin/sdkmanager" \
    "/opt/homebrew/share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager" \
    "/usr/local/share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager"; do
    [[ -x "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

shar_android_env(){
  shar_android_select_java || return 1
  export ANDROID_SDK_ROOT="$SHAR_ANDROID_SDK_ROOT"
  export ANDROID_HOME="$SHAR_ANDROID_SDK_ROOT"

  local sdkmanager=""
  sdkmanager="$(shar_android_find_sdkmanager 2>/dev/null || true)"
  if [[ ! -d "$SHAR_ANDROID_SDK_ROOT/platforms/android-$SHAR_ANDROID_API_LEVEL" || ! -d "$SHAR_ANDROID_SDK_ROOT/build-tools/$SHAR_ANDROID_BUILD_TOOLS_VERSION" || ! -x "$SHAR_ANDROID_SDK_ROOT/platform-tools/adb" ]]; then
    if [[ -z "$sdkmanager" && "${SHAR_ANDROID_AUTO_INSTALL_TOOLS:-1}" == 1 ]] && command -v brew >/dev/null 2>&1; then
      shar_android_log "Installing Android command-line tools with Homebrew"
      brew list --cask android-commandlinetools >/dev/null 2>&1 || brew install --cask android-commandlinetools
      sdkmanager="$(shar_android_find_sdkmanager 2>/dev/null || true)"
    fi
    [[ -n "$sdkmanager" ]] || return 1
    shar_android_log "Installing required Android SDK packages"
    yes | "$sdkmanager" --sdk_root="$SHAR_ANDROID_SDK_ROOT" --licenses >/dev/null 2>&1 || true
    "$sdkmanager" --sdk_root="$SHAR_ANDROID_SDK_ROOT" \
      "platform-tools" \
      "platforms;android-$SHAR_ANDROID_API_LEVEL" \
      "build-tools;$SHAR_ANDROID_BUILD_TOOLS_VERSION"
  fi
}
