#!/bin/zsh
set -e
set -o pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/scripts/android_env.sh"
shar_android_env
KEYSTORE_PATH="${SHAR_ANDROID_KEYSTORE:-$HOME/.config/workwork/shar-android-release.keystore}"
KEY_ALIAS="${SHAR_ANDROID_KEY_ALIAS:-shar}"
KEYCHAIN_SERVICE="${SHAR_ANDROID_KEYCHAIN_SERVICE:-workwork.shar.android.keystore}"
KEYCHAIN_ACCOUNT="${SHAR_ANDROID_KEYCHAIN_ACCOUNT:-shar}"
fail(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ -f "$KEYSTORE_PATH" ]] || fail "Android release keystore missing: $KEYSTORE_PATH"
PASSWORD="$(security find-generic-password -w -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" 2>/dev/null || true)"
[[ -n "$PASSWORD" ]] || fail "Android keystore password missing from macOS Keychain."
"$JAVA_HOME/bin/keytool" -list -keystore "$KEYSTORE_PATH" -storepass "$PASSWORD" -alias "$KEY_ALIAS" >/dev/null 2>&1 || fail "Android release keystore or alias is not usable."
printf 'Android release signing is usable: %s (%s)\n' "$KEYSTORE_PATH" "$KEY_ALIAS"
