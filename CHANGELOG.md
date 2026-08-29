# Changelog

All notable changes to LocalWebShare are recorded here.

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
