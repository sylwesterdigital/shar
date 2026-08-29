#!/bin/zsh
set -e
set -o pipefail
export GIT_PAGER=cat PAGER=cat GH_PAGER=cat GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
GH_REPO="${GH_REPO:-sylwesterdigital/shar}"
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="${RELEASE_TAG:-v$VERSION}"
RELEASE_DIR="$ROOT/release"
NOTES="$RELEASE_DIR/LocalWebShare-v${VERSION}-RELEASE_NOTES.md"
log(){ printf '\n==> %s\n' "$*"; }
fail(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
retry(){ local n=1 max="$1" delay="$2"; shift 2; until "$@"; do local rc=$?; (( n >= max )) && return "$rc"; printf 'WARNING: retry %d/%d in %ss: %s\n' "$n" "$max" "$delay" "$*" >&2; sleep "$delay"; n=$((n+1)); done; }
for t in gh git shasum awk; do command -v "$t" >/dev/null 2>&1 || fail "Missing required tool: $t"; done
gh auth status -h github.com >/dev/null 2>&1 || fail "GitHub CLI is not authenticated."

MAC_DMG="$RELEASE_DIR/LocalWebShare-v${VERSION}-macOS-universal2.dmg"
MAC_ZIP="$RELEASE_DIR/LocalWebShare-v${VERSION}-macOS-universal2.zip"
MAC_SHA="$RELEASE_DIR/LocalWebShare-v${VERSION}-macOS-SHA256.txt"
APK="$RELEASE_DIR/LocalWebShare-v${VERSION}-android.apk"
AAB="$RELEASE_DIR/LocalWebShare-v${VERSION}-android.aab"
ANDROID_SHA="$RELEASE_DIR/LocalWebShare-v${VERSION}-android-SHA256.txt"
assets=("$MAC_DMG" "$MAC_ZIP" "$MAC_SHA" "$APK" "$AAB" "$ANDROID_SHA")
for f in "${assets[@]}"; do [[ -s "$f" ]] || fail "Missing release artifact: $f"; done
(
  cd "$RELEASE_DIR"
  shasum -a 256 -c "$(basename "$MAC_SHA")"
  shasum -a 256 -c "$(basename "$ANDROID_SHA")"
)

CHANGELOG_SECTION="$(awk -v v="$VERSION" '
  $0 == "## [" v "] - 2026-08-29" {show=1; next}
  /^## \[/ && show {exit}
  show {print}
' CHANGELOG.md)"
if [[ -z "$CHANGELOG_SECTION" ]]; then
  CHANGELOG_SECTION="$(awk -v v="$VERSION" '
    index($0,"## [" v "]") == 1 {show=1; next}
    /^## \[/ && show {exit}
    show {print}
  ' CHANGELOG.md)"
fi
cat > "$NOTES" <<EOFNOTES
# Shar $VERSION

Local-first file and media sharing for iPhone/iPad, macOS, Android and any modern web browser on the same network.

## Downloads

- macOS: signed + notarized universal DMG and ZIP
- Android: signed APK and AAB
- iOS/iPadOS: source and Xcode project are included in this release; the automated local pipeline also compiles iOS and installs it on a connected development device when available

## Changes

$CHANGELOG_SECTION

## Links

- Project page: https://mojoworks.xyz/labs/shar/
- Source: https://github.com/$GH_REPO
EOFNOTES

if ! git show-ref --tags --verify --quiet "refs/tags/$TAG"; then
  log "Creating annotated Git tag $TAG"
  git tag -a "$TAG" -m "Shar $VERSION"
fi
log "Pushing tag $TAG"
retry 3 6 git push origin "refs/tags/$TAG"

if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
  log "GitHub Release $TAG already exists; updating assets"
else
  log "Creating draft GitHub Release $TAG"
  retry 3 6 gh release create "$TAG" --repo "$GH_REPO" --draft --title "Shar $VERSION" --notes-file "$NOTES"
fi
log "Uploading release assets"
for asset in "${assets[@]}"; do
  retry 4 8 gh release upload "$TAG" "$asset" --repo "$GH_REPO" --clobber
 done
log "Publishing GitHub Release $TAG"
retry 3 6 gh release edit "$TAG" --repo "$GH_REPO" --draft=false --title "Shar $VERSION" --notes-file "$NOTES"
RELEASE_URL="$(gh release view "$TAG" --repo "$GH_REPO" --json url --jq '.url')"
printf 'GitHub Release published: %s\n' "$RELEASE_URL"
