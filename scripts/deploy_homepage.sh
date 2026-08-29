#!/bin/zsh
set -e
set -o pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/release_profile.sh"
shar_load_release_profile
GH_REPO="${GH_REPO:-sylwesterdigital/shar}"
REMOTE_URL="${SHAR_REMOTE_URL:-https://mojoworks.xyz/labs/shar/}"
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="${RELEASE_TAG:-v$VERSION}"
BUILD_ROOT="$ROOT/build/homepage"
STAMP="$(date +%Y%m%d%H%M%S)"
BUILD_DIR="$BUILD_ROOT/shar-homepage-$STAMP"
log(){ printf '\n==> %s\n' "$*"; }
fail(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
retry(){ local n=1 max="$1" delay="$2"; shift 2; until "$@"; do local rc=$?; (( n >= max )) && return "$rc"; printf 'WARNING: retry %d/%d in %ss: %s\n' "$n" "$max" "$delay" "$*" >&2; sleep "$delay"; n=$((n+1)); done; }
for t in gh python3 rsync ssh curl gzip; do command -v "$t" >/dev/null 2>&1 || fail "Missing tool: $t"; done
[[ -f "$ROOT/homepage/index.html" ]] || fail "homepage/index.html missing"
mkdir -p "$BUILD_DIR"
cp "$ROOT/homepage/index.html" "$BUILD_DIR/index.html"
cp "$ROOT/assets/shar-logo.svg" "$BUILD_DIR/shar-logo.svg"

log "Resolving published GitHub release $TAG"
RELEASE_JSON="$BUILD_DIR/.release.json"
gh release view "$TAG" --repo "$GH_REPO" --json url,name,publishedAt,isDraft,assets > "$RELEASE_JSON"
python3 - "$BUILD_DIR" "$RELEASE_JSON" "$VERSION" "$TAG" "$GH_REPO" "$REMOTE_URL" <<'PY'
from pathlib import Path
import json, sys
root=Path(sys.argv[1]); data=json.loads(Path(sys.argv[2]).read_text()); version,tag,repo,remote=sys.argv[3:]
if data.get('isDraft'): raise SystemExit(f'{tag} is still a draft')
assets={a['name']: a.get('url','') for a in data.get('assets',[])}
needed={
 'mac_dmg':f'LocalWebShare-v{version}-macOS-universal2.dmg',
 'mac_zip':f'LocalWebShare-v{version}-macOS-universal2.zip',
 'android_apk':f'LocalWebShare-v{version}-android.apk',
 'android_aab':f'LocalWebShare-v{version}-android.aab',
}
missing=[name for name in needed.values() if name not in assets]
if missing: raise SystemExit('GitHub release missing assets: '+', '.join(missing))
release_url=data.get('url') or f'https://github.com/{repo}/releases/tag/{tag}'
published=(data.get('publishedAt') or '').replace('T',' ').replace('Z',' UTC') or 'unknown'
repl={
 '__VERSION__':version,'__TAG__':tag,'__RELEASE_URL__':release_url,'__PUBLISHED_AT__':published,
 '__MAC_DMG_URL__':assets[needed['mac_dmg']], '__MAC_ZIP_URL__':assets[needed['mac_zip']],
 '__ANDROID_APK_URL__':assets[needed['android_apk']], '__ANDROID_AAB_URL__':assets[needed['android_aab']],
}
p=root/'index.html'; text=p.read_text()
for k,v in repl.items(): text=text.replace(k,v)
if '__' in text and any(k in text for k in repl): raise SystemExit('Unresolved homepage placeholder')
p.write_text(text)
(root/'release.json').write_text(json.dumps({
 'product':'Shar','version':version,'tag':tag,'release_url':release_url,'published_at':data.get('publishedAt'),
 'deployment_url':remote,'downloads':{k:{'name':needed[k],'url':assets[needed[k]]} for k in needed}
},indent=2)+'\n')
PY
rm -f "$RELEASE_JSON"
grep -F "$TAG" "$BUILD_DIR/index.html" >/dev/null || fail "Homepage does not contain release tag $TAG"
find "$BUILD_DIR" -type f \( -name '*.html' -o -name '*.json' -o -name '*.svg' \) -print0 | while IFS= read -r -d '' f; do gzip -9 -kf "$f"; done

log "Deploying homepage to $SHAR_REMOTE_HOST:$SHAR_REMOTE_DIR"
retry 4 8 ssh -o BatchMode=yes -o ConnectTimeout=15 -p "$SHAR_REMOTE_PORT" "$SHAR_REMOTE_USER@$SHAR_REMOTE_HOST" "mkdir -p '$SHAR_REMOTE_DIR'"
flags=(-avz --human-readable --itemize-changes --chmod="$SHAR_REMOTE_CHMOD" --partial --partial-dir=.rsync-partial --delay-updates --delete-delay)
if rsync --help 2>&1 | grep -q -- '--chown'; then flags+=(--chown="$SHAR_REMOTE_OWNER"); fi
retry 4 10 rsync "${flags[@]}" -e "ssh -o BatchMode=yes -o ConnectTimeout=15 -p $SHAR_REMOTE_PORT" "$BUILD_DIR/" "$SHAR_REMOTE_USER@$SHAR_REMOTE_HOST:$SHAR_REMOTE_DIR/"

log "Verifying public homepage $REMOTE_URL"
TMP="$(mktemp /tmp/shar-homepage.XXXXXX)"
trap 'rm -f "$TMP"' EXIT
retry 4 8 curl --fail --silent --show-error --location "${REMOTE_URL%/}/?deploy=$STAMP" -o "$TMP"
grep -qi '<title[^>]*>Shar' "$TMP" || fail "Public page is reachable but title verification failed."
grep -F "$TAG" "$TMP" >/dev/null || fail "Public page does not contain $TAG."
printf 'Homepage deployed and verified: %s\n' "$REMOTE_URL"
