# Changelog

## [2.1.7] - 2026-08-30

### macOS identity and navigation
- Changed the optional macOS **ⓘ** toolbar action to open **Developer updates**, matching the iOS behavior.
- Moved the full product/company About experience to the application menu **Shar → About Shar**, backed by the dedicated native About panel.
- Set the generated macOS bundle `CFBundleName` to **Shar** in both development and notarized release builders, removing the user-visible `LocalWebShare` application-menu name while retaining internal target/executable compatibility.
- Added release guards for the macOS info-button routing, application-menu About command and visible bundle name.

### Release metadata
- Added v2.1.7 to native developer-update feeds and updated runtime client identifiers/signaling health version.
- Bumped iOS/macOS marketing/build version and Android versionName/versionCode to 2.1.7 / 20107.

## [2.1.6] - 2026-08-30

### macOS audio playback
- Replaced per-card macOS `AVPlayer` instances with the shared audio playback controller so only one inline audio file can play at a time.
- Grid/List changes no longer interrupt the active inline audio session because the player is owned by the parent macOS library view instead of disposable card rows.
- Deleting the active audio file stops the shared player cleanly.

### Support and About
- Added a permanent dollar-sign **Support Shar** control to the macOS top bar beside About and Config; iOS now also exposes Support in its top toolbar.
- Added a dedicated native macOS About sheet with explicit Version/Build, company, source, website, support and copyright information.
- Updated company identity across native About surfaces and the website to **WORKWORK.FUN LTD**; MojoWorks is described only as a creative sub-brand.
- Added **© 2026 Sylwester Mielniczuk, CEO of WORKWORK.FUN LTD** to native About/support surfaces and the public site.

### Stripe website support
- Embedded the configured official Stripe Buy Button directly on the Shar homepage in addition to `support.html`, using the supplied production Payment Link, Buy Button ID and publishable key at deploy time.
- Extended homepage deployment verification to require the rendered Stripe card on the public homepage.

### Release safety
- Added repository guards for shared macOS audio ownership, non-interrupting Grid/List rendering, top Support controls, WORKWORK.FUN LTD identity/copyright, and homepage Stripe rendering.
- Bumped iOS/macOS marketing/build version and Android versionName/versionCode to 2.1.6 / 20106.

All notable changes to Shar are recorded here.

## [2.1.5] - 2026-08-30

### Support checkout
- Connected **Support Shar** to the production Stripe Payment Link and official Stripe Buy Button generated for Shar.
- Replaced the support-page auto-redirect with an embedded Stripe checkout card plus a direct Payment Link fallback.
- Added `SFSafariViewController` presentation on iOS so Support Shar opens inside the native app experience without adding the Stripe iOS SDK or a new payment backend.
- Kept macOS and Android support actions on the stable Shar support URL, centralizing payment configuration.
- Added validation for the Payment Link, Buy Button ID and publishable key while keeping Stripe secret keys out of the repository.

### Release safety
- Added repository guards for the Stripe Buy Button placeholders, iOS Safari checkout wrapper, and v2.1.5 runtime signaling version.
- Bumped iOS/macOS marketing/build version and Android versionName/versionCode to 2.1.5 / 20105.

## [2.1.4] - 2026-08-30

### Fixed
- Made the connected-device launch step best-effort after a successful iOS install. If the iPhone locks between installation and `devicectl ... process launch`, the release now prints a warning and continues instead of failing the entire macOS/Android/server/GitHub/homepage pipeline.
- Preserved fatal behavior for actual iOS build, signing, installation, or explicit `--console` launch failures.

### Release safety
- Added repository verification that requires the non-fatal locked-device launch guard and rejects the old `exit 3` regression.
- Bumped iOS/macOS marketing/build version and Android versionName/versionCode to 2.1.4 / 20104.

## [2.1.3] - 2026-08-30

### Native client consistency
- Reworked the macOS main library to follow the iOS structure with an import `+` control, compact LAN Sharing strip, All/Images/Audio/Video/Docs/Other filtering, filtered-file count, and native Grid/List views.
- Moved macOS button-label configuration, Grid/List preference, file-size visibility, colour theme, developer toggle and sharing details into a right-side **Config** drawer opened by the cog.
- Added dedicated macOS grid cards and list rows while retaining native preview, inline audio, Remote Share, Finder reveal and delete actions.

### About and support
- Replaced the iOS About `LabeledContent` version row with explicit **Version** and **Build** rows so both values remain visible in the narrow Settings drawer.
- Added initial builder/About identity, Shar website, source-code and **Support Shar** actions to iOS and macOS; v2.1.6 later corrected the legal company identity to WORKWORK.FUN LTD.
- Added an Android **About Shar** dialog and **Support Shar** button with version/build and builder information.
- Added `homepage/support.html` as the stable client support endpoint. Deployment validates `SHAR_STRIPE_SUPPORT_URL` as a `https://buy.stripe.com/...` Payment Link and renders the support page to forward to Stripe without hard-coding payment identifiers throughout the native clients.
- Extended the private Shar release profile to persist the Stripe support URL and import compatible Rantlist support URL variables when available.

### Release safety
- Added repository guards for macOS Grid/List + media filters + cog Config, explicit iOS Version/Build display, cross-client About/Support links, support-page deployment, and the v2.1.3 signaling version.
- Bumped iOS/macOS marketing/build version and Android versionName/versionCode to 2.1.3 / 20103.

## [2.1.2] - 2026-08-30

### Fixed
- Replaced the macOS Remote Share action that started the local `:8080` LAN server and opened a browser with a fully native SwiftUI Secure Remote Share sheet.
- macOS now creates the secure Internet session directly from the selected native file, independently of the Wi-Fi Sharing switch.

### Native macOS Remote Share
- Added native PIN, locally generated QR code, secure URL, Copy link, macOS sharing-service picker, sender approval, transfer progress, retry/cancel and verified completion UI.
- Added an off-screen macOS WebKit WebRTC/Web Crypto engine using the same v2.1 AES-256-GCM, PBKDF2 PIN, approval and SHA-256 protocol as the native iOS sender. File bytes are supplied from the native file through the bounded chunk bridge; the localhost browser UI is not loaded.

### Release safety
- Added repository guards preventing macOS Remote Share from calling `webServer.start()` or opening `127.0.0.1:8080`.
- Added extraction and `node --check` validation for the JavaScript embedded in the native macOS Remote Share engine.
- Bumped iOS/macOS marketing/build version and Android versionName/versionCode to 2.1.2 / 20102.

## [2.1.1] - 2026-08-30

### Fixed
- Fixed the Android release compilation failure in `LocalHttpServer.java`: the v2.1 Base64URL helper used Java-illegal backslash escapes inside the embedded HTML text block. The shared browser implementation now avoids those escape-sensitive regular expressions entirely.
- Kept the Apple and Android embedded browser HTML byte-for-byte aligned after the fix.

### Release safety
- Repository verification now extracts the actual Android `WEB_PAGE` Java text block and compiles it in a minimal Java probe when `javac` is available. This catches illegal text-block escapes before Gradle, notarization, or deployment work is attempted.
- Bumped iOS marketing/build version and Android versionName/versionCode to 2.1.1 / 20101.

## [2.1.0] - 2026-08-30

### Security
- Added application-level **AES-256-GCM end-to-end encryption** for Remote Share file contents and file metadata. The sender generates a random 256-bit content key locally and places it only in the receiver URL fragment (`#share=…&key=…`); URL fragments are not sent in the HTTP request, and the signaling/TURN service never receives the content key.
- Added a separate mandatory 6-digit receiver PIN. The sender and receiver derive a PBKDF2-SHA256 proof locally; the signaling service compares only the derived verifier and applies per-share failure lockouts after repeated incorrect attempts.
- Added mandatory sender approval for secure Remote Share. A receiver that entered the correct PIN remains pending until the sender explicitly approves the device; receiver TURN credentials and WebRTC signaling credentials are not released before approval.
- Added streaming SHA-256 integrity verification for every transferred file. Completion is accepted only after the receiver decrypts the complete file, verifies its SHA-256 digest, and returns an encrypted completion acknowledgement containing the verified digest(s).
- Added private-metadata sessions: the signaling service sees item count and byte sizes needed for limits/completion, but secure v2.1 sessions do not publish the original file/folder names or MIME types before the encrypted data channel is established.
- Secure receiver links now keep both the share capability and content key in the URL fragment. New v2.1 QR codes are generated locally on the native sender so the key is never sent to the QR/signaling service.
- Added explicit rejection of plaintext/unprotected WebRTC data-channel payloads in the v2.1 receiver.

### Infrastructure hardening
- Disabled nginx access logging for `/api/shar/remote/v1/` so temporary share IDs are not written to the normal API access log.
- Hardened the dedicated Shar coturn service with loopback/private/link-local peer blocking plus per-user and total allocation quotas, reducing TURN abuse and SSRF-style relay targets.
- Kept runtime ICE fully on Shar-controlled STUN/TURN; Google STUN remains prohibited by repository verification.

### Release safety
- Added `scripts/test_remote_crypto.sh`, which validates the receiver SHA-256 implementation against known vectors, performs an AES-GCM round-trip, requires fragment-based key handling, and rejects any Google STUN runtime dependency.
- Expanded the signaling protocol smoke test to cover incorrect PIN rejection, PBKDF2 verifier authentication, pending receiver approval, host approval, delayed guest credential release, signaling, completion validation, and one-time rejoin rejection.
- The release pipeline now runs both signaling/auth and cryptographic Remote Share tests before native builds or server deployment.

### Changed
- Bumped iOS marketing/build version and Android versionName/versionCode to 2.1.0 / 20100.
- Secure Remote Share uses 48 KiB plaintext chunks before AES-GCM framing to keep WebRTC data-channel messages comfortably bounded after authentication-tag overhead.

## [2.0.8] - 2026-08-30

### Fixed
- Fixed the native iOS Remote Share sheet hanging indefinitely on **Creating temporary Internet share…**. The embedded WebRTC engine had a JavaScript syntax error in its `dc.onerror` callback, so the hidden engine failed to parse before it could create a session or report an error.
- Corrected the data-channel error callback and kept the v2.0.7 receiver-completion handshake unchanged.

### Privacy / infrastructure
- Removed `stun:stun.l.google.com:19302` from Shar's runtime ICE configuration. Shar now advertises its own coturn endpoint for STUN as well as TURN, so Remote Share does not contact Google STUN.

### Hardened
- Repository verification now extracts the actual JavaScript embedded in the native iOS `NativeRemoteShareCoordinator` and runs `node --check` on it, in addition to the browser sender, public receiver and signaling server syntax checks.
- The remote protocol smoke test now requires a Shar-hosted STUN URL and fails if any Google STUN URL reappears.

### Changed
- Bumped iOS marketing/build version and Android versionName/versionCode to 2.0.8 / 20008.

## [2.0.7] - 2026-08-30

### Fixed
- Fixed a completed Remote Share being overwritten by **Connection failed / Share not found or expired** after the file had already arrived. Receiver success is now a terminal state: later WebRTC disconnects, one-time session cleanup, signaling polling failures and expected 404s cannot replace a verified successful transfer.
- Added a receiver-to-sender `receiver-complete` data-channel acknowledgement after all expected bytes have been received and the final file size has been validated.
- The sender now shows **Finalizing with receiver…** and only transitions to **Transfer complete** after receiver acknowledgement or the signaling service confirms completion.
- Completed one-time signaling sessions remain readable for a short 60-second completion grace period so sender/receiver finalization can settle, while a second receiver is still rejected.

### Polished
- Receiver completion now shows **Transfer complete ✓**, a full progress bar, a disabled **Received ✓** action, and clear save/download guidance instead of a contradictory red error state.
- Added final whole-transfer byte-count validation in addition to the existing per-file size checks.

### Hardened
- Extended the remote protocol smoke test to verify the completion grace state and confirm that completed one-time shares reject another receiver.
- Added repository guards for terminal receiver success and the explicit `receiver-complete` handshake.

### Changed
- Bumped iOS marketing/build version and Android versionName/versionCode to 2.0.7 / 20007.

## [2.0.6] - 2026-08-30

### Fixed
- Fixed the native iOS **Share link** button in Remote Share. It now explicitly presents Apple's `UIActivityViewController` with the generated HTTPS receiver URL instead of relying on SwiftUI `ShareLink`, which was not presenting an activity sheet in the live nested Remote Share presentation.
- The receiver link can now be sent directly through Messages, Mail, AirDrop and installed third-party messaging/share apps exposed by iOS.
- **Copy link** remains a separate clipboard-only action.

### Hardened
- Added repository guards requiring the native iOS activity-controller share path and preventing a regression back to `ShareLink` inside `RemoteShareSheet`.

### Changed
- Bumped iOS marketing/build version and Android versionName/versionCode to 2.0.6 / 20006.
- Remote signaling, TURN, receiver protocol and native WebRTC transfer engine remain unchanged from v2.0.5.

## [2.0.5] - 2026-08-30

### Fixed
- Fixed a first-start race in the Ubuntu Remote Share deployment where `systemctl restart shar-remote.service` could return before Node had bound `127.0.0.1:8787`, causing an immediate `curl` connection-refused error and unnecessary nginx rollback.
- Prevented the existing `shar-remote.path` watcher from racing the bootstrap while `server.js` is being replaced; the path watcher is stopped before source installation and re-enabled only after the signaling service is healthy.
- Remote deployment now waits for the signaling service to become genuinely ready instead of probing port 8787 immediately.

### Diagnostics / hardening
- Added preflight `node --check` validation of the installed signaling source, environment-file checks, bounded readiness retries, and automatic `systemctl status`, `journalctl`, socket and source diagnostics when startup fails.
- The fast-update path now verifies localhost signaling readiness after replacing `server.js` before deciding whether nginx/public-route repair can proceed.
- Nginx changes are only rolled back after the service has failed the full readiness window, rather than on a transient startup race.

### Changed
- Bumped iOS marketing/build version and Android versionName/versionCode to 2.0.5 / 20005.
- Remote Share protocol, TURN ports and native iOS Remote Share UI remain unchanged from v2.0.4.

## [2.0.4] - 2026-08-30

### Fixed
- Fixed the iOS Remote Share UX being implemented as a visible WKWebView of Shar's local `:8080` browser interface. Tapping **Remote** on a native iOS file card now stays in the native SwiftUI client and no longer starts or navigates to the LAN web server.
- Removed the redundant **Choose files / Choose folder** controls when a specific iOS file has already been selected for remote sharing.
- Remote-share failures now show a native error state with **Retry** instead of leaving an empty/dead browser form on screen.

### Added
- Added a native iOS Remote Share sheet with QR code, copyable HTTPS receiver link, iOS Share Sheet integration, expiry/status display, transfer progress, connection state, retry and cancel controls.
- Added an internal off-screen WebRTC engine bridged directly to the selected native file in 64 KiB chunks. It uses the public Shar signaling API and its STUN/TURN ICE configuration without requiring the local Wi-Fi Sharing switch or `192.168.x.x:8080` server to be enabled.
- Added release guards that reject regressions where the iOS Remote action starts the LAN server or reintroduces the visible local-browser Remote Share view.

### Changed
- Bumped iOS marketing/build version and Android versionName/versionCode to 2.0.4 / 20004.
- LAN Sharing and Remote Share are now explicitly separate iOS paths: the Sharing switch controls only the local HTTP server, while Remote Share operates over the Internet from the native app.

## [2.0.3] - 2026-08-30

### Fixed
- Fixed a false-negative nginx verification on hosts where the production HTTPS listener is not authoritative on `127.0.0.1`; Remote Share no longer rolls back a potentially correct apex configuration solely because a forced loopback/SNI probe returns 404.
- Nginx repair now uses `nginx -T` as the loaded-configuration source of truth and installs the Shar API include into every loaded TLS server block with an exact `mojoworks.xyz` `server_name` token, covering duplicate/legacy apex blocks without touching subdomains.
- Public API verification now uses the real HTTPS endpoint with cache-busting retries and validates Shar service/version JSON before release publication. Failed verification prints response headers/body, loaded Shar nginx includes and DNS addresses before restoring all changed nginx files.

### Changed
- Bumped iOS marketing/build version and Android versionName/versionCode to 2.0.3 / 20003.
- Kept the signaling service, TURN ports/protocol and Remote Share wire format unchanged from v2.0.x.

## [2.0.2] - 2026-08-30

### Fixed
- Fixed the first live Remote Share nginx bootstrap selecting `drive.mojoworks.xyz` because a word-boundary domain regex treated the apex `mojoworks.xyz` as a substring match. nginx selection now requires an exact `server_name` token and prefers the HTTPS/TLS block.
- Fixed subsequent deployments skipping nginx repair merely because the local `shar-remote.service` was healthy; the fast path now also requires the public API to be healthy and running the current Shar version.
- Removed stale Shar nginx includes from non-target vhosts left by the v2.0.1 bootstrap and added exact local HTTPS/SNI verification before external public verification.

### Hardened
- Added multi-file nginx backup/rollback for every vhost touched by stale-route cleanup or exact-route insertion.
- Added repository checks for exact-host nginx selection, public-route repair behavior and remote signaling version parity.

### Changed
- Bumped iOS marketing/build version and Android versionName/versionCode to 2.0.2 / 20002.

## [2.0.1] - 2026-08-30

### Fixed
- Fixed the Android release compilation failure in v2.0.0 where `MainActivity` referenced `BuildConfig.VERSION_NAME` and `BuildConfig.VERSION_CODE` even though this Gradle configuration did not expose the generated `BuildConfig` class.
- Android now reads the installed app version/build from `PackageManager` / `PackageInfo`, so the visible Settings/footer version does not depend on Gradle-generated Java constants.
- Preserved all v2.0.0 Remote Share, signaling, TURN bootstrap, macOS notarization and iOS behavior unchanged.

### Hardened
- Added a repository regression check that rejects Android source references to `BuildConfig.VERSION_NAME` / `BuildConfig.VERSION_CODE` and requires the package-metadata version helper.

### Changed
- Bumped iOS marketing/build version and Android versionName/versionCode to 2.0.1 / 20001.

## [2.0.0] - 2026-08-29

### Hardened after implementation review
- Added a local signaling protocol smoke test to the release pipeline before any remote host is modified.
- Added signaling session-capacity and per-IP creation limits to reduce abuse.
- Added an iOS local-network-only ATS exception so the native Remote Share sheet can load Shar's own `127.0.0.1` sender UI without allowing arbitrary cleartext traffic.

### Added
- Added **Remote Share** over WebRTC DataChannel for transfers between different Internet networks. Shar now creates a temporary one-receiver HTTPS link plus QR code, negotiates a direct peer-to-peer connection when possible, and falls back to a dedicated TURN relay when NAT/firewalls block direct connectivity.
- Added remote sharing from each Shar file card in the shared browser UI, plus direct local **Choose files** and **Choose folder** sources with relative folder paths preserved in the transfer manifest.
- Added native iOS/iPadOS remote-share sheets using an in-app WKWebView so the local Shar server remains foregrounded during a transfer.
- Added native macOS and Android **Remote** actions which open the same local WebRTC sender workflow.
- Added the public receiver at `https://mojoworks.xyz/labs/shar/receive.html`. Chromium desktop receivers can stream directly into a selected file/directory through the File System Access API; other browsers use a bounded in-memory fallback and expose explicit Save links.
- Added a dependency-free Node.js signaling service with expiring capability tokens, one active receiver, bounded signaling queues, rate limiting, no file storage, and short-lived TURN REST credentials.
- Added a dedicated Shar coturn service on port 3479 with a narrow relay range, separate from any existing Rantlist TURN configuration.
- Added `scripts/check_remote_share.sh`, `scripts/deploy_remote_share.sh`, and `scripts/remote_bootstrap.sh` to preflight, install/update and verify the Ubuntu/Debian signaling + TURN infrastructure automatically.
- Added safe nginx integration with a generated snippet, pre-change backup, `nginx -t`, and automatic rollback if validation fails.
- Documented the only external network prerequisite the Ubuntu bootstrap cannot control: provider-level firewall access for the dedicated TURN/relay ports.
- Added remote service systemd hardening and a path-triggered restart so later ZIP deployments can update `remote/server.js` without ongoing root access.

### Changed
- The foreground watcher now supports an intentional same-version retry when a failed release ZIP is touched/re-downloaded, so one-time server bootstrap fixes do not require an artificial version bump.
- The release pipeline now deploys/verifies remote WebRTC signaling + TURN after native builds and before publishing the release. Missing Ubuntu packages are installed only during first-time bootstrap.
- Homepage deployment now includes and verifies `receive.html`, and the public homepage documents remote WebRTC sharing.
- Bumped iOS marketing/build version and Android versionName/versionCode to 2.0.0 / 20000.

### Security
- Remote links are random capability URLs, expire after 30 minutes by default, allow one receiver by default, and can be revoked by the sender.
- Permanent TURN credentials are never shipped in the app/repository; the server creates short-lived HMAC credentials from a root-owned secret.
- Signaling stores only temporary session metadata/SDP/ICE messages in memory; file bytes are transferred only through the encrypted WebRTC data channel (directly or via TURN).

## [1.7.6] - 2026-08-29

### Added
- Added an optional **ⓘ Developer updates** button to the iOS/iPadOS toolbar, macOS client, Android client, and shared browser UI. It is hidden by default and can be enabled from Settings.
- Added a compact recent-development feed with short summaries of the latest Shar releases instead of exposing the full changelog in the app.
- Added a persistent browser preference for the developer-info control, so enabling or hiding it survives reloads on that browser.

### Changed
- Bumped iOS marketing/build version and Android versionName/versionCode to 1.7.6 / 10706.

## [1.7.5] - 2026-08-29

### Fixed
- Fixed the macOS distribution build failure introduced by iOS background-audio support in v1.7.4.
- Guarded all `AVAudioSession` activation and interruption handling with iOS-only conditional compilation so the shared media code compiles on macOS.
- Preserved iOS background/lock-screen audio playback and interruption handling while leaving macOS playback behavior unchanged.

### Changed
- Bumped iOS marketing/build version and Android versionName/versionCode to 1.7.5 / 10705.

## [1.7.4] - 2026-08-29

### Added
- Added iOS/iPadOS background audio playback so an audio track can continue while Shar is minimized or while the screen is locked.
- Added the iOS `audio` background mode and an `AVAudioSession` playback category for lock-screen/background media playback.
- Added audio-interruption handling so calls/Siri can pause inline playback and it can resume when iOS reports that resumption is appropriate.

### Changed
- Video preview playback now pauses when Shar leaves the foreground; background playback is intentionally limited to audio media.
- Bumped iOS marketing/build version and Android versionName/versionCode to 1.7.4 / 10704.

## [1.7.3] - 2026-08-29

### Changed
- Image previews on iOS/iPadOS now default to fit the complete image inside the available preview area instead of using a scrollable minimum-size layout that could appear cropped or zoomed.
- Browser image/video previews now explicitly use `object-fit: contain` so the complete asset stays visible inside the modal viewer.
- Cellular network status now explains that direct inbound sharing is normally blocked by carrier NAT/firewalls rather than implying that a carrier public IP is a usable Shar endpoint.
- Bumped iOS marketing/build version and Android versionName/versionCode to 1.7.3 / 10703.

### Added
- Added a persistent bottom-right **X** close button to the iOS/iPadOS media preview. Swipe/gesture dismissal and previous/next gallery navigation remain available.

## [1.7.2] - 2026-08-29

### Added
- Expanded the always-visible iOS/iPadOS **+** control into a native add menu with **Photos & Videos**, **Record Video**, and **Files**.
- Added multi-select Photos library import for both still images and videos using the native iOS picker. Imported assets are copied directly into Shar's shared library and appear immediately in the app/browser file grid.
- Added native full-screen video capture from the iPhone/iPad camera. Finished recordings are stored in Shar automatically with timestamped `.mov` filenames and become available to browser sharing immediately.
- Added iOS camera, microphone, and photo-library privacy descriptions required for capture/import workflows.

### Changed
- Updated the empty-library guidance to explain all three local import paths from the **+** button.
- Bumped iOS marketing/build version and Android versionName/versionCode to 1.7.2 / 10702.

## [1.7.1] - 2026-08-29

### Added
- Added an always-visible circular **+** button in the iOS/iPadOS top-left toolbar. It opens the native Files picker, supports multiple selection and copies chosen files into Shar's local shared library immediately.
- Added the installed Shar version/build directly beneath the iOS Settings title, while retaining the About version row.

### Changed
- Standardized the user-facing product name to **Shar** across the iOS splash/app label, macOS header/display name, Android launcher/header and browser page title. Internal project paths and build artifact names remain `LocalWebShare` for pipeline compatibility.
- Moved the iOS Settings drawer content below the safe area/notch and added extra top spacing so its title no longer collides with iPhone sensor housing/status UI.
- Updated the empty iOS library guidance to explain both local **+** imports and browser uploads.
- Bumped iOS marketing/build version and Android versionName/versionCode to 1.7.1 / 10701.

## [1.7.0] - 2026-08-29

### Added
- Added adaptive browser media-card density with a live Thumbnail / card size slider from 120–320 px. Smaller cards automatically create more grid columns; narrow browser windows retain at least two columns.
- Added a browser-wide Text size slider from 75–125%.
- Added built-in Minimal, Balanced and Large layout presets plus a browser-local “My saved preset” slot that stores button style, layout, theme, thumbnail size and text size.
- Added a one-click “Use minimal” reset in the settings drawer.

### Changed
- Minimal is now the default browser layout: icon-only action buttons, 150 px adaptive cards, 90% typography, tighter spacing and a shorter upload drop area.
- The browser grid now uses adaptive card sizing instead of a fixed 220 px minimum, allowing substantially denser libraries on desktop and tablets.
- The browser settings drawer now exposes density controls alongside button labels, layout and colour theme.
- Bumped iOS marketing/build version and Android versionName/versionCode to 1.7.0 / 10700.

### Fixed
- Fixed duplicated action controls where an SVG icon and its fallback glyph were rendered at the same time. Fallback glyphs now appear only if the corresponding SVG fails to load.

## [1.6.1] - 2026-08-29

### Fixed
- Fixed the macOS distribution build failure caused by `ContentUnavailableView`, which is only available on macOS 14 while Shar intentionally targets macOS 13.
- Replaced all macOS `ContentUnavailableView` usage with a native SwiftUI empty-state component compatible with macOS 13.
- Fixed the empty gallery and unsupported-preview states to use the same macOS 13-compatible component.

### Changed
- Bumped iOS marketing/build version and Android versionName/versionCode to 1.6.1 / 10601.
- Updated README release/version examples and documented the macOS 13 deployment target compatibility fix.


## [1.6.0] - 2026-08-29

### Added
- Added a fully automated multi-platform release pipeline triggered by the existing foreground ZIP watcher.
- Added signed/notarized universal2 macOS distribution builds producing both DMG and ZIP artifacts.
- Added persistent Android release signing stored outside the repository, with the signing password stored in macOS Keychain.
- Added signed Android APK and AAB release builds plus SHA-256 checksum manifests.
- Added generic iOS/iPadOS Release compilation validation so the pipeline can validate iOS even when no device is connected.
- Added optional automatic tethered iPhone/iPad install/launch when a development device is connected; absence of a device no longer blocks macOS/Android/web publication.
- Added GitHub Release publication to `sylwesterdigital/shar` with release notes and native release artifacts.
- Added a Shar product homepage source under `homepage/` with live links to the exact published GitHub release assets.
- Added automated deployment of the homepage to `/var/www/mojoworks/labs/shar` and verification of `https://mojoworks.xyz/labs/shar/`.
- Added a private Shar SSH deployment profile which bootstraps automatically from the existing Rantlist release profile when available.
- Added release credential checks for macOS Developer ID/notarization, Android signing, iOS/Xcode and homepage SSH access.

### Changed
- `scripts/deploy.sh` is now a thin foreground entry point for the complete `release_and_deploy.sh` workflow.
- `scripts/build_all.sh` now creates distribution-quality macOS and Android artifacts, validates iOS Release compilation, and installs iOS on a connected development device when available.
- The release workflow now commits/pushes source before publishing the matching Git tag/GitHub Release, then deploys the homepage only after release assets are verified.
- macOS public distribution now uses the existing WORKWORK.FUN Developer ID fingerprint and notarization profile used by the established release host, both overrideable by environment variables.
- Android versionName/versionCode and iOS marketing/build version bumped to 1.6.0 / 10600.

### Homepage
- Added macOS DMG and ZIP download buttons.
- Added Android APK and AAB download buttons.
- Added iOS/Xcode source link to the exact GitHub release.
- Added published version/tag, release notes and source links.

## [1.5.0] - 2026-08-29

### Added
- Added an iOS/iPadOS launch screen using the `SharLogo` asset plus an app-level startup splash with the shared Shar logo and app name.
- Added live startup/network status detection for Wi-Fi, cellular/mobile data, wired/other network and offline states using `NWPathMonitor`.
- Added a compact top sharing strip on iPhone/iPad with the Sharing toggle, current local address, Copy Address and Share Address controls in one row.
- Added a right-side settings drawer opened from the top-right gear icon.
- Added persisted colour themes: System, Ocean, Forest, Sunset and Violet.
- Added persisted Grid/List file-layout selection, with Grid as the default.
- Added media filter chips for All, Images, Audio, Video, Documents and Other.
- Added optional Auto-start on Wi-Fi and Show file sizes settings.
- Added a shared iOS inline-audio playback controller so only one file-list audio item can play at once.
- Added browser media-type filter chips, Grid/List selection and a gear-driven settings drawer.
- Added browser colour-theme selection with persisted preferences.
- Added global browser media exclusivity so starting any inline or preview audio/video pauses every other active player.

### Changed
- Removed the large Local Web Share heading/subheading from the browser UI so uploads and files start much higher on the page.
- Reworked the iPhone/iPad main screen from a tall `List`/section layout into a compact sharing bar + filters + media grid/list.
- Opening an iOS full media preview now stops any inline audio playback first.
- Browser gallery previous/next navigation now follows the currently selected media filter.
- iOS marketing/build version bumped to 1.5.0 / 10500.
- Android versionName/versionCode bumped to 1.5.0 / 10500 to keep the multi-platform release version aligned.

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
