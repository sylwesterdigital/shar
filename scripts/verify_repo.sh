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
! grep -Fq 'exit 3' scripts/app_build.sh || fail "iOS locked-device launch regression still aborts release after successful install"
grep -Fq 'Shar · v\(appVersion)' LocalWebShare/ContentView.swift || fail "iOS visible Settings version missing"
grep -Fq 'Text("Version")' LocalWebShare/ContentView.swift || fail "iOS explicit Version row missing"
grep -Fq 'Text("Build")' LocalWebShare/ContentView.swift || fail "iOS explicit Build row missing"
grep -Fq 'Support Shar' LocalWebShare/ContentView.swift || fail "iOS Support Shar action missing"
grep -Fq 'SFSafariViewController' LocalWebShare/ContentView.swift || fail "iOS in-app support checkout wrapper missing"
grep -Fq 'SharProductInfo.builderName' LocalWebShare/ContentView.swift || fail "iOS builder About identity missing"
! grep -A110 -F 'private var settingsPanel' LocalWebShare/ContentView.swift | grep -Fq '.ignoresSafeArea()' || fail "iOS Settings panel ignores safe area"
grep -Fq 'android:label="Shar"' android/app/src/main/AndroidManifest.xml || fail "Android display name is not Shar"
grep -Fq 'About Shar' android/app/src/main/java/com/localwebshare/app/MainActivity.java || fail "Android About dialog missing"
grep -Fq 'Support Shar' android/app/src/main/java/com/localwebshare/app/MainActivity.java || fail "Android Support Shar action missing"
grep -Fq 'BUILDER_NAME = "MojoWorks"' android/app/src/main/java/com/localwebshare/app/MainActivity.java || fail "Android builder identity missing"
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
grep -Fq 'SharProductInfo.builderName' macos/LocalWebShareMacApp.swift || fail "macOS builder About identity missing"
grep -Fq 'MacNativeRemoteShareCoordinator' macos/LocalWebShareMacApp.swift || fail "macOS native Remote Share coordinator missing"
grep -Fq 'MacNativeRemoteShareQR' macos/LocalWebShareMacApp.swift || fail "macOS native Remote Share QR generator missing"
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
m=re.search(r'private static final String WEB_PAGE = (\"\"\".*?\"\"\");', src, re.S)
if not m:
    raise SystemExit('Android embedded WEB_PAGE Java text block missing')
Path('/tmp/SharAndroidWebPageProbe.java').write_text('final class SharAndroidWebPageProbe { static final String WEB_PAGE = ' + m.group(1) + '; }\n')
PYANDROIDWEB
    rm -rf /tmp/shar-android-webpage-probe
    mkdir -p /tmp/shar-android-webpage-probe
    javac -d /tmp/shar-android-webpage-probe /tmp/SharAndroidWebPageProbe.java >/dev/null 2>&1 || fail "Android embedded browser Java text-block compilation failed"
  fi
  if command -v node >/dev/null 2>&1; then
    node --check remote/server.js >/dev/null || fail "Remote signaling JavaScript syntax failed"
    node --check /tmp/shar-browser-verify.js >/dev/null || fail "Embedded browser JavaScript syntax failed"
    node --check /tmp/shar-receiver-verify.js >/dev/null || fail "Remote receiver JavaScript syntax failed"
    node --check /tmp/shar-ios-native-remote-verify.js >/dev/null || fail "Native iOS Remote Share JavaScript syntax failed"
    node --check /tmp/shar-macos-native-remote-verify.js >/dev/null || fail "Native macOS Remote Share JavaScript syntax failed"
  fi
fi

ok "repository structure"
ok "version $VERSION_VALUE / build $BUILD_NUMBER"
ok "shared logo assets"
ok "iOS, macOS and Android client sources"
