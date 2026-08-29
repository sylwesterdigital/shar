#!/bin/zsh
set -e
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
PBX="$ROOT/LocalWebShare.xcodeproj/project.pbxproj"
ANDROID_GRADLE="$ROOT/android/app/build.gradle"
MODE="${1:-patch}"

[[ -f "$VERSION_FILE" ]] || { echo "VERSION not found" >&2; exit 1; }
[[ -f "$PBX" ]] || { echo "Xcode project not found" >&2; exit 1; }
OLD="$(tr -d '[:space:]' < "$VERSION_FILE")"

NEW="$(python3 - "$OLD" "$MODE" <<'PY'
import re, sys
old, mode=sys.argv[1], sys.argv[2]
if not re.fullmatch(r'\d+\.\d+\.\d+', old):
    raise SystemExit('VERSION must be MAJOR.MINOR.PATCH')
a,b,c=map(int,old.split('.'))
if mode=='major': a,b,c=a+1,0,0
elif mode=='minor': b,c=b+1,0
elif mode=='patch': c+=1
elif re.fullmatch(r'\d+\.\d+\.\d+', mode):
    a,b,c=map(int,mode.split('.'))
else: raise SystemExit('use major, minor, patch, or X.Y.Z')
print(f'{a}.{b}.{c}')
PY
)"

BUILD_NUM="$(python3 - "$NEW" <<'PY'
import sys
m,n,p=map(int,sys.argv[1].split('.'))
print(m*10000+n*100+p)
PY
)"

printf '%s\n' "$NEW" > "$VERSION_FILE"
python3 - "$PBX" "$ANDROID_GRADLE" "$NEW" "$BUILD_NUM" <<'PY'
from pathlib import Path
import re, sys
pbx=Path(sys.argv[1]); gradle=Path(sys.argv[2]); version=sys.argv[3]; build=sys.argv[4]
s=pbx.read_text()
s=re.sub(r'MARKETING_VERSION = [^;]+;', f'MARKETING_VERSION = {version};', s)
s=re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;', f'CURRENT_PROJECT_VERSION = {build};', s)
pbx.write_text(s)
if gradle.exists():
    g=gradle.read_text()
    g=re.sub(r'versionCode\s+\d+', f'versionCode {build}', g)
    g=re.sub(r"versionName\s+'[^']+'", f"versionName '{version}'", g)
    gradle.write_text(g)
PY

echo "$OLD -> $NEW (build $BUILD_NUM; iOS/macOS/Android)"
