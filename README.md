# LocalWebShare Prototype — 1.3.6

Local iOS Wi-Fi file sharing prototype with browser upload/download and in-app audio/video playback.

## Repository

Canonical repository:

```text
git@github.com:sylwesterdigital/shar.git
```

Expected local checkout:

```text
/Users/smielniczuk/Documents/works/shar
```

Repository layout:

```text
shar/
├── archive/                         # downloaded release ZIPs; Git ignored
├── scripts/
│   ├── build-watch.sh               # visible foreground ZIP watcher
│   ├── deploy.sh                    # build + Git deployment workflow
│   ├── app_build.sh                 # Xcode build/sign/install/launch
│   ├── app_buil.sh                  # compatibility alias
│   ├── app_buld.sh                  # compatibility alias
│   ├── apply-release.sh             # deprecated compatibility wrapper
│   ├── remove-legacy-launchagent.sh # one-time/idempotent cleanup
│   ├── bump-version.sh
│   └── package-release.sh
├── LocalWebShare/
├── LocalWebShare.xcodeproj/
├── CHANGELOG.md
├── README.md
├── VERSION
└── .gitignore
```

`VERSION` is authoritative. This release is **1.3.6**.

## Normal workflow

Run the watcher from the repository:

```zsh
cd /Users/smielniczuk/Documents/works/shar
./scripts/build-watch.sh
```

It stays attached to the current Terminal and prints what it is doing. Stop it with **Ctrl+C**.

It watches:

```text
/Users/smielniczuk/Documents/works/shar/archive/LocalWebSharePrototype-v*.zip
```

When a higher version appears, the watcher performs this visible workflow:

```text
detect ZIP
→ wait until download/write is stable
→ unzip to a temporary directory
→ verify VERSION, Xcode project and deployment scripts
→ synchronise release files into the shar repository
→ run ./scripts/deploy.sh
→ build/sign/install/launch iOS app
→ git commit "Release vX.Y.Z"
→ git push origin <current branch>
→ reload the updated watcher
→ continue watching
```

The watcher follows the same foreground model as the other update watchers: no LaunchAgent, no hidden daemon and no installer/uninstaller cycle.

## Watcher behaviour

The release ZIP is authoritative for repository source files. Synchronisation uses `rsync --delete` while preserving these local paths:

```text
.git/
archive/
.watch-state/
build/
xcuserdata/
```

A package is recorded as processed before native deployment starts. Therefore a failed Xcode/device deployment does not repeat every five seconds. After fixing the build/device issue, run `./scripts/deploy.sh` directly, or use the next bumped release ZIP.

## Deployment script

`scripts/deploy.sh` is the deployment entry point called by the watcher.

It:

1. validates `VERSION`, `README.md`, `CHANGELOG.md` and `.gitignore`;
2. ensures `origin` is `git@github.com:sylwesterdigital/shar.git`;
3. runs `scripts/app_build.sh`;
4. stages repository changes;
5. commits them as `Release vX.Y.Z` when there are changes;
6. pushes the current branch to `origin`.

Run directly when required:

```zsh
cd /Users/smielniczuk/Documents/works/shar
./scripts/deploy.sh
```

## Xcode/device build

```zsh
cd /Users/smielniczuk/Documents/works/shar
./scripts/app_build.sh
```

The script:

- detects full Xcode;
- uses Apple Development team `5P9V78UZAC` by default (overrideable with `TEAM_ID`);
- detects a connected physical iPhone/iPad through `devicectl`;
- builds using automatic signing and provisioning updates;
- verifies the app signature;
- installs the app with `devicectl`;
- launches without LLDB attach, avoiding the earlier `attach by pid ... no such process` path;
- preserves app Documents/uploads unless `--fresh` is explicitly used.

## Legacy LaunchAgent cleanup

The background LaunchAgent design is obsolete. On watcher startup, `scripts/remove-legacy-launchagent.sh` removes, if present:

```text
com.localwebshare.build-watch
~/Library/LaunchAgents/com.localwebshare.build-watch.plist
/Users/smielniczuk/Documents/works/shar/bin/build-watch.sh
```

Nothing installs it again.

## Release policy

Every update must include:

- a bumped `VERSION`;
- matching Xcode marketing/build numbers;
- a new `CHANGELOG.md` entry;
- an updated `README.md`;
- a release ZIP named `LocalWebSharePrototype-vX.Y.Z.zip`;
- a successful device build before the Git release commit is pushed.

`archive/` is intentionally not committed and is not included inside release ZIPs.

Bump the next version:

```zsh
./scripts/bump-version.sh patch
```

Package the current version:

```zsh
./scripts/package-release.sh
```

## iOS app

- local HTTP sharing on port 8080;
- browser drag-and-drop uploads that start automatically;
- browser media cards with image/video thumbnails and file-type metadata;
- click-to-preview images, audio and video in the browser;
- inline audio controls in the browser file list;
- HTTP byte-range support for audio/video seeking;
- separate inline media and attachment-download routes;
- browser download/delete with confirmation;
- iOS file rows with Quick Look-generated thumbnails/type badges;
- tap any file row to open a preview;
- full image preview, AVPlayer video playback and custom audio controls;
- Quick Look fallback for documents/other previewable files;
- swipe/context-menu delete and delete from the preview screen;
- Share sheet support from previews;
- streamed uploads/downloads;
- app Documents storage;
- local-network permission configuration;
- Files/iTunes file-sharing exposure.

Keep the app in the foreground while using the web server because iOS can suspend listener sockets when the app is backgrounded.
