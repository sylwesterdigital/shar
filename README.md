# LocalWebShare — 1.4.1

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

`VERSION` is authoritative. Current release: **1.4.1** (build/version code **10401**).

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
│   ├── deploy.sh                    # verify + iOS build + Git commit/push
│   ├── verify_repo.sh               # cross-platform release consistency checks
│   ├── app_build.sh                 # iOS build/sign/install/launch
│   ├── build_macos.sh               # macOS build/install/launch
│   ├── build_android.sh             # Android APK build/install when attached
│   ├── build_all.sh                 # macOS + Android + iOS
│   ├── bump-version.sh              # bumps iOS + Android metadata together
│   └── package-release.sh
├── CHANGELOG.md
├── README.md
├── VERSION
└── .gitignore
```

## Shared browser experience

When sharing is enabled, open the displayed local URL from another device on the same LAN, for example:

```text
http://192.168.1.42:8080
```

The browser UI supports:

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
- three button-label modes: **Text**, **Icons**, and **Icon + short**.

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

The supplied `shar-logo.svg` is now the iOS/iPadOS app icon via `Assets.xcassets`.

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

The build creates:

```text
release/LocalWebShare-v1.4.1-macOS-<arch>.zip
```

The app is ad-hoc signed for local use. Distribution/notarization can be added later without changing the application architecture.

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

Build the debug APK and install/launch automatically when an authorised Android device is attached:

```zsh
./scripts/build_android.sh
```

Build APK without installing:

```zsh
./scripts/build_android.sh --no-install
```

The script expects JDK 17 and Android SDK API 35/build-tools 35.0.0. It uses an existing Android Studio/Homebrew JDK and SDK, installs missing SDK packages through `sdkmanager` when available, and downloads Gradle 8.9 into local build output when needed.

APK output:

```text
release/LocalWebShare-v1.4.1-android-debug.apk
```

## Build all clients

With the required toolchains available:

```zsh
./scripts/build_all.sh
```

Order:

```text
macOS → Android → iOS/iPadOS
```

The Android build installs only when an authorised device is attached. The iOS build requires the tethered Apple device because `app_build.sh` is also the installation test.

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

`scripts/deploy.sh` performs:

```text
verify repository/version/platform assets
→ build/sign/install/launch iOS client
→ git add
→ git commit "Release vX.Y.Z"
→ git push origin <current branch>
```

Git operations run locally on the Mac using the existing SSH configuration for:

```text
git@github.com:sylwesterdigital/shar.git
```

For explicit multi-platform local builds before deployment, run `./scripts/build_all.sh` first.

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
