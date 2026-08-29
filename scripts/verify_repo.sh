#!/bin/zsh
set -e
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

fail(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ok(){ printf 'OK: %s\n' "$*"; }

[[ -f VERSION ]] || fail "VERSION missing"
VERSION_VALUE="$(tr -d '[:space:]' < VERSION)"
[[ "$VERSION_VALUE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid VERSION: $VERSION_VALUE"
BUILD_NUMBER="$(python3 - "$VERSION_VALUE" <<'PY'
import sys
a,b,c=map(int,sys.argv[1].split('.'))
print(a*10000+b*100+c)
PY
)"

for p in \
  README.md CHANGELOG.md .gitignore \
  assets/shar-logo.svg assets/shar-logo-1024.png \
  LocalWebShare.xcodeproj/project.pbxproj LocalWebShare/Info.plist \
  LocalWebShare/MediaSupport.swift LocalWebShare/GeneratedUIIcons.swift \
  LocalWebShare/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png \
  macos/LocalWebShareMacApp.swift macos/AppIcon.iconset/icon_512x512@2x.png \
  android/settings.gradle android/build.gradle android/app/build.gradle \
  android/app/src/main/AndroidManifest.xml \
  android/app/src/main/java/com/localwebshare/app/MainActivity.java \
  android/app/src/main/java/com/localwebshare/app/LocalHttpServer.java \
  android/app/src/main/java/com/localwebshare/app/PreviewActivity.java \
  android/app/src/main/java/com/localwebshare/app/GeneratedUIIcons.java \
  scripts/app_build.sh scripts/build_macos.sh scripts/build_android.sh scripts/build_all.sh scripts/sync_ui_icons.sh; do
  [[ -e "$p" ]] || fail "Missing $p"
done

grep -Fq "$VERSION_VALUE" README.md || fail "README does not mention $VERSION_VALUE"
grep -Fq "## [$VERSION_VALUE]" CHANGELOG.md || fail "CHANGELOG has no $VERSION_VALUE entry"
grep -Eq '^/archive/$|^archive/$' .gitignore || fail "archive/ is not ignored"

grep -Fq "MARKETING_VERSION = $VERSION_VALUE;" LocalWebShare.xcodeproj/project.pbxproj || fail "iOS marketing version mismatch"
grep -Fq "CURRENT_PROJECT_VERSION = $BUILD_NUMBER;" LocalWebShare.xcodeproj/project.pbxproj || fail "iOS build number mismatch"
grep -Eq "versionName[[:space:]]+'$VERSION_VALUE'" android/app/build.gradle || fail "Android versionName mismatch"
grep -Eq "versionCode[[:space:]]+$BUILD_NUMBER" android/app/build.gradle || fail "Android versionCode mismatch"
grep -Fq 'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;' LocalWebShare.xcodeproj/project.pbxproj || fail "iOS AppIcon asset is not configured"
grep -Fq '<string>SharLogo</string>' LocalWebShare/Info.plist || fail "iOS launch screen does not reference SharLogo"
grep -Fq 'NWPathMonitor' LocalWebShare/MediaSupport.swift || fail "iOS network status monitor missing"
grep -Fq 'LazyVGrid' LocalWebShare/ContentView.swift || fail "iOS grid media view missing"
grep -Fq 'settingsPanel' LocalWebShare/ContentView.swift || fail "iOS settings drawer missing"
grep -Fq 'currentFilter' LocalWebShare/LocalWebServer.swift || fail "Apple browser media filters missing"
grep -Fq 'settings-open' LocalWebShare/LocalWebServer.swift || fail "Apple browser settings drawer missing"
grep -Fq 'currentFilter' android/app/src/main/java/com/localwebshare/app/LocalHttpServer.java || fail "Android browser media filters missing"

for s in scripts/*.sh; do [[ -x "$s" ]] || fail "Script is not executable: $s"; done

if command -v plutil >/dev/null 2>&1; then plutil -lint LocalWebShare/Info.plist >/dev/null || fail "Invalid iOS Info.plist"; fi
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY'
from pathlib import Path
import json
for p in [Path('LocalWebShare/Assets.xcassets/Contents.json'), Path('LocalWebShare/Assets.xcassets/AppIcon.appiconset/Contents.json')]:
    json.loads(p.read_text())
PY
fi

ok "repository structure"
ok "version $VERSION_VALUE / build $BUILD_NUMBER"
ok "shared logo assets"
ok "iOS, macOS and Android client sources"
