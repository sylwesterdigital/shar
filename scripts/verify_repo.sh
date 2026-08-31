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
  LocalWebShare/MediaSupport.swift LocalWebShare/ThreeDPreview.swift LocalWebShare/GeneratedUIIcons.swift \
  LocalWebShare/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png \
  macos/LocalWebShareMacApp.swift macos/AppIcon.iconset/icon_512x512@2x.png \
  android/settings.gradle android/build.gradle android/app/build.gradle \
  android/app/src/main/AndroidManifest.xml \
  android/app/src/main/java/com/localwebshare/app/MainActivity.java \
  android/app/src/main/java/com/localwebshare/app/LocalHttpServer.java \
  android/app/src/main/java/com/localwebshare/app/PreviewActivity.java \
  android/app/src/main/java/com/localwebshare/app/RemoteShareActivity.java \
  android/app/src/main/java/com/localwebshare/app/GeneratedUIIcons.java \
  scripts/app_build.sh scripts/build_macos.sh scripts/build_android.sh scripts/build_all.sh scripts/sync_ui_icons.sh \
  scripts/build_macos_release.sh scripts/build_android_release.sh scripts/build_ios_check.sh \
  scripts/release_and_deploy.sh scripts/publish_github_release.sh scripts/deploy_homepage.sh \
  scripts/check_remote_share.sh scripts/deploy_remote_share.sh scripts/remote_bootstrap.sh scripts/test_remote_protocol.sh scripts/test_remote_crypto.sh \
  scripts/release_profile.sh scripts/setup_android_release.sh scripts/check_android_release_credentials.sh \
  scripts/check_macos_release_credentials.sh scripts/check_ios_release_credentials.sh scripts/android_env.sh \
  remote/server.js homepage/index.html homepage/receive.html homepage/support.html; do
  [[ -e "$p" ]] || fail "Missing $p"
done

grep -Fq "$VERSION_VALUE" README.md || fail "README does not mention $VERSION_VALUE"
grep -Fq "## [$VERSION_VALUE]" CHANGELOG.md || fail "CHANGELOG has no $VERSION_VALUE entry"
grep -Eq '^/archive/$|^archive/$' .gitignore || fail "archive/ is not ignored"

grep -Fq "MARKETING_VERSION = $VERSION_VALUE;" LocalWebShare.xcodeproj/project.pbxproj || fail "iOS marketing version mismatch"

python3 - <<'PYSWIFTASYNCGUARD'
from pathlib import Path
import re
violations=[]
for base in (Path('LocalWebShare'), Path('macos')):
    for path in base.rglob('*.swift'):
        text=path.read_text()
        for m in re.finditer(r'\?\?\s*await\b', text):
            line=text.count('\n', 0, m.start())+1
            violations.append(f"{path}:{line}")
if violations:
    raise SystemExit('Invalid async nil-coalescing (?? await) found: ' + ', '.join(violations))
PYSWIFTASYNCGUARD
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
grep -Fq '@AppStorage("showDeveloperInfo")' LocalWebShare/ContentView.swift || fail "iOS developer-info preference missing"
grep -Fq 'Show ⓘ updates button' LocalWebShare/ContentView.swift || fail "iOS developer-info Settings toggle missing"
grep -Fq 'DeveloperUpdatesView' LocalWebShare/ContentView.swift || fail "iOS developer updates panel missing"
grep -Fq 'GridCardIconButtonStyle' LocalWebShare/ContentView.swift || fail "iOS fixed-size grid action button style missing"
grep -Fq '.frame(width: 34, height: 34)' LocalWebShare/ContentView.swift || fail "iOS grid action controls are not fixed to a stable square size"
grep -Fq '@AppStorage("actionLabelMode") private var actionLabelModeRaw = ActionLabelMode.icons.rawValue' LocalWebShare/ContentView.swift || fail "iOS new-install Grid actions do not default to icons"
grep -Fq 'didMigrateGridIconsV223' LocalWebShare/ContentView.swift || fail "iOS existing compact-default installs are not migrated to Grid icons"
grep -Fq '.frame(width: 78)' LocalWebShare/ContentView.swift || fail "iOS main Grid/List segmented switch missing"
grep -Fq 'Label("Browse Files…", systemImage: "folder")' LocalWebShare/ContentView.swift || fail "iOS direct Browse Files action missing"
grep -Fq '.frame(width: 54, height: 54)' LocalWebShare/ContentView.swift || fail "iOS first-run rounded + action missing"
grep -Fq 'Image("SharLogo")' LocalWebShare/ContentView.swift || fail "iOS Developer updates identity header missing app logo"
grep -Fq 'let date: String' LocalWebShare/ContentView.swift || fail "iOS Developer updates release dates missing"
grep -Fq 'ThumbnailView(file: file, size: CGSize(width: 76, height: 76))' LocalWebShare/ContentView.swift || fail "iOS Secure Remote Share visual file confirmation missing"
grep -Fq 'PulsingProminentButtonStyle' LocalWebShare/ContentView.swift || fail "iOS highlighted current-action style missing"
grep -Fq 'showingFileImporter' LocalWebShare/ContentView.swift || fail "iOS + file importer missing"
grep -Fq 'allowsMultipleSelection: true' LocalWebShare/ContentView.swift || fail "iOS multi-file import missing"
grep -Fq 'PhotoVideoLibraryPicker' LocalWebShare/ContentView.swift || fail "iOS Photos/video picker missing"
grep -Fq 'configuration.selectionLimit = 0' LocalWebShare/ContentView.swift || fail "iOS Photos multi-select missing"
grep -Fq 'VideoCameraPicker' LocalWebShare/ContentView.swift || fail "iOS video camera picker missing"
grep -Fq 'UTType.movie.identifier' LocalWebShare/ContentView.swift || fail "iOS video import/capture type missing"
grep -Fq '<key>NSAppTransportSecurity</key>' LocalWebShare/Info.plist || fail "iOS ATS configuration missing"
grep -A5 -F '<key>NSAppTransportSecurity</key>' LocalWebShare/Info.plist | grep -Fq '<key>NSAllowsLocalNetworking</key>' || fail "iOS local-only ATS exception missing"
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
grep -Fq 'Installation is authoritative for release validation' scripts/app_build.sh || fail "iOS installed-app launch must be best-effort for distribution releases"
grep -Fq 'No space left on device' scripts/app_build.sh || fail "iOS device-storage install detection missing"
grep -Fq 'IOS_STATUS == 21' scripts/build_all.sh || fail "Distribution release does not tolerate an attached iOS device that is out of storage"
! grep -Fq 'exit 3' scripts/app_build.sh || fail "iOS locked-device launch regression still aborts release after successful install"
grep -Fq 'Shar · v\(appVersion)' LocalWebShare/ContentView.swift || fail "iOS visible Settings version missing"
grep -Fq 'Text("Version")' LocalWebShare/ContentView.swift || fail "iOS explicit Version row missing"
grep -Fq 'Text("Build")' LocalWebShare/ContentView.swift || fail "iOS explicit Build row missing"
grep -Fq 'Support Shar' LocalWebShare/ContentView.swift || fail "iOS Support Shar action missing"
grep -Fq 'SFSafariViewController' LocalWebShare/ContentView.swift || fail "iOS in-app support checkout wrapper missing"
grep -Fq 'SharProductInfo.builderName' LocalWebShare/ContentView.swift || fail "iOS builder About identity missing"
grep -Fq 'builderName = "WORKWORK.FUN LTD"' LocalWebShare/MediaSupport.swift || fail "WORKWORK.FUN LTD product identity missing"
grep -Fq '© 2026 Sylwester Mielniczuk, CEO of WORKWORK.FUN LTD' LocalWebShare/MediaSupport.swift || fail "Apple copyright/CEO identity missing"
grep -Fq 'case threeD' LocalWebShare/FileStore.swift || fail "3D media kind missing"
grep -Fq 'case threeD' LocalWebShare/MediaSupport.swift || fail "3D media filter missing"
grep -Fq 'case "3D"' LocalWebShare/MediaSupport.swift >/dev/null 2>&1 || true
grep -Fq '"glb", "gltf"' LocalWebShare/FileStore.swift || fail "GLB/glTF file classification missing"
grep -Fq 'SharGLTFLoader' LocalWebShare/ThreeDPreview.swift || fail "native GLB/glTF loader missing"
grep -Fq 'MDLAsset.canImportFileExtension' LocalWebShare/ThreeDPreview.swift || fail "native Model I/O 3D fallback missing"
grep -Fq 'import SceneKit.ModelIO' LocalWebShare/ThreeDPreview.swift || fail "SceneKit/Model I/O bridge import missing"
! grep -Fq 'ContentUnavailableView' LocalWebShare/ThreeDPreview.swift || fail "3D preview uses macOS 14-only ContentUnavailableView despite macOS 13 target"
grep -Fq 'let imageData: Data?' LocalWebShare/ThreeDPreview.swift || fail "3D texture loader still risks shadowing data(forURI:)"
grep -Fq 'ThreeDLightPreset' LocalWebShare/ThreeDPreview.swift || fail "native 3D lighting presets missing"
grep -Fq 'floorEnabled' LocalWebShare/ThreeDPreview.swift || fail "native 3D floor toggle missing"
grep -Fq 'ThreeDBackgroundPreset' LocalWebShare/ThreeDPreview.swift || fail "native 3D background presets missing"
grep -Fq 'Fit model' LocalWebShare/ThreeDPreview.swift || fail "native 3D camera-fit control missing"
grep -Fq 'ThreeDThumbnailCache' LocalWebShare/ThreeDPreview.swift || fail "native 3D thumbnail cache missing"
grep -Fq 'camera.viewfinder' LocalWebShare/ThreeDPreview.swift || fail "native 3D thumbnail recapture action missing"
grep -Fq 'SharThreeDThumbnailChanged' LocalWebShare/FileStore.swift || fail "native 3D thumbnail refresh notification missing"
grep -Fq 'generateDefault(for: destination)' LocalWebShare/FileStore.swift || fail "imported/dropped 3D thumbnail warmup missing"
grep -Fq 'ThreeDThumbnailCache.cachedImage' LocalWebShare/ThumbnailView.swift || fail "iOS library does not consume cached 3D thumbnails"
grep -Fq 'ThreeDPreviewView(file: file)' LocalWebShare/MediaPlayerView.swift || fail "iOS native 3D preview missing"
grep -Fq 'ensureLoaded(file, autoplayIfNew: true)' LocalWebShare/MediaPlayerView.swift || fail "iOS audio preview does not preserve shared playback state"
grep -Fq '@Published private(set) var currentTime' LocalWebShare/MediaSupport.swift || fail "shared audio current-time state missing"
grep -Fq '@Published private(set) var duration' LocalWebShare/MediaSupport.swift || fail "shared audio duration state missing"
grep -Fq 'dollarsign.circle.fill' LocalWebShare/ContentView.swift || fail "iOS top Support icon missing"
! grep -A110 -F 'private var settingsPanel' LocalWebShare/ContentView.swift | grep -Fq '.ignoresSafeArea()' || fail "iOS Settings panel ignores safe area"
grep -Fq 'android:label="Shar"' android/app/src/main/AndroidManifest.xml || fail "Android display name is not Shar"
grep -Fq 'About Shar' android/app/src/main/java/com/localwebshare/app/MainActivity.java || fail "Android About dialog missing"
grep -Fq 'Support Shar' android/app/src/main/java/com/localwebshare/app/MainActivity.java || fail "Android Support Shar action missing"
grep -Fq 'BUILDER_NAME = "WORKWORK.FUN LTD"' android/app/src/main/java/com/localwebshare/app/MainActivity.java || fail "Android company identity missing"
grep -Fq 'COPYRIGHT = "© 2026 Sylwester Mielniczuk, CEO of WORKWORK.FUN LTD"' android/app/src/main/java/com/localwebshare/app/MainActivity.java || fail "Android copyright/CEO identity missing"
grep -Fq 'Text("Shar").font(.title2.bold())' macos/LocalWebShareMacApp.swift || fail "macOS header is not Shar"
grep -Fq 'Show ⓘ developer updates' macos/LocalWebShareMacApp.swift || fail "macOS developer-info preference missing"
grep -Fq 'show_developer_info' android/app/src/main/java/com/localwebshare/app/MainActivity.java || fail "Android developer-info preference missing"
grep -Fq 'Developer updates' android/app/src/main/java/com/localwebshare/app/MainActivity.java || fail "Android developer updates panel missing"
grep -Fq 'appVersionLabel()' android/app/src/main/java/com/localwebshare/app/MainActivity.java || fail "Android package-metadata version helper missing"
! grep -Eq 'BuildConfig\.VERSION_(NAME|CODE)' android/app/src/main/java/com/localwebshare/app/MainActivity.java || fail "Android UI must not depend on generated BuildConfig version constants"
grep -Fq '<title>Shar</title>' LocalWebShare/LocalWebServer.swift || fail "Apple browser page title is not Shar"
grep -Fq 'currentFilter' LocalWebShare/LocalWebServer.swift || fail "Apple browser media filters missing"
grep -Fq 'settings-open' LocalWebShare/LocalWebServer.swift || fail "Apple browser settings drawer missing"
grep -Fq 'id="infoButton"' LocalWebShare/LocalWebServer.swift || fail "Apple browser developer-info button missing"
grep -Fq 'lws-show-developer-info' LocalWebShare/LocalWebServer.swift || fail "Apple browser developer-info preference missing"
grep -Fq 'Developer updates' LocalWebShare/LocalWebServer.swift || fail "Apple browser developer updates panel missing"
grep -Fq 'currentFilter' android/app/src/main/java/com/localwebshare/app/LocalHttpServer.java || fail "Android browser media filters missing"
grep -Fq "['threeD','3D']" LocalWebShare/LocalWebServer.swift || fail "Apple browser 3D filter missing"
grep -Fq "['threeD','3D']" android/app/src/main/java/com/localwebshare/app/LocalHttpServer.java || fail "Android browser 3D filter missing"
grep -Fq 'case ("GET", "/3d-viewer.js")' LocalWebShare/LocalWebServer.swift || fail "Apple local WebGL 3D viewer endpoint missing"
grep -Fq 'THREE_D_VIEWER_JS' android/app/src/main/java/com/localwebshare/app/LocalHttpServer.java || fail "Android local WebGL 3D viewer payload missing"
grep -Fq 'function threeDPreview' LocalWebShare/LocalWebServer.swift || fail "browser 3D preview renderer missing"
grep -Fq "canvas.getContext('webgl2'" LocalWebShare/LocalWebServer.swift || fail "browser 3D WebGL 2 renderer missing"
grep -Fq "light.textContent='☀ Studio'" LocalWebShare/LocalWebServer.swift || fail "browser 3D lighting control missing"
grep -Fq "floor.textContent='▱ Floor'" LocalWebShare/LocalWebServer.swift || fail "browser 3D floor control missing"
grep -Fq "bg.textContent='◐ Dark'" LocalWebShare/LocalWebServer.swift || fail "browser 3D background control missing"
grep -Fq "inlineIcons={previous:" LocalWebShare/LocalWebServer.swift || fail "inline Previous/Next SVG icons missing"
grep -Fq "if(inlineIcons[name])" LocalWebShare/LocalWebServer.swift || fail "browser navigation still depends on external Previous/Next SVG files"
! grep -Fq 'jsdelivr' LocalWebShare/LocalWebServer.swift android/app/src/main/java/com/localwebshare/app/LocalHttpServer.java || fail "browser 3D viewer must not load a third-party CDN"
grep -Fq 'case "glb": case "gltf"' android/app/src/main/java/com/localwebshare/app/MediaTypes.java || fail "Android 3D classification missing"
grep -Fq 'lws-preset-v2' LocalWebShare/LocalWebServer.swift || fail "Apple browser density presets missing"
grep -Fq 'id="thumbSize"' LocalWebShare/LocalWebServer.swift || fail "Apple browser thumbnail size control missing"
grep -Fq 'fallback-icon.missing' LocalWebShare/LocalWebServer.swift || fail "Apple browser icon fallback fix missing"
grep -Fq 'lws-preset-v2' android/app/src/main/java/com/localwebshare/app/LocalHttpServer.java || fail "Android browser density presets missing"
grep -Fq "const REMOTE_API='https://mojoworks.xyz/api/shar/remote/v1'" LocalWebShare/LocalWebServer.swift || fail "Apple browser remote-share API missing"
grep -Fq 'RTCPeerConnection' LocalWebShare/LocalWebServer.swift || fail "Apple browser WebRTC sender missing"
grep -Fq 'remoteStart([serverSource(f)])' LocalWebShare/LocalWebServer.swift || fail "Browser file-card remote share action missing"
grep -Fq 'webkitdirectory' LocalWebShare/LocalWebServer.swift || fail "Browser folder remote-share picker missing"
grep -Fq 'NativeRemoteShareCoordinator' LocalWebShare/ContentView.swift || fail "iOS native Remote Share coordinator missing"
grep -Fq 'NativeRemoteShareQR' LocalWebShare/ContentView.swift || fail "iOS native Remote Share QR generator missing"
grep -Fq 'NativeSystemShareSheet' LocalWebShare/ContentView.swift || fail "iOS native activity share sheet missing"
grep -Fq 'UIActivityViewController(activityItems: activityItems' LocalWebShare/ContentView.swift || fail "iOS Remote Share does not present UIActivityViewController"
! grep -A180 -F 'private struct RemoteShareSheet' LocalWebShare/ContentView.swift | grep -Fq 'ShareLink(item: url' || fail "iOS Remote Share regressed to the non-presenting SwiftUI ShareLink"
grep -Fq "const API='https://mojoworks.xyz/api/shar/remote/v1'" LocalWebShare/ContentView.swift || fail "iOS native Remote Share public API missing"
grep -Fq "pc=new RTCPeerConnection" LocalWebShare/ContentView.swift || fail "iOS internal WebRTC engine missing"
grep -Fq "type:'chunk'" LocalWebShare/ContentView.swift || fail "iOS native file-to-WebRTC bridge missing"
! grep -Fq 'RemoteShareWebView' LocalWebShare/ContentView.swift || fail "iOS Remote Share must not open the local browser UI"
python3 - <<'PYREMOTEIOS'
from pathlib import Path
import re
s=Path('LocalWebShare/ContentView.swift').read_text()
m=re.search(r'private func openRemoteShare\(_ file: SharedFile\) \{(.*?)\n    \}', s, re.S)
if not m: raise SystemExit('iOS openRemoteShare function missing')
if 'webServer.start' in m.group(1): raise SystemExit('iOS Remote Share still starts the LAN HTTP server')
PYREMOTEIOS
grep -Fq 'openRemoteShare' macos/LocalWebShareMacApp.swift || fail "macOS remote share action missing"
grep -Fq 'MacRemoteShareSheet' macos/LocalWebShareMacApp.swift || fail "macOS native Remote Share sheet missing"
grep -Fq '@AppStorage("macFileViewMode")' macos/LocalWebShareMacApp.swift || fail "macOS Grid/List preference missing"
grep -Fq '@AppStorage("macMediaFilter")' macos/LocalWebShareMacApp.swift || fail "macOS media-filter preference missing"
grep -Fq 'ForEach(MediaFilter.allCases)' macos/LocalWebShareMacApp.swift || fail "macOS media filter strip missing"
grep -Fq 'LazyVGrid' macos/LocalWebShareMacApp.swift || fail "macOS grid library missing"
grep -Fq 'Label("Config", systemImage: "gearshape.fill")' macos/LocalWebShareMacApp.swift || fail "macOS cog Config drawer missing"
grep -Fq 'MacLibraryListRow' macos/LocalWebShareMacApp.swift || fail "macOS list library missing"
grep -Fq 'Support Shar' macos/LocalWebShareMacApp.swift || fail "macOS Support Shar action missing"
grep -Fq 'dollarsign.circle.fill' macos/LocalWebShareMacApp.swift || fail "macOS top Support icon missing"
grep -Fq 'CommandGroup(replacing: .appInfo)' macos/LocalWebShareMacApp.swift || fail "macOS application-menu About override missing"
grep -Fq 'MacAboutPanelController.shared.show()' macos/LocalWebShareMacApp.swift || fail "macOS About Shar menu does not open the native About panel"
grep -Fq 'contentRect: NSRect(x: 0, y: 0, width: 560, height: 420)' macos/LocalWebShareMacApp.swift || fail "macOS About panel fixed readable size missing"
grep -Fq 'panel.contentMinSize = NSSize(width: 560, height: 420)' macos/LocalWebShareMacApp.swift || fail "macOS About panel minimum size guard missing"
grep -Fq '.frame(width: 560, height: 420, alignment: .topLeading)' macos/LocalWebShareMacApp.swift || fail "macOS About SwiftUI content can collapse below readable size"
python3 - <<'PYMACTOOLBAR'
from pathlib import Path
s=Path('macos/LocalWebShareMacApp.swift').read_text()
a=s.find('    private var topBar: some View {')
b=s.find('    private var sharingStrip:', a)
if a < 0 or b < 0: raise SystemExit('macOS topBar block missing')
bar=s[a:b]
if 'Image(systemName: "info.circle.fill")' not in bar or 'showingDeveloperUpdates = true' not in bar:
    raise SystemExit('macOS info toolbar button must open Developer updates like iOS')
if 'showingAbout' in bar or '.help("About Shar")' in bar:
    raise SystemExit('macOS toolbar info button still routes to About instead of Developer updates')
PYMACTOOLBAR
grep -Fq '<key>CFBundleName</key><string>Shar</string>' scripts/build_macos.sh || fail "macOS development bundle name is not Shar"
grep -Fq 'APP="$BUILD_ROOT/Shar.app"' scripts/build_macos.sh || fail "macOS development app bundle is not named Shar.app"
grep -Fq 'INSTALL_APP="$INSTALL_DIR/Shar.app"' scripts/build_macos.sh || fail "macOS installed development app is not named Shar.app"
grep -Fq 'LEGACY_INSTALL_APP="$INSTALL_DIR/LocalWebShare.app"' scripts/build_macos.sh || fail "macOS legacy LocalWebShare.app cleanup target missing"
grep -Fq '<key>CFBundleName</key><string>Shar</string>' scripts/build_macos_release.sh || fail "macOS release bundle name is not Shar"
! grep -Fq '<key>CFBundleName</key><string>LocalWebShare</string>' scripts/build_macos.sh scripts/build_macos_release.sh || fail "macOS visible bundle name regressed to LocalWebShare"
grep -Fq '@StateObject private var audioPlayback = SharedAudioPlaybackController()' macos/LocalWebShareMacApp.swift || fail "macOS shared audio controller missing"
grep -Fq 'MacInlineAudioButton(file: file, playback: audioPlayback)' macos/LocalWebShareMacApp.swift || fail "macOS library cards do not use shared audio playback"
grep -Fq 'ThreeDPreviewView(file: file)' macos/LocalWebShareMacApp.swift || fail "macOS native 3D preview missing"
grep -Fq 'GeometryReader { proxy in' macos/LocalWebShareMacApp.swift || fail "macOS image fit-to-preview geometry missing"
grep -Fq 'proxy.size.width - 24' macos/LocalWebShareMacApp.swift || fail "macOS image preview does not fit the viewport on open"
grep -Fq 'audioPlayback.ensureLoaded(file, autoplayIfNew: true)' macos/LocalWebShareMacApp.swift || fail "macOS audio preview does not preserve shared playback state"
! grep -A20 -F 'private struct MacInlineAudioButton' macos/LocalWebShareMacApp.swift | grep -Fq '@State private var player' || fail "macOS inline audio still owns disposable per-card players"
! grep -A20 -F 'private struct MacInlineAudioButton' macos/LocalWebShareMacApp.swift | grep -Fq '.onDisappear' || fail "macOS inline audio still stops on Grid/List disappearance"
grep -Fq 'SharProductInfo.builderName' macos/LocalWebShareMacApp.swift || fail "macOS builder About identity missing"
grep -Fq 'MacNativeRemoteShareCoordinator' macos/LocalWebShareMacApp.swift || fail "macOS native Remote Share coordinator missing"
grep -Fq 'MacNativeRemoteShareQR' macos/LocalWebShareMacApp.swift || fail "macOS native Remote Share QR generator missing"
grep -Fq 'MacThumbnail(file: file, size: 54)' macos/LocalWebShareMacApp.swift || fail "macOS Secure Remote Share visual file confirmation missing"
grep -Fq '2026-08-31", "3D thumbnails + compact iOS workflow' macos/LocalWebShareMacApp.swift || fail "macOS dated v2.2.3 developer update missing"
grep -Fq '2026-08-31", "macOS 3D thumbnail build hotfix' macos/LocalWebShareMacApp.swift || fail "macOS dated v2.2.32 developer update missing"
grep -Fq '.frame(width: 700, height: 670)' macos/LocalWebShareMacApp.swift || fail "macOS Remote Share compact sheet dimensions missing"
grep -Fq 'Text(remote.formattedPIN)' macos/LocalWebShareMacApp.swift || fail "macOS Remote Share PIN display missing"
grep -Fq '.font(.system(size: 34, weight: .bold, design: .monospaced))' macos/LocalWebShareMacApp.swift || fail "macOS Remote Share large PIN styling missing"
grep -Fq 'private var actionBar: some View' macos/LocalWebShareMacApp.swift || fail "macOS Remote Share persistent bottom action bar missing"
grep -Fq 'remote.didCopy ? "Copied" : "Copy link"' macos/LocalWebShareMacApp.swift || fail "macOS Remote Share Copy link action missing"
grep -Fq 'Label("Share link", systemImage: "square.and.arrow.up")' macos/LocalWebShareMacApp.swift || fail "macOS Remote Share Share link action missing"
grep -Fq 'Label("Cancel share", systemImage: "xmark.circle")' macos/LocalWebShareMacApp.swift || fail "macOS Remote Share Cancel share action missing"
grep -Fq 'AES-256-GCM · SHA-256 · approval · 1 receiver · 30 min' macos/LocalWebShareMacApp.swift || fail "macOS Remote Share concise security summary missing"
grep -Fq 'NSSharingServicePicker(items: [url])' macos/LocalWebShareMacApp.swift || fail "macOS native link sharing picker missing"
grep -Fq "pc=new RTCPeerConnection" macos/LocalWebShareMacApp.swift || fail "macOS internal WebRTC engine missing"
grep -Fq "type:'chunk'" macos/LocalWebShareMacApp.swift || fail "macOS native file-to-WebRTC bridge missing"
grep -Fq 'approvalRequired:true' macos/LocalWebShareMacApp.swift || fail "macOS sender approval requirement missing"
grep -Fq "name:'AES-GCM'" macos/LocalWebShareMacApp.swift || fail "macOS AES-256-GCM Remote Share encryption missing"
python3 - <<'PYREMOTEMAC'
from pathlib import Path
import re
s=Path('macos/LocalWebShareMacApp.swift').read_text()
m=re.search(r'private func openRemoteShare\(_ file: SharedFile\) \{(.*?)\n    \}', s, re.S)
if not m: raise SystemExit('macOS openRemoteShare function missing')
body=m.group(1)
if 'webServer.start' in body: raise SystemExit('macOS Remote Share still starts the LAN HTTP server')
if '127.0.0.1:8080' in body or 'NSWorkspace.shared.open' in body: raise SystemExit('macOS Remote Share still opens localhost/browser')
PYREMOTEMAC
grep -Fq 'RemoteShareActivity' android/app/src/main/java/com/localwebshare/app/MainActivity.java || fail "Android remote share action missing"
grep -Fq '<activity android:name=".RemoteShareActivity"' android/app/src/main/AndroidManifest.xml || fail "Android RemoteShareActivity is not registered"
grep -Fq 'const TURN_SECRET = process.env.SHAR_TURN_SECRET' remote/server.js || fail "Remote server TURN secret must come from environment"
grep -Fq 'crypto.createHmac' remote/server.js || fail "Short-lived TURN credential generation missing"
grep -Fq 'stun:${TURN_HOST}:${TURN_PORT}' remote/server.js || fail "Shar-hosted STUN configuration missing"
! grep -RFiq 'stun.l.google.com' LocalWebShare remote homepage android/app/src/main/java || fail "Runtime Remote Share must not use Google STUN"
grep -Fq 'MAX_SIGNALS' remote/server.js || fail "Remote signaling bounds missing"
grep -Fq 'MAX_ACTIVE_SESSIONS' remote/server.js || fail "Remote active-session cap missing"
grep -Fq 'MAX_CREATES_PER_HOUR' remote/server.js || fail "Remote share-creation rate limit missing"
grep -Fq 'Receive with Shar' homepage/receive.html || fail "Remote receiver page missing"
grep -Fq 'showDirectoryPicker' homepage/receive.html || fail "Receiver direct-to-directory support missing"
grep -Fq 'RTCPeerConnection' homepage/receive.html || fail "Receiver WebRTC implementation missing"
grep -Fq "t:'receiver-complete'" homepage/receive.html || fail "Receiver completion acknowledgement missing"
grep -Fq 'transferTerminal' homepage/receive.html || fail "Receiver terminal-success guard missing"
grep -Fq "Transfer complete ✓" homepage/receive.html || fail "Receiver polished completion state missing"
grep -Fq "m.t==='receiver-complete'" LocalWebShare/ContentView.swift || fail "iOS sender receiver-complete handshake missing"
grep -Fq 'COMPLETION_GRACE_MS' remote/server.js || fail "Remote completion grace period missing"
grep -Fq 'Receiver byte-count confirmation does not match' remote/server.js || fail "Remote completion byte-count server validation missing"
grep -Fq "name:'AES-GCM'" LocalWebShare/ContentView.swift || fail "iOS AES-256-GCM Remote Share encryption missing"
grep -Fq "#share=" LocalWebShare/ContentView.swift || fail "iOS secure receiver URL fragment missing"
grep -Fq 'pinVerifier' remote/server.js || fail "Remote PIN verifier support missing"
grep -Fq 'PIN_MAX_FAILURES' remote/server.js || fail "Remote PIN brute-force lockout missing"
grep -Fq "parts[2]==='approve'" remote/server.js || fail "Sender receiver-approval endpoint missing"
grep -Fq "parts[2]==='approval'" remote/server.js || fail "Receiver approval polling endpoint missing"
grep -Fq 'approvalRequired:true' LocalWebShare/ContentView.swift || fail "Native iOS sender approval requirement missing"
grep -Fq 'pinIterations:PIN_ITERATIONS' LocalWebShare/ContentView.swift || fail "Native iOS PBKDF2 PIN proof missing"
grep -Fq 'privateMetadata:true' LocalWebShare/ContentView.swift || fail "Native iOS metadata privacy mode missing"
grep -Fq 'SHA-256 verification failed' homepage/receive.html || fail "Receiver SHA-256 verification missing"
grep -Fq 'Unencrypted WebRTC payload rejected' homepage/receive.html || fail "Receiver plaintext data-channel rejection missing"
grep -Fq 'location.hash' homepage/receive.html || fail "Receiver encryption capability is not read from URL fragment"
grep -Fq 'The 256-bit content key is stored only in the URL fragment' homepage/receive.html || fail "Receiver E2EE security disclosure missing"
grep -Fq 'access_log off;' scripts/remote_bootstrap.sh || fail "Remote API access-log suppression missing"
grep -Fq 'denied-peer-ip=127.0.0.0-127.255.255.255' scripts/remote_bootstrap.sh || fail "TURN loopback-peer blocking missing"
grep -Fq 'denied-peer-ip=169.254.0.0-169.254.255.255' scripts/remote_bootstrap.sh || fail "TURN metadata/link-local blocking missing"
grep -Fq 'user-quota=8' scripts/remote_bootstrap.sh || fail "TURN per-user quota missing"
grep -Fq 'shar-coturn.service' scripts/remote_bootstrap.sh || fail "Dedicated TURN bootstrap missing"
grep -Fq 'nginx -t' scripts/remote_bootstrap.sh || fail "Remote nginx safety validation missing"
grep -Fq 'previous nginx configuration was restored automatically' scripts/remote_bootstrap.sh || fail "Remote nginx rollback missing"
grep -Fq 'SHAR_NGINX_HOST' scripts/remote_bootstrap.sh || fail "Remote nginx exact-host selection missing"
grep -Fq 'exact=(host in names(block) and is_tls(block))' scripts/remote_bootstrap.sh || fail "Remote nginx exact server_name token check missing"
grep -Fq 'Removed stale Shar include from' scripts/remote_bootstrap.sh || fail "Remote nginx stale-vhost cleanup missing"
grep -Fq "nginx -T >/tmp/shar-nginx-effective.txt" scripts/remote_bootstrap.sh || fail "Remote effective-nginx discovery missing"
grep -Fq 'Verifying public HTTPS routing (authoritative)' scripts/remote_bootstrap.sh || fail "Remote authoritative public-route health check missing"
grep -Fq 'Waiting for direct Shar signaling upstream' scripts/remote_bootstrap.sh || fail "Remote signaling readiness wait missing"
grep -Fq 'systemctl status shar-remote.service --no-pager -l' scripts/remote_bootstrap.sh || fail "Remote systemd startup diagnostics missing"
grep -Fq 'journalctl -u shar-remote.service' scripts/remote_bootstrap.sh || fail "Remote journal diagnostics missing"
grep -Fq 'systemctl stop shar-remote.path' scripts/remote_bootstrap.sh || fail "Remote path-watcher race guard missing"
grep -Fq 'Waiting for updated Shar signaling service' scripts/deploy_remote_share.sh || fail "Remote fast-update readiness wait missing"
grep -Fq 'cache-busting retries' README.md || fail "Remote public-route verification documentation missing"
grep -Fq 'public API is missing/stale' scripts/deploy_remote_share.sh || fail "Remote public-route repair path missing"
grep -Fq "version:'$VERSION_VALUE'" remote/server.js || fail "Remote signaling server version mismatch"
grep -Fq './scripts/deploy_remote_share.sh' scripts/release_and_deploy.sh || fail "Release pipeline does not deploy remote sharing"
grep -Fq './scripts/test_remote_protocol.sh' scripts/release_and_deploy.sh || fail "Release pipeline does not smoke-test remote signaling"
grep -Fq './scripts/test_remote_crypto.sh' scripts/release_and_deploy.sh || fail "Release pipeline does not test Remote Share crypto primitives"
grep -Fq 'Retrying deployment for current v' scripts/build-watch.sh || fail "Watcher same-version deployment retry support missing"

grep -Fq 'https://mojoworks.xyz/labs/shar/' README.md || fail "README does not document the Shar homepage"
grep -Fq '/var/www/mojoworks/labs/shar' README.md || fail "README does not document the Shar deployment directory"
grep -Fq '__MAC_DMG_URL__' homepage/index.html || fail "Homepage macOS release placeholder missing"
grep -Fq '__ANDROID_APK_URL__' homepage/index.html || fail "Homepage Android release placeholder missing"
grep -Fq 'receive.html' homepage/index.html || fail "Homepage remote receiver link missing"
grep -Fq 'support.html' homepage/index.html || fail "Homepage support link missing"
grep -Fq '__STRIPE_SUPPORT_HREF__' homepage/index.html || fail "Homepage Stripe support href placeholder missing"
grep -Fq '__STRIPE_BUY_BUTTON_ID__' homepage/index.html || fail "Homepage Stripe Buy Button ID placeholder missing"
grep -Fq '__STRIPE_PUBLISHABLE_KEY__' homepage/index.html || fail "Homepage Stripe publishable key placeholder missing"
grep -Fq '<stripe-buy-button' homepage/index.html || fail "Homepage embedded Stripe Buy Button missing"
grep -Fq 'WORKWORK.FUN LTD' homepage/index.html || fail "Homepage company identity missing"
grep -Fq '© 2026 Sylwester Mielniczuk, CEO of WORKWORK.FUN LTD' homepage/index.html || fail "Homepage copyright/CEO identity missing"
grep -Fq 'Support Shar' homepage/support.html || fail "Shar support page missing"
grep -Fq '__STRIPE_SUPPORT_HREF__' homepage/support.html || fail "Stripe support href placeholder missing"
grep -Fq '__STRIPE_BUY_BUTTON_ID__' homepage/support.html || fail "Stripe Buy Button ID placeholder missing"
grep -Fq '__STRIPE_PUBLISHABLE_KEY__' homepage/support.html || fail "Stripe publishable key placeholder missing"
grep -Fq 'https://js.stripe.com/v3/buy-button.js' homepage/support.html || fail "Stripe Buy Button loader missing"
grep -Fq 'SHAR_STRIPE_SUPPORT_URL' scripts/release_profile.sh || fail "Private Stripe support profile field missing"
grep -Fq 'SHAR_STRIPE_BUY_BUTTON_ID' scripts/release_profile.sh || fail "Stripe Buy Button profile field missing"
grep -Fq 'SHAR_STRIPE_PUBLISHABLE_KEY' scripts/release_profile.sh || fail "Stripe publishable-key profile field missing"
grep -Fq 'SHAR_STRIPE_SUPPORT_URL' scripts/deploy_homepage.sh || fail "Stripe support homepage renderer missing"
grep -Fq 'SHAR_STRIPE_BUY_BUTTON_ID' scripts/deploy_homepage.sh || fail "Stripe Buy Button homepage renderer missing"
grep -Fq 'SHAR_STRIPE_PUBLISHABLE_KEY' scripts/deploy_homepage.sh || fail "Stripe publishable-key homepage renderer missing"
grep -Fq '"$BUILD_DIR/index.html" "$BUILD_DIR/support.html"' scripts/deploy_homepage.sh || fail "Stripe renderer must update both homepage and support page"
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
Path('/tmp/shar-browser-verify.js').write_text(re.search(r'<script>(.*?)</script>', html(apple), re.S).group(1))
three=re.search(r'private static let threeDViewerJavaScript = #"""\n(.*?)"""#', apple, re.S)
if not three: raise SystemExit('Apple local 3D viewer JavaScript missing')
Path('/tmp/shar-3d-viewer-verify.js').write_text(three.group(1))
receiver=Path('homepage/receive.html').read_text()
Path('/tmp/shar-receiver-verify.js').write_text(re.search(r'<script>(.*?)</script>', receiver, re.S).group(1))
content=Path('LocalWebShare/ContentView.swift').read_text()
engine=re.search(r'private var engineHTML: String \{.*?return \"\"\"(.*?)\"\"\"', content, re.S)
if not engine: raise SystemExit('Native iOS Remote Share engine HTML missing')
engine_script=re.search(r'<script>(.*?)</script>', engine.group(1), re.S)
if not engine_script: raise SystemExit('Native iOS Remote Share engine JavaScript missing')
ios_js=engine_script.group(1).replace(r'const FILE=\(json);', 'const FILE={"name":"verify","path":"verify","size":1,"mime":"application/octet-stream"};')
Path('/tmp/shar-ios-native-remote-verify.js').write_text(ios_js)
mac=Path('macos/LocalWebShareMacApp.swift').read_text()
mac_engine=re.search(r'private var engineHTML: String \{.*?return """(.*?)"""', mac, re.S)
if not mac_engine: raise SystemExit('Native macOS Remote Share engine HTML missing')
mac_script=re.search(r'<script>(.*?)</script>', mac_engine.group(1), re.S)
if not mac_script: raise SystemExit('Native macOS Remote Share engine JavaScript missing')
mac_js=mac_script.group(1).replace(r'const FILE=\(json);', 'const FILE={"name":"verify","path":"verify","size":1,"mime":"application/octet-stream"};')
Path('/tmp/shar-macos-native-remote-verify.js').write_text(mac_js)
PY
  if command -v javac >/dev/null 2>&1; then
    python3 - <<'PYANDROIDWEB'
from pathlib import Path
import re
src=Path('android/app/src/main/java/com/localwebshare/app/LocalHttpServer.java').read_text()
m=re.search(r'private static final String WEB_PAGE = (""".*?""");', src, re.S)
t=re.search(r'private static final String THREE_D_VIEWER_JS = (""".*?""");', src, re.S)
if not m:
    raise SystemExit('Android embedded WEB_PAGE Java text block missing')
if not t:
    raise SystemExit('Android embedded THREE_D_VIEWER_JS Java text block missing')
Path('/tmp/SharAndroidWebPageProbe.java').write_text('final class SharAndroidWebPageProbe { static final String WEB_PAGE = ' + m.group(1) + '; static final String THREE_D_VIEWER_JS = ' + t.group(1) + '; }\n')
PYANDROIDWEB
    rm -rf /tmp/shar-android-webpage-probe
    mkdir -p /tmp/shar-android-webpage-probe
    javac -d /tmp/shar-android-webpage-probe /tmp/SharAndroidWebPageProbe.java >/dev/null 2>&1 || fail "Android embedded browser Java text-block compilation failed"
  fi
  if command -v node >/dev/null 2>&1; then
    node --check remote/server.js >/dev/null || fail "Remote signaling JavaScript syntax failed"
    node --check /tmp/shar-browser-verify.js >/dev/null || fail "Embedded browser JavaScript syntax failed"
    node --check /tmp/shar-3d-viewer-verify.js >/dev/null || fail "Local browser 3D viewer JavaScript syntax failed"
    node --check /tmp/shar-receiver-verify.js >/dev/null || fail "Remote receiver JavaScript syntax failed"
    node --check /tmp/shar-ios-native-remote-verify.js >/dev/null || fail "Native iOS Remote Share JavaScript syntax failed"
    node --check /tmp/shar-macos-native-remote-verify.js >/dev/null || fail "Native macOS Remote Share JavaScript syntax failed"
  fi
fi

ok "repository structure"
ok "version $VERSION_VALUE / build $BUILD_NUMBER"
ok "shared logo assets"
ok "iOS, macOS and Android client sources"
