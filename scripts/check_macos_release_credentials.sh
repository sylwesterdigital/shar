#!/bin/zsh
set -e
set -o pipefail
SIGNING_FINGERPRINT="${SHAR_SIGNING_FINGERPRINT:-B97863CA4E17170FCD5FBFA4C76A8DF3D91D5F6B}"
NOTARY_PROFILE="${SHAR_NOTARY_PROFILE:-workwork-caption-notary}"
fail(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "macOS release must run on macOS."
for t in security xcrun codesign; do command -v "$t" >/dev/null 2>&1 || fail "Missing tool: $t"; done
IDENTITY_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$SIGNING_FINGERPRINT" | head -n 1 || true)"
[[ -n "$IDENTITY_LINE" ]] || fail "Developer ID signing fingerprint not found: $SIGNING_FINGERPRINT"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null 2>&1 \
  || fail "Apple notarization profile is not usable: $NOTARY_PROFILE"
printf 'macOS Developer ID and notarization credentials are usable.\n%s\n' "$IDENTITY_LINE"
