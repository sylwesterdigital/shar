# Shar — 1.7.3

Local-first Wi-Fi file and media sharing for **iOS/iPadOS, macOS and Android**. Each native client stores its own shared files, can run a local HTTP server on port 8080, and exposes the same browser workflow for drag-and-drop upload, download, preview and delete.

## Repository

Canonical repository:

```text
git@github.com:sylwesterdigital/shar.git
```

Expected local checkout:

```text
/Users/smielniczuk/Documents/works/shar
```

`VERSION` is authoritative. Current release: **1.7.3** (build/version code **10703**).

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
│   ├── release_profile.sh           # private SSH profile loader/importer
│   ├── bump-version.sh              # bumps iOS + Android metadata together
│   └── package-release.sh
├── CHANGELOG.md
├── README.md
├── VERSION
└── .gitignore
```


## Preview behavior

Image previews default to **fit**, keeping the entire image visible inside the available viewer area rather than cropping or starting zoomed in. The iOS/iPadOS preview also provides a persistent bottom-right **X** close control in addition to gesture dismissal. Browser image/video previews use `object-fit: contain` for the same fit-first behavior.

## Wi-Fi versus cellular sharing

Shar is a local HTTP server. On Wi-Fi/LAN, other devices on the same reachable network can connect directly to the Shar address. A cellular connection can have Internet access while still being unsuitable for inbound hosting: most mobile carriers place phones behind carrier-grade NAT and/or inbound firewalls, so discovering the carrier-facing public IP does **not** normally make port 8080 reachable from the Internet.

For sharing outside the local network, use a private VPN/tunnel or a future Shar relay service. Shar does not advertise a cellular public IP as a working share address because that would be misleading on the majority of carrier networks.

## Automated release pipeline

The normal release workflow is now deliberately one-action: leave the foreground watcher running and save a newer release ZIP into:

```text
/Users/smielniczuk/Documents/works/shar/archive/
```

For example:

```text
LocalWebSharePrototype-v1.7.3.zip
```

`scripts/build-watch.sh` detects the highest new semantic version, waits until the ZIP is stable, synchronises it into the repository, then visibly calls `scripts/deploy.sh`. The deployment pipeline performs:

```text
verify repository and credentials
→ create/check Android release signing
→ build + notarize macOS universal2 DMG/ZIP
→ build signed Android APK/AAB
→ compile-check iOS/iPadOS Release
→ install/launch iOS on a tethered development device when one is available
→ git commit + push main
→ tag the exact commit
→ publish GitHub Release assets
→ render homepage against that exact release
→ rsync homepage to /var/www/mojoworks/labs/shar
→ verify https://mojoworks.xyz/labs/shar/
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
