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
  scripts/app_build.sh scripts/build_macos.sh scripts/build_android.sh scripts/build_all.sh scripts/sync_ui_icons.sh \
  scripts/build_macos_release.sh scripts/build_android_release.sh scripts/build_ios_check.sh \
  scripts/release_and_deploy.sh scripts/publish_github_release.sh scripts/deploy_homepage.sh \
  scripts/release_profile.sh scripts/setup_android_release.sh scripts/check_android_release_credentials.sh \
  scripts/check_macos_release_credentials.sh scripts/check_ios_release_credentials.sh scripts/android_env.sh \
  homepage/index.html; do
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
grep -Fq '<key>CFBundleDisplayName</key>' LocalWebShare/Info.plist || fail "iOS display name key missing"
grep -A1 -F '<key>CFBundleDisplayName</key>' LocalWebShare/Info.plist | grep -Fq '<string>Shar</string>' || fail "iOS display name is not Shar"
grep -Fq 'NWPathMonitor' LocalWebShare/MediaSupport.swift || fail "iOS network status monitor missing"
grep -Fq 'LazyVGrid' LocalWebShare/ContentView.swift || fail "iOS grid media view missing"
grep -Fq 'settingsPanel' LocalWebShare/ContentView.swift || fail "iOS settings drawer missing"
grep -Fq 'showingFileImporter' LocalWebShare/ContentView.swift || fail "iOS + file importer missing"
grep -Fq 'allowsMultipleSelection: true' LocalWebShare/ContentView.swift || fail "iOS multi-file import missing"
grep -Fq 'PhotoVideoLibraryPicker' LocalWebShare/ContentView.swift || fail "iOS Photos/video picker missing"
grep -Fq 'configuration.selectionLimit = 0' LocalWebShare/ContentView.swift || fail "iOS Photos multi-select missing"
grep -Fq 'VideoCameraPicker' LocalWebShare/ContentView.swift || fail "iOS video camera picker missing"
grep -Fq 'UTType.movie.identifier' LocalWebShare/ContentView.swift || fail "iOS video import/capture type missing"
grep -Fq '<key>NSCameraUsageDescription</key>' LocalWebShare/Info.plist || fail "iOS camera permission text missing"
grep -Fq '<key>NSMicrophoneUsageDescription</key>' LocalWebShare/Info.plist || fail "iOS microphone permission text missing"
grep -Fq '<key>NSPhotoLibraryUsageDescription</key>' LocalWebShare/Info.plist || fail "iOS photo-library permission text missing"
grep -Fq '<key>UIBackgroundModes</key>' LocalWebShare/Info.plist || fail "iOS background modes key missing"
grep -A3 -F '<key>UIBackgroundModes</key>' LocalWebShare/Info.plist | grep -Fq '<string>audio</string>' || fail "iOS background audio mode missing"
grep -Fq 'AVAudioSession.sharedInstance()' LocalWebShare/MediaSupport.swift || fail "iOS background audio session missing"
grep -Fq 'setCategory(.playback' LocalWebShare/MediaSupport.swift || fail "iOS playback audio category missing"
python3 - <<'PYIOSGUARD'
from pathlib import Path
lines=Path('LocalWebShare/MediaSupport.swift').read_text().splitlines()
ios_depth=0
stack=[]
violations=[]
for lineno, raw in enumerate(lines, 1):
    stripped=raw.strip()
    if stripped.startswith('#if '):
        is_ios = stripped == '#if os(iOS)'
        stack.append(is_ios)
        if is_ios: ios_depth += 1
        continue
    if stripped == '#endif':
        if stack:
            was_ios=stack.pop()
            if was_ios: ios_depth -= 1
        continue
    if 'AVAudioSession' in raw and ios_depth <= 0:
        violations.append(lineno)
if violations:
    raise SystemExit('AVAudioSession references escape the iOS-only guard at lines: ' + ', '.join(map(str, violations)))
PYIOSGUARD
grep -Fq 'Shar · v\(appVersion)' LocalWebShare/ContentView.swift || fail "iOS visible Settings version missing"
! grep -A110 -F 'private var settingsPanel' LocalWebShare/ContentView.swift | grep -Fq '.ignoresSafeArea()' || fail "iOS Settings panel ignores safe area"
grep -Fq 'android:label="Shar"' android/app/src/main/AndroidManifest.xml || fail "Android display name is not Shar"
grep -Fq 'Text("Shar").font(.title2.bold())' macos/LocalWebShareMacApp.swift || fail "macOS header is not Shar"
grep -Fq '<title>Shar</title>' LocalWebShare/LocalWebServer.swift || fail "Apple browser page title is not Shar"
grep -Fq 'currentFilter' LocalWebShare/LocalWebServer.swift || fail "Apple browser media filters missing"
grep -Fq 'settings-open' LocalWebShare/LocalWebServer.swift || fail "Apple browser settings drawer missing"
grep -Fq 'currentFilter' android/app/src/main/java/com/localwebshare/app/LocalHttpServer.java || fail "Android browser media filters missing"
grep -Fq 'lws-preset-v2' LocalWebShare/LocalWebServer.swift || fail "Apple browser density presets missing"
grep -Fq 'id="thumbSize"' LocalWebShare/LocalWebServer.swift || fail "Apple browser thumbnail size control missing"
grep -Fq 'fallback-icon.missing' LocalWebShare/LocalWebServer.swift || fail "Apple browser icon fallback fix missing"
grep -Fq 'lws-preset-v2' android/app/src/main/java/com/localwebshare/app/LocalHttpServer.java || fail "Android browser density presets missing"

grep -Fq 'https://mojoworks.xyz/labs/shar/' README.md || fail "README does not document the Shar homepage"
grep -Fq '/var/www/mojoworks/labs/shar' README.md || fail "README does not document the Shar deployment directory"
grep -Fq '__MAC_DMG_URL__' homepage/index.html || fail "Homepage macOS release placeholder missing"
grep -Fq '__ANDROID_APK_URL__' homepage/index.html || fail "Homepage Android release placeholder missing"
grep -Fq 'sylwesterdigital/shar' scripts/publish_github_release.sh || fail "GitHub release repository mismatch"
grep -Fq '/var/www/mojoworks/labs/shar' scripts/release_profile.sh || fail "Shar remote deployment directory mismatch"

for s in scripts/*.sh; do [[ -x "$s" ]] || fail "Script is not executable: $s"; done

if command -v plutil >/dev/null 2>&1; then plutil -lint LocalWebShare/Info.plist >/dev/null || fail "Invalid iOS Info.plist"; fi
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY'
from pathlib import Path
import json, re
for p in [Path('LocalWebShare/Assets.xcassets/Contents.json'), Path('LocalWebShare/Assets.xcassets/AppIcon.appiconset/Contents.json')]:
    json.loads(p.read_text())
apple=Path('LocalWebShare/LocalWebServer.swift').read_text()
android=Path('android/app/src/main/java/com/localwebshare/app/LocalHttpServer.java').read_text()
def html(text):
    m=re.search(r'<!doctype html>.*?</html>', text, re.S|re.I)
    if not m: raise SystemExit('Embedded browser HTML missing')
    return m.group(0)
if html(apple) != html(android):
    raise SystemExit('Apple and Android embedded browser UIs differ')
PY
fi

ok "repository structure"
ok "version $VERSION_VALUE / build $BUILD_NUMBER"
ok "shared logo assets"
ok "iOS, macOS and Android client sources"
