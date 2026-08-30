# Shar — 2.1.4

Local-first file and media sharing for **iOS/iPadOS, macOS and Android**, now with optional **remote WebRTC sharing**. Each native client still runs its local HTTP server on port 8080 for LAN use, while Remote Share creates an expiring QR/link and transfers bytes over an encrypted WebRTC data channel directly peer-to-peer when possible or through the Shar TURN relay when required.

## Repository

Canonical repository:

```text
git@github.com:sylwesterdigital/shar.git
```

Expected local checkout:

```text
/Users/smielniczuk/Documents/works/shar
```

`VERSION` is authoritative. Current release: **2.1.4** (build/version code **20104**).

## Branding

The canonical logo source is:

```text
assets/shar-logo.svg
```

The repository also contains generated platform icon assets derived from that SVG:

- iOS/iPadOS: `LocalWebShare/Assets.xcassets/AppIcon.appiconset/`
- macOS: `macos/AppIcon.iconset/`
- Android: `android/app/src/main/res/mipmap-*/ic_launcher*.png`

Do not edit the generated icons independently; update `assets/shar-logo.svg` and regenerate the platform icon sets together.

## Repository layout

```text
shar/
├── archive/                         # downloaded release ZIPs; Git ignored
├── assets/                          # canonical shared logo artwork
├── LocalWebShare/                   # iOS/iPadOS SwiftUI client
├── LocalWebShare.xcodeproj/
├── macos/                           # native macOS SwiftUI client + iconset
├── android/                         # native Android client
├── remote/                          # dependency-free signaling service source
├── homepage/                        # product page + public WebRTC receiver
├── scripts/
│   ├── build-watch.sh               # visible foreground ZIP watcher
│   ├── deploy.sh                    # foreground entry point for full release/deploy
│   ├── verify_repo.sh               # cross-platform release consistency checks
│   ├── app_build.sh                 # iOS build/sign/install/launch
│   ├── build_macos.sh               # macOS build/install/launch
│   ├── build_android.sh             # Android APK build/install when attached
│   ├── build_all.sh                 # distribution macOS + Android + iOS validation/install
│   ├── build_macos_release.sh       # universal2 signed/notarized DMG + ZIP
│   ├── build_android_release.sh     # signed APK + AAB
│   ├── release_and_deploy.sh        # build → GitHub Release → homepage deployment
│   ├── publish_github_release.sh    # GitHub tag/release/assets
│   ├── deploy_homepage.sh           # render + rsync + verify /labs/shar
│   ├── check_remote_share.sh        # remote API/TURN + bootstrap capability preflight
│   ├── test_remote_protocol.sh      # local signaling/auth/path-safety smoke test
│   ├── deploy_remote_share.sh       # install/update/verify signaling + TURN
│   ├── remote_bootstrap.sh          # one-time Ubuntu/Debian privileged bootstrap
│   ├── release_profile.sh           # private SSH profile loader/importer
│   ├── bump-version.sh              # bumps iOS + Android metadata together
│   └── package-release.sh
├── CHANGELOG.md
├── README.md
├── VERSION
└── .gitignore
```


## Optional developer updates

Shar can show a compact **ⓘ** developer-updates button. It is **off by default** to keep the minimal interface clean. On iOS/iPadOS enable **Settings → Developer → Show ⓘ updates button**; macOS and Android expose the same opt-in preference in their local controls.

The panel is intentionally brief: it shows the latest few release versions with one short development summary each, similar to a development-channel update feed rather than the complete `CHANGELOG.md`. The shared browser UI has the same hidden-by-default option and remembers the choice in browser storage. Native clients persist the preference locally as well.


## Background audio on iPhone/iPad

Shar enables the iOS `audio` background mode and uses an `AVAudioSession` playback category for audio files. When an audio track is playing, it can continue after Shar is sent to the background or the iPhone/iPad screen locks. Video playback intentionally pauses when Shar leaves the foreground. Normal system audio interruptions (for example calls or Siri) can pause playback and Shar resumes when iOS indicates that playback should continue.

Background audio is for media playback only; it is not used as a workaround to guarantee that the local HTTP sharing server remains available while iOS is backgrounded.

## Preview behavior

Image previews default to **fit**, keeping the entire image visible inside the available viewer area rather than cropping or starting zoomed in. The iOS/iPadOS preview also provides a persistent bottom-right **X** close control in addition to gesture dismissal. Browser image/video previews use `object-fit: contain` for the same fit-first behavior.

## LAN and remote WebRTC sharing

### v2.1.4 release pipeline resilience
- A successful tethered iOS install is now authoritative for distribution validation. If the device locks before the optional automatic launch, Shar prints a warning and continues the remaining release/deployment stages.
- Actual build, signing and installation failures remain fatal. This prevents an already-installed iPhone app from blocking macOS/Android artifacts, remote-service deployment, GitHub publication and homepage deployment.

### v2.1.3 unified native library UI and About/Support
- macOS now mirrors the iOS library structure instead of using a configuration-heavy sidebar: the main window has the import `+`, compact LAN Sharing strip, All/Images/Audio/Video/Docs/Other media filter chips, visible filtered-file count, and native Grid/List modes.
- macOS button-label mode, layout, file-size visibility, colour theme, developer updates and sharing details moved into the **Config** drawer opened by the top-right cog.
- iOS About now renders **Version** and **Build** as explicit visible rows instead of relying on a compact `LabeledContent` value that could disappear in the narrow settings drawer.
- iOS and macOS About identify **MojoWorks** as the builder and link to the Shar website and source repository. Android now has a native **About Shar** dialog with the same builder/version/product information.
- All native clients include **Support Shar**. The clients open the stable `https://mojoworks.xyz/labs/shar/support.html` endpoint; deployment renders that page to forward to `SHAR_STRIPE_SUPPORT_URL`, which must be a Stripe Payment Link (`https://buy.stripe.com/...`). Keeping the payment target in the private release profile allows the Stripe link to change without shipping new apps.
- `scripts/release_profile.sh` persists `SHAR_STRIPE_SUPPORT_URL` and can import an existing `RANTLIST_STRIPE_SUPPORT_URL` / `RANTLIST_SUPPORT_URL` when bootstrapping the Shar profile. If no Stripe link is configured yet, the support page reports that clearly instead of embedding a fake payment URL.

### v2.1.2 native macOS Secure Remote Share
- macOS Remote Share now stays entirely inside the native Shar app. Pressing **Remote** no longer starts the LAN HTTP server or opens `127.0.0.1:8080` in a browser.
- The native macOS sheet mirrors the iOS secure flow: filename/size, status, mandatory receiver PIN, local QR code, copy/share link actions, sender approval, encrypted-transfer progress, SHA-256 verified completion, retry and cancel.
- macOS uses the same off-screen WebKit WebRTC/Web Crypto transport engine pattern as iOS while SwiftUI owns the visible UI and reads the selected native file through a bounded chunk bridge. The LAN server remains independent and may stay off during Remote Share.
- **Share link** uses the native macOS sharing-service picker so the secure receiver URL can be sent through Mail, Messages, AirDrop and installed sharing extensions.

### v2.1.1 Android build fix
- Fixed the secure Remote Share browser JavaScript embedded in the Android Java text block so Gradle/Javac no longer rejects the Base64URL helper as an illegal Java escape sequence.
- Added a release verification probe that compiles the actual Android embedded browser text block with `javac`, catching Java-string/text-block escaping regressions before the expensive distribution build starts.

### v2.1.0 secure Remote Share

Shar 2.1 makes Remote Share secure-by-default. A sender creates a random 256-bit AES-GCM content key locally, and the receiver URL carries that key only in the URL fragment:

```text
https://mojoworks.xyz/labs/shar/receive.html#share=<random-session>&key=<256-bit-content-key>
```

The browser does not send the fragment in the HTTP request, so the content key is not disclosed to nginx, the signaling API or the TURN relay. The signaling service stores only temporary session state needed for WebRTC coordination and completion accounting. Secure sessions also use private metadata: original filenames, folder paths and MIME types are sent only inside the encrypted WebRTC data channel.

Every v2.1 secure share additionally requires a separate six-digit PIN and explicit sender approval. The PIN itself is not sent to the signaling service: sender and receiver derive a PBKDF2-SHA256 proof locally, and the service rate-limits incorrect proof attempts. After the correct PIN, the receiver remains pending until the sender presses **Approve**; TURN/WebRTC receiver credentials are not released before approval. Send the PIN separately from the link when practical.

File contents and control metadata are wrapped in AES-256-GCM before being sent through WebRTC. The receiver calculates SHA-256 while decrypting each file and refuses completion if the digest does not match the encrypted sender digest. The final completion acknowledgement is itself encrypted and includes the verified digest list. WebRTC/DTLS remains an additional transport-encryption layer, and Shar first attempts direct P2P before falling back to the dedicated Shar TURN relay.

The dedicated TURN configuration blocks loopback, private, carrier-grade-NAT and link-local relay targets, applies allocation quotas, and the nginx signaling route disables normal access logging. Runtime ICE uses only Shar-controlled STUN/TURN infrastructure.

### v2.0.8 remote sender/runtime ICE fix

v2.0.8 fixes a JavaScript syntax regression inside the native iOS off-screen WebRTC engine that could leave the native Remote Share sheet stuck on **Creating temporary Internet share…** without either a link or an error. Release verification now extracts that exact embedded engine from `ContentView.swift` and runs `node --check` against it before packaging.

Shar Remote Share no longer contacts Google STUN. The signaling service now returns only the dedicated Shar coturn host for STUN/TURN ICE discovery, so runtime WebRTC connectivity uses Shar-controlled infrastructure. Android's Gradle `google()` repository remains a build-time dependency source and is unrelated to the running Remote Share network path.

LAN sharing remains unchanged: devices on the same reachable network can open the local Shar URL such as `http://192.168.1.42:8080`. Cellular carrier IP addresses are still not treated as inbound-routable Shar addresses.

For different networks, use **Remote Share**. On iPhone/iPad or macOS, choose **Remote** directly on a native Shar file row/card. This path is independent of the LAN Sharing switch: Shar does not start or navigate to the local `:8080` browser server. The native SwiftUI sheet immediately creates the Internet share and shows the QR code/link, status and transfer progress. The shared browser UI still has its own ↗ Remote Share control for people intentionally using Shar from a browser. Shar creates a 30-minute, one-receiver secure capability link whose session ID and 256-bit content key are carried in the URL fragment. Native iOS generates the QR code locally, and the sender also displays a separate six-digit PIN. The recipient must enter the PIN and then be explicitly approved by the sender before WebRTC receiver credentials are released. The receiver needs only a modern browser. Signaling is handled by `https://mojoworks.xyz/api/shar/remote/v1`; file bytes are never uploaded there. WebRTC first attempts a direct peer-to-peer connection, then automatically uses the dedicated Shar TURN relay when direct ICE connectivity fails. The receiver UI reports whether it is connected and saves files directly to disk when the browser exposes the File System Access API.

Folder sharing uses a file manifest containing relative paths. Desktop browsers with directory access can recreate the folder hierarchy; browsers without direct file-system writing fall back to individual Save links and enforce a memory safety limit for large transfers. On iOS and macOS, the native Remote Share sheet uses an internal off-screen WebRTC engine and reads the selected native file through a controlled chunk bridge; the user never sees the local browser UI and the LAN server can remain disabled. Keep Shar in the foreground while an outgoing remote transfer is active because iOS does not grant arbitrary long-running background networking to a file sender.

### Remote infrastructure and first-time bootstrap

v2.0.7 fixes Remote Share finalization: the receiver now treats verified completion as a terminal success state, acknowledges completion back to the sender over the WebRTC data channel, and the signaling service keeps completed one-time sessions available for a short 60-second grace period while rejecting any second receiver. This prevents expected session cleanup or WebRTC disconnects from overwriting a successfully downloaded file with a false connection error. The receiver validates per-file sizes plus the total received byte count and presents a stable **Transfer complete ✓** state. v2.0.6 fixes the native iOS Remote Share link action: **Share link** now presents `UIActivityViewController` with the receiver HTTPS URL as the activity item, so the link can be sent directly through Messages, Mail, AirDrop and installed messaging/share apps. **Copy link** remains clipboard-only. v2.0.5 keeps the native iOS Remote Share architecture from v2.0.4 and hardens signaling-service deployment readiness. The bootstrap stops the source path watcher before replacing `server.js`, validates the installed Node source/environment, restarts the service, and waits through bounded localhost health retries before nginx/public-route validation. If startup genuinely fails it prints `systemctl status`, recent `journalctl` output and listening-socket diagnostics before rollback. v2.0.4 separates native iOS Remote Share completely from LAN browser sharing. v2.0.3 hardens nginx routing using nginx's own effective configuration rather than directory-order guesses. Every loaded TLS server block whose `server_name` contains the exact apex token `mojoworks.xyz` receives the Shar include, while stale includes are removed from non-target blocks. This covers duplicate/legacy apex vhosts safely. The bootstrap no longer treats a forced `127.0.0.1` SNI request as authoritative, because production nginx listeners may be bound to a specific public address. It validates the signaling upstream directly, reloads nginx, then makes the real public HTTPS API (with cache-busting retries) the release gate. On failure it prints response/nginx/DNS diagnostics and restores all nginx files it changed. If the signaling service exists locally but the public endpoint is missing or stale, normal deployments automatically re-enter this repair/bootstrap path instead of incorrectly taking the fast update path.

The normal ZIP pipeline manages the remote pieces automatically. `scripts/deploy_remote_share.sh` connects using the same private Shar SSH profile as the homepage deployment. On the first v2 release it checks the Ubuntu/Debian host and, when passwordless sudo is available, installs only missing packages (`nodejs`, `qrencode`, `coturn`, `nginx`, etc.), creates a dedicated `shar-coturn.service`, installs the signaling service, safely injects an nginx API proxy, opens TURN ports in UFW when UFW is active, and verifies the public health endpoint.

The dedicated TURN service uses port **3479** and relay range **49210–49250**, avoiding changes to an existing Rantlist coturn setup. Its long-lived HMAC secret lives only in `/etc/shar-remote.env` (root-readable); clients receive short-lived TURN usernames/passwords from the signaling service.

If the deployment SSH user does not have passwordless sudo, automation intentionally stops before publication and prints the exact one-time `sudo /tmp/shar-remote-bootstrap.sh ...` command. After that bootstrap, `/opt/shar-remote` is writable by the release user and a systemd path unit restarts the service after source updates, so future ZIP releases do not normally need root access. If nginx cannot be identified or `nginx -t` fails, the bootstrap aborts and restores the previous config automatically.

After completing a one-time manual bootstrap or correcting an external firewall/DNS issue, run `touch archive/LocalWebSharePrototype-v2.1.4.zip`. The foreground watcher recognizes the changed ZIP signature and performs an intentional same-version deployment retry.

If the VPS has a provider-level firewall outside Ubuntu/UFW, that control panel must also allow TURN port **3479 TCP/UDP** and relay range **49210–49250 TCP/UDP**. The deployment script can manage UFW but cannot change an external hosting-provider firewall.

### Android release build note

Shar reads the visible Android version from the installed package metadata (`PackageInfo`) rather than directly referencing Gradle-generated `BuildConfig` constants. This keeps the native UI compatible with Android Gradle Plugin configurations where BuildConfig generation is disabled. Repository verification guards against reintroducing the broken `BuildConfig.VERSION_*` dependency.

Useful checks:

```text
./scripts/check_remote_share.sh
./scripts/deploy_remote_share.sh
curl https://mojoworks.xyz/api/shar/remote/v1/health
```

## Automated release pipeline

The normal release workflow is now deliberately one-action: leave the foreground watcher running and save a newer release ZIP into:

```text
/Users/smielniczuk/Documents/works/shar/archive/
```

For example:

```text
LocalWebSharePrototype-v2.1.4.zip
```

`scripts/build-watch.sh` detects the highest new semantic version, waits until the ZIP is stable, synchronises it into the repository, then visibly calls `scripts/deploy.sh`. The deployment pipeline performs:

```text
verify repository and credentials
→ smoke-test remote signaling/auth/path safety
→ create/check Android release signing
→ build + notarize macOS universal2 DMG/ZIP
→ build signed Android APK/AAB
→ compile-check iOS/iPadOS Release
→ install/launch iOS on a tethered development device when one is available
→ deploy/update + verify Shar signaling and dedicated TURN relay
→ git commit + push main
→ tag the exact commit
→ publish GitHub Release assets
→ render homepage against that exact release
→ rsync homepage + WebRTC receiver to /var/www/mojoworks/labs/shar
→ verify https://mojoworks.xyz/labs/shar/ and /receive.html
→ resume foreground watching
```

The public release repository is:

```text
https://github.com/sylwesterdigital/shar/releases
```

The product page is:

```text
https://mojoworks.xyz/labs/shar/
```

### Distribution artifacts

A successful automated release produces:

```text
release/LocalWebShare-vVERSION-macOS-universal2.dmg
release/LocalWebShare-vVERSION-macOS-universal2.zip
release/LocalWebShare-vVERSION-macOS-SHA256.txt
release/LocalWebShare-vVERSION-android.apk
release/LocalWebShare-vVERSION-android.aab
release/LocalWebShare-vVERSION-android-SHA256.txt
```

The macOS build targets **macOS 13.0+**, is Developer ID signed and notarized. v1.6.1 removes macOS-14-only `ContentUnavailableView` usage so the declared macOS 13 deployment target compiles correctly. Android uses a persistent release key at `~/.config/workwork/shar-android-release.keystore`; its password is stored in macOS Keychain under `workwork.shar.android.keystore`. If the key does not exist on the release Mac, the pipeline creates it automatically on the first release. The keystore must be backed up because future Android upgrades must use the same key.

### Homepage deployment profile

Shar keeps SSH credentials outside Git at:

```text
~/.config/workwork/shar-release.env
```

On the first run, `scripts/release_profile.sh` imports the existing Rantlist deployment host/user/port/ownership settings when available and pins Shar's remote directory to:

```text
/var/www/mojoworks/labs/shar
```

The homepage is rendered only after the matching GitHub Release is published and its required macOS/Android assets are present.

## Shared browser experience

When sharing is enabled, open the displayed local URL from another device on the same LAN, for example:

```text
http://192.168.1.42:8080
```

The browser UI is deliberately compact so the file library begins near the top of the page. It has no large product/logo header and supports:

- drag files anywhere onto the upload area to upload immediately;
- multi-file picker upload;
- image thumbnails and full preview;
- inline audio playback;
- inline video preview/playback;
- byte-range media serving for seeking;
- download;
- delete with confirmation;
- file type and size metadata;
- previous/next preview navigation without closing the viewer;
- left/right swipe navigation in the preview and keyboard arrow navigation in the browser;
- audio play/pause and seeking directly from the file list;
- MP3/M4A metadata (title/artist) and embedded album artwork when present;
- three button-label modes: **Text**, **Icons**, and **Icon + short**;
- media filter chips for All, Images, Audio, Video, Documents and Other;
- Grid and List layouts, with Grid as the default;
- a gear/settings drawer containing button style, layout and colour themes;
- colour themes: System, Ocean, Forest, Sunset and Violet;
- exclusive media playback: starting one audio/video player automatically pauses other players;
- adaptive grid density controlled by a **Thumbnail / card size** slider (120–320 px), with smaller cards automatically fitting more columns while narrow screens retain at least two columns;
- browser-wide **Text size** scaling from 75–125%;
- built-in **Minimal**, **Balanced** and **Large** UI presets plus one browser-local **My saved preset**;
- **Minimal** is the default browser preset: icon-only action buttons, 150 px adaptive cards, 90% text sizing, tighter spacing and a shorter upload area;
- SVG action buttons render a single icon; fallback glyphs appear only when a configured SVG icon cannot load.
- **Remote** on any file card creates an expiring WebRTC share link + QR code; the top ↗ button can also share files/folders selected directly from the browser device.
- Remote transfers use ordered WebRTC DataChannels with 64 KiB chunks, buffered-amount backpressure, per-file byte-count validation, and automatic direct-vs-TURN connection reporting.

The server routes are intentionally consistent across clients:

```text
GET    /
GET    /api/files
POST   /upload?filename=...
GET    /media/<filename>
GET    /artwork/<filename>
GET    /ui-icon/<name>.svg
GET    /files/<filename>
DELETE /files/<filename>
```

Remote signaling is intentionally separate from the local server:

```text
https://mojoworks.xyz/api/shar/remote/v1
https://mojoworks.xyz/labs/shar/receive.html
```


## Optional UI icon source

The repository keeps downloaded/local release material out of Git, but the build can use the existing SVG icon library at:

```text
/Users/smielniczuk/Documents/works/shar/archive/icons
```

`scripts/sync_ui_icons.sh` runs automatically before iOS, macOS and Android builds. It embeds supported SVGs such as `play.svg`, `pause.svg`, `preview.svg`, `download.svg`, `delete.svg`, `close.svg`, `photo.svg`, `video.svg` and `file.svg` into the local builds. The `archive/` folder remains ignored and the icon source itself is not committed. If that folder is unavailable, native/system fallback icons are used.

## iOS / iPadOS

Native SwiftUI client with Files/Documents storage, media thumbnails, image/audio/video/document previews, gallery-style previous/next navigation, inline audio playback, MP3 artwork/title/artist metadata, delete/share actions and the local HTTP server.

The iPhone/iPad home screen is compact and media-first:

- system launch screen using the `SharLogo` asset followed by a startup splash that displays **Shar** and a live Wi-Fi/mobile/offline network check;
- an always-visible circular **+** button in the top-left opens an add menu with **Photos & Videos**, **Record Video**, and **Files**;
- **Photos & Videos** opens the native multi-select Photos picker and copies selected images/videos into Shar's Documents/shared library;
- **Record Video** opens the native camera full-screen, records video with microphone audio, then stores the finished timestamped `.mov` directly in Shar;
- **Files** retains the native multi-file Files picker for iCloud Drive, On My iPhone and installed document providers;
- top-row Sharing toggle plus Copy Address and Share Address controls;
- horizontally scrolling media-type filter chips immediately below the sharing row;
- Grid view by default, with optional List view;
- a right-side settings drawer opened from the top-right gear, positioned below the iPhone safe area/notch;
- the Settings header and About section both show the installed app version/build;
- persisted Text / Icons / Icon + short button style;
- persisted System / Ocean / Forest / Sunset / Violet accent themes;
- optional auto-start sharing on Wi-Fi and file-size display;
- one shared inline audio player, so playing a new track stops the previous track;
- opening any full preview stops inline audio first.

Build, sign, install and launch on the tethered iPhone/iPad:

```zsh
cd /Users/smielniczuk/Documents/works/shar
./scripts/app_build.sh
```

Defaults:

- Apple Development Team: `5P9V78UZAC`
- automatic Xcode provisioning/signing
- physical-device detection through `devicectl`
- bundle ID generated from the team unless overridden
- existing app Documents/uploads preserved unless `--fresh` is supplied

The supplied `shar-logo.svg` is the iOS/iPadOS app icon via `Assets.xcassets`, and the installed app display name is **Shar**.

Keep the iOS app in the foreground while serving files because iOS can suspend listener sockets when the app is backgrounded or the device locks.

## macOS

Native SwiftUI client using the same Swift HTTP server implementation as iOS.

Features:

- native file/media library with previous/next/swipe preview navigation;
- inline audio play/pause and embedded artwork/title/artist metadata;
- selectable Text / Icons / Icon + short button presentation;
- local HTTP sharing on port 8080;
- drag files directly into the Mac app to import;
- image/audio/video/Quick Look previews;
- delete and reveal-in-Finder actions;
- managed shared folder at:

```text
~/Library/Application Support/LocalWebShare/Shared
```

Build, install into `~/Applications`, and launch:

```zsh
./scripts/build_macos.sh
```

Build without launching:

```zsh
./scripts/build_macos.sh --no-launch
```

The fast local build creates an architecture-specific ZIP under `release/`. For public releases, `scripts/build_macos_release.sh` builds a universal2 binary, Developer ID signs it, submits it for Apple notarization, staples it, and produces DMG + ZIP assets. `scripts/build_macos.sh` remains available for fast local development builds.

## Android

Native Android client implemented with Android platform APIs and no third-party runtime libraries.

Features:

- local HTTP sharing on port 8080;
- previous/next and swipe navigation in the native preview;
- inline audio play/pause plus embedded album artwork/title/artist metadata;
- selectable Text / Icons / Icon + short button presentation;
- native file import;
- native file list with image/video thumbnails;
- tap to preview images, video and audio;
- delete from the file list or preview;
- browser drag-and-drop upload/download/preview/delete using the same route contract as iOS/macOS;
- app-private shared file storage.

For fast local development, build the debug APK and install/launch automatically when an authorised Android device is attached:

```zsh
./scripts/build_android.sh
```

Build APK without installing:

```zsh
./scripts/build_android.sh --no-install
```

The script expects JDK 17 and Android SDK API 35/build-tools 35.0.0. It uses an existing Android Studio/Homebrew JDK and SDK, installs missing SDK packages through `sdkmanager` when available, and downloads Gradle 8.9 into local build output when needed.

Local debug output:

```text
release/LocalWebShare-v1.7.3-android-debug.apk
```

Public signed release output from `scripts/build_android_release.sh`:

```text
release/LocalWebShare-v1.7.3-android.apk
release/LocalWebShare-v1.7.3-android.aab
```

## Build all clients

With the required toolchains available:

```zsh
./scripts/build_all.sh
```

Order:

```text
Android signing bootstrap/check
→ signed + notarized macOS universal2 DMG/ZIP
→ signed Android APK/AAB
→ generic iOS/iPadOS Release compile validation
→ tethered iOS install/launch when a development device is available
```

A missing tethered iPhone/iPad does not block macOS/Android publication; the generic iOS Release compile still has to pass.

## Foreground release watcher

Run:

```zsh
cd /Users/smielniczuk/Documents/works/shar
./scripts/build-watch.sh
```

It stays attached to the current Terminal and stops with **Ctrl+C**. It watches:

```text
/Users/smielniczuk/Documents/works/shar/archive/LocalWebSharePrototype-v*.zip
```

A newer release is unpacked and synchronised into this repository, preserving `.git/`, `archive/`, `.watch-state/`, build output and local Xcode user data. The watcher then visibly calls `scripts/deploy.sh`.

There is no LaunchAgent and no background daemon. The obsolete `com.localwebshare.build-watch` LaunchAgent is only removed if an old copy still exists.

## Deployment and Git

`scripts/deploy.sh` delegates to the full release workflow, which performs:

```text
verify repo + credentials
→ build macOS/Android/iOS
→ git commit "Release vX.Y.Z" + push main
→ create/push tag vX.Y.Z
→ publish GitHub Release with macOS + Android artifacts
→ render the homepage from that exact published release
→ deploy to /var/www/mojoworks/labs/shar
→ verify https://mojoworks.xyz/labs/shar/
```

Git operations run locally on the Mac using the existing SSH configuration for:

```text
git@github.com:sylwesterdigital/shar.git
```

For an explicit release-quality multi-platform build without publishing/deploying, run `./scripts/build_all.sh`.

## Release policy

Every update must include:

- bumped `VERSION`;
- matching iOS marketing/build number;
- matching Android `versionName`/`versionCode`;
- updated `CHANGELOG.md`;
- updated `README.md`;
- platform icon assets when branding changes;
- release ZIP named `LocalWebSharePrototype-vX.Y.Z.zip`;
- Git commit/push through the local deployment workflow.

Bump a version:

```zsh
./scripts/bump-version.sh patch
./scripts/bump-version.sh minor
./scripts/bump-version.sh major
```

Package:

```zsh
./scripts/verify_repo.sh
./scripts/package-release.sh
```

## Release scripts

```text
scripts/release_and_deploy.sh           full release pipeline
scripts/publish_github_release.sh      publish/update GitHub Release
scripts/deploy_homepage.sh             render, rsync and verify mojoworks homepage
scripts/build_macos_release.sh         signed/notarized universal2 macOS artifacts
scripts/build_android_release.sh       signed Android APK + AAB
scripts/build_ios_check.sh             generic unsigned iOS Release compile validation
scripts/setup_android_release.sh       automatic one-time Android signing bootstrap
scripts/check_*_release_credentials.sh release-host preflight checks
scripts/release_profile.sh             private SSH deployment-profile loader
```


## v1.7.5 platform guard

Shar's iOS background-audio session setup is compiled only for iOS. The shared media playback controller remains available to macOS without referencing `AVAudioSession`, which Apple marks unavailable on macOS. This keeps background/lock-screen audio on iPhone while allowing the universal2 macOS release build to compile normally.

Remote signaling defaults to an active-session cap and 30 new remote shares per hour per source IP.

### Remote release safety checks

A local protocol smoke test runs before any server deployment. It validates disposable session creation/join, TURN credential issuance, signaling relay, one-time completion invalidation, and path-traversal rejection. The Ubuntu bootstrap separately validates systemd services, TURN listening ports, nginx syntax/rollback, and the public API health endpoint before the GitHub release/homepage are published.
