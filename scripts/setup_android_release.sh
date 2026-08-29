#!/bin/zsh
set -e
set -o pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/scripts/android_env.sh"
shar_android_select_java
KEYSTORE_PATH="${SHAR_ANDROID_KEYSTORE:-$HOME/.config/workwork/shar-android-release.keystore}"
KEY_ALIAS="${SHAR_ANDROID_KEY_ALIAS:-shar}"
KEYCHAIN_SERVICE="${SHAR_ANDROID_KEYCHAIN_SERVICE:-workwork.shar.android.keystore}"
KEYCHAIN_ACCOUNT="${SHAR_ANDROID_KEYCHAIN_ACCOUNT:-shar}"
fail(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "Android release signing setup must run on macOS."
for t in security openssl; do command -v "$t" >/dev/null 2>&1 || fail "Missing required tool: $t"; done
KEYTOOL="$JAVA_HOME/bin/keytool"
[[ -x "$KEYTOOL" ]] || fail "keytool missing from JDK 17: $JAVA_HOME"
if [[ -f "$KEYSTORE_PATH" ]]; then
  PASSWORD="$(security find-generic-password -w -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" 2>/dev/null || true)"
  [[ -n "$PASSWORD" ]] || fail "Android release keystore exists but its password is missing from macOS Keychain: $KEYCHAIN_SERVICE"
  "$KEYTOOL" -list -keystore "$KEYSTORE_PATH" -storepass "$PASSWORD" -alias "$KEY_ALIAS" >/dev/null 2>&1 || fail "Existing Android release keystore/alias is not usable."
  printf 'Android release signing already configured: %s\n' "$KEYSTORE_PATH"
  exit 0
fi
mkdir -p "$(dirname "$KEYSTORE_PATH")"
umask 077
PASSWORD="$(openssl rand -hex 24)"
"$KEYTOOL" -genkeypair -v -keystore "$KEYSTORE_PATH" -storepass "$PASSWORD" -keypass "$PASSWORD" -alias "$KEY_ALIAS" -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=Shar, OU=MOJOWORKS, O=MOJOWORKS"
security add-generic-password -U -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w "$PASSWORD" >/dev/null
chmod 600 "$KEYSTORE_PATH"
printf 'Created Android release signing key: %s\n' "$KEYSTORE_PATH"
printf 'Password stored in macOS Keychain service: %s\n' "$KEYCHAIN_SERVICE"
printf 'IMPORTANT: back up this keystore; future Android upgrades must use the same signing key.\n'
