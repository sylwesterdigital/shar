# Changelog

All notable changes to LocalWebShare are recorded here.

## [1.4.1] - 2026-08-29

### Added
- Added gallery-style previous/next navigation in browser, iOS/iPadOS, macOS and Android previews.
- Added swipe-left/swipe-right navigation in native previews and the browser; browser previews also support left/right arrow keys.
- Added inline play/pause controls for audio files in iOS/iPadOS, macOS and Android file lists.
- Added MP3/M4A title/artist metadata extraction and embedded album-artwork thumbnails where metadata contains artwork.
- Added `/artwork/<filename>` to expose embedded audio artwork to the browser UI.
- Added three button presentation modes: Text, Icons, and Icon + short.
- Added `scripts/sync_ui_icons.sh`, which imports supported SVG controls from `archive/icons` at build time without committing the ignored icon library.
- Added `/ui-icon/<name>.svg` for browser controls backed by the locally embedded SVG icon set.

### Changed
- Browser audio rows now use compact inline play/pause + seek controls instead of requiring the preview viewer.
- Browser preview now stays open while navigating through the entire current file list and updates its position indicator.
- Audio cards use embedded cover artwork when available and show title/artist metadata.
- iOS/macOS/Android builds automatically synchronise the local SVG control icon library before compilation.
- iOS marketing/build version bumped to 1.4.1 / 10401.
- Android versionName/versionCode bumped to 1.4.1 / 10401.

## [1.4.0] - 2026-08-29

### Added
- Added the user-supplied `shar-logo.svg` as the canonical shared application logo.
- Added generated iOS/iPadOS AppIcon asset-catalog images derived from the shared logo.
- Added generated macOS iconset assets derived from the shared logo.
- Added generated Android launcher icons derived from the shared logo.
- Added a native macOS SwiftUI client with local web sharing, drag-and-drop import, native media/document previews, delete actions and Finder integration.
- Added a native Android client with a self-contained local HTTP server, native file import/listing, image/video thumbnails, audio/video/image preview and delete actions.
- Added Android browser drag-and-drop upload, preview/playback, download and delete using the same HTTP route contract as the Apple clients.
- Added `scripts/build_macos.sh` for local macOS build/install/launch.
- Added `scripts/build_android.sh` for Android debug APK build plus optional tethered-device install/launch.
- Added `scripts/build_all.sh` to build macOS, Android and iOS/iPadOS clients in sequence.
- Added `scripts/verify_repo.sh` to validate cross-platform release structure, versions and branding assets.

### Changed
- Promoted the project from an iOS-only prototype to a three-platform local sharing suite; version moved from 1.3.6 to 1.4.0.
- `FileStore` now uses an app-managed Application Support shared directory on macOS rather than the user's general Documents directory.
- `FileStore` now supports importing/copying external files into managed storage.
- `scripts/bump-version.sh` now updates both the Xcode version/build metadata and Android `versionName`/`versionCode`.
- `scripts/deploy.sh` now runs cross-platform repository verification before the tethered iOS installation test and Git commit/push.
- `.gitignore` now excludes generated release output and Android build/Gradle output.
- iOS marketing/build version bumped to 1.4.0 / 10400.
- Android versionName/versionCode set to 1.4.0 / 10400.

### Branding
- iOS App Store icon renders use an opaque background to satisfy Apple app-icon alpha restrictions while preserving the supplied artwork.
- macOS and Android keep transparent-capable source renditions where appropriate.

## [1.3.6] - 2026-08-29

### Added
- Added browser drag-and-drop upload; dropped files upload immediately without a separate Upload button.
- Added browser media cards with image/video visual previews, type/size metadata and inline audio controls.
- Added click-to-preview modal playback for images, audio and video in the browser.
- Added `/media/` inline serving route with HTTP byte-range support so browser audio/video playback can seek correctly.
- Added iOS Quick Look thumbnails/type badges for file rows.
- Added tap-to-preview on iOS for images, audio, video and Quick Look-compatible documents.
- Added custom iOS audio playback controls, native video playback, full image preview and Share actions.
- Added explicit delete actions on iOS via swipe, context menu and the preview toolbar.

### Fixed
- Fixed device signing defaults after `app_build.sh` selected unrelated Team ID `F7K9RLSWY7` and Xcode reported `No Account for Team`.
- `app_build.sh` now defaults to the known Apple Development team `5P9V78UZAC`; `TEAM_ID` remains overrideable.

### Changed
- Browser file metadata now includes media kind and MIME type.
- Downloads remain attachment responses while previews are served inline.
- Xcode marketing/build version bumped to 1.3.6 / 10306.

## [1.3.5] - 2026-08-29

### Fixed
- Fixed the foreground watcher crash `BUILD_ARGS[@]: unbound variable` seen with the v1.3.4 updater.
- Removed the empty-array forwarding mechanism that caused the updater failure.
- Removed the need for `apply-release.sh` as the primary release path; it is now only a compatibility wrapper.

### Changed
- Reworked the release workflow to match the existing foreground watcher/deploy pattern used in the user's other projects.
- `scripts/build-watch.sh` now only watches, validates, extracts and synchronises a release, then visibly calls `scripts/deploy.sh`.
- `scripts/deploy.sh` now owns build/sign/install/launch plus Git commit and push.
- Shell entry points now use `#!/bin/zsh` to match the normal macOS interactive environment while keeping their syntax intentionally simple.
- The watcher selects the highest semantic-version release ZIP and ignores releases that are not newer than the repository `VERSION`.
- The watcher marks a failed package as processed before deployment so a failed native build does not automatically rerun every five seconds.
- The release ZIP is authoritative for repository source files; `.git/`, `archive/`, `.watch-state/`, and `build/` are preserved during synchronisation.

### Repository
- Canonical remote remains `git@github.com:sylwesterdigital/shar.git`.
- `archive/` remains Git ignored.
- The obsolete `com.localwebshare.build-watch` LaunchAgent is removed idempotently and is never installed again.

## [1.3.4] - 2026-08-29

### Changed
- The release repository is explicitly tied to `git@github.com:sylwesterdigital/shar.git`.
- The foreground watcher lives at `scripts/build-watch.sh` inside `/Users/smielniczuk/Documents/works/shar`.
- `archive/`, `.watch-state/`, and local build output are ignored by Git.
- Release application builds the iOS app first, then commits and pushes the release after a successful build/install/launch.

### Added
- Initial foreground release watcher and Git deployment automation.
- Legacy LaunchAgent cleanup.
