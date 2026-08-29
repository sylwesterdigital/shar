#!/bin/zsh
set -e
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
PBX="$ROOT/LocalWebShare.xcodeproj/project.pbxproj"
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
python3 - "$PBX" "$NEW" "$BUILD_NUM" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1]); version=sys.argv[2]; build=sys.argv[3]
s=p.read_text()
s=re.sub(r'MARKETING_VERSION = [^;]+;', f'MARKETING_VERSION = {version};', s)
s=re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;', f'CURRENT_PROJECT_VERSION = {build};', s)
p.write_text(s)
PY

echo "$OLD -> $NEW (build $BUILD_NUM)"
