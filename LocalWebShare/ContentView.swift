import AVFoundation
import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import WebKit
import CoreImage.CIFilterBuiltins

struct ContentView: View {
    @EnvironmentObject private var fileStore: FileStore
    @EnvironmentObject private var webServer: LocalWebServer
    @EnvironmentObject private var networkMonitor: NetworkStatusMonitor

    @AppStorage("actionLabelMode") private var actionLabelModeRaw = ActionLabelMode.compact.rawValue
    @AppStorage("fileViewMode") private var fileViewModeRaw = FileViewMode.grid.rawValue
    @AppStorage("mediaFilter") private var mediaFilterRaw = MediaFilter.all.rawValue
    @AppStorage("colorTheme") private var colorThemeRaw = AppColorTheme.ocean.rawValue
    @AppStorage("autoStartSharing") private var autoStartSharing = false
    @AppStorage("showFileSizes") private var showFileSizes = true
    @AppStorage("showDeveloperInfo") private var showDeveloperInfo = false

    @StateObject private var audioPlayback = SharedAudioPlaybackController()
    @State private var selectedFile: SharedFile?
    @State private var filePendingDelete: SharedFile?
    @State private var showingSettings = false
    @State private var copiedAddress = false
    @State private var showingFileImporter = false
    @State private var showingPhotoPicker = false
    @State private var showingVideoCamera = false
    @State private var showingDeveloperUpdates = false
    @State private var remoteShareFile: SharedFile?

    private var actionLabelMode: ActionLabelMode {
        ActionLabelMode(rawValue: actionLabelModeRaw) ?? .compact
    }

    private var fileViewMode: FileViewMode {
        FileViewMode(rawValue: fileViewModeRaw) ?? .grid
    }

    private var mediaFilter: MediaFilter {
        MediaFilter(rawValue: mediaFilterRaw) ?? .all
    }

    private var colorTheme: AppColorTheme {
        AppColorTheme(rawValue: colorThemeRaw) ?? .ocean
    }

    private var filteredFiles: [SharedFile] {
        fileStore.files.filter { mediaFilter.matches($0) }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            NavigationStack {
                VStack(spacing: 0) {
                    sharingStrip
                    Divider()
                    filterStrip
                    Divider()
                    filesContent
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button {
                                showingPhotoPicker = true
                            } label: {
                                Label("Photos & Videos", systemImage: "photo.on.rectangle.angled")
                            }

                            Button {
                                showingVideoCamera = true
                            } label: {
                                Label("Record Video", systemImage: "video.badge.plus")
                            }
                            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                            Button {
                                showingFileImporter = true
                            } label: {
                                Label("Files", systemImage: "folder")
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(colorTheme.accent, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add photos, videos, camera recordings or files")
                    }
                    ToolbarItem(placement: .principal) {
                        Text("Files")
                            .font(.headline)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 12) {
                            if showDeveloperInfo {
                                Button {
                                    showingDeveloperUpdates = true
                                } label: {
                                    Image(systemName: "info.circle.fill")
                                }
                                .accessibilityLabel("Developer updates")
                            }

                            Button {
                                withAnimation(.snappy(duration: 0.25)) { showingSettings = true }
                            } label: {
                                Image(systemName: "gearshape.fill")
                            }
                            .accessibilityLabel("Settings")
                        }
                    }
                }
            }
            .tint(colorTheme.accent)
            .allowsHitTesting(!showingSettings)

            if showingSettings {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.25)) { showingSettings = false }
                    }
                    .transition(.opacity)

                settingsPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .sheet(item: $selectedFile) { file in
            MediaPlayerView(files: filteredFiles, initialFile: file) { deleted in
                fileStore.delete(deleted)
            }
            .tint(colorTheme.accent)
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                urls.forEach { fileStore.importFile(from: $0) }
            case .failure(let error):
                fileStore.lastError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingPhotoPicker) {
            PhotoVideoLibraryPicker(isPresented: $showingPhotoPicker) { url in
                fileStore.importFile(from: url)
            } onError: { message in
                fileStore.lastError = message
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showingVideoCamera) {
            VideoCameraPicker(isPresented: $showingVideoCamera) { url in
                fileStore.importFile(from: url)
            } onError: { message in
                fileStore.lastError = message
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingDeveloperUpdates) {
            DeveloperUpdatesView()
                .tint(colorTheme.accent)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $remoteShareFile) { file in
            RemoteShareSheet(file: file)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            filePendingDelete.map { "Delete \($0.name)?" } ?? "Delete file?",
            isPresented: Binding(
                get: { filePendingDelete != nil },
                set: { if !$0 { filePendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let filePendingDelete {
                    if audioPlayback.activeFileID == filePendingDelete.id { audioPlayback.stop() }
                    fileStore.delete(filePendingDelete)
                }
                filePendingDelete = nil
            }
            Button("Cancel", role: .cancel) { filePendingDelete = nil }
        }
        .alert("Error", isPresented: Binding(
            get: { fileStore.lastError != nil || webServer.lastError != nil },
            set: { isPresented in
                if !isPresented { fileStore.lastError = nil; webServer.lastError = nil }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(fileStore.lastError ?? webServer.lastError ?? "Unknown error")
        }
        .onAppear {
            fileStore.refresh()
            if autoStartSharing, networkMonitor.kind == .wifi, !webServer.isRunning {
                webServer.start()
            }
        }
        .onChange(of: networkMonitor.kind) { _, kind in
            if autoStartSharing, kind == .wifi, !webServer.isRunning {
                webServer.start()
            }
        }
    }

    private var sharingStrip: some View {
        HStack(spacing: 10) {
            Toggle("Sharing", isOn: Binding(
                get: { webServer.isRunning },
                set: { enabled in
                    enabled ? webServer.start() : webServer.stop()
                }
            ))
            .toggleStyle(.switch)
            .font(.subheadline.weight(.semibold))
            .fixedSize()

            Text(webServer.isRunning ? displayAddress : networkMonitor.kind.title)
                .font(.caption.monospaced())
                .foregroundStyle(webServer.isRunning ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                UIPasteboard.general.string = webServer.shareURL
                copiedAddress = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copiedAddress = false
                }
            } label: {
                Image(systemName: copiedAddress ? "checkmark" : "doc.on.doc")
            }
            .disabled(!webServer.isRunning)
            .accessibilityLabel("Copy sharing address")

            ShareLink(item: webServer.shareURL) {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(!webServer.isRunning)
            .accessibilityLabel("Share sharing address")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(colorTheme.accent.opacity(0.075))
    }

    private var filterStrip: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(MediaFilter.allCases) { filter in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                mediaFilterRaw = filter.rawValue
                            }
                        } label: {
                            Label(filter.title, systemImage: filter.systemImage)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    mediaFilter == filter ? colorTheme.accent.opacity(0.18) : Color(uiColor: .secondarySystemGroupedBackground),
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule()
                                        .stroke(mediaFilter == filter ? colorTheme.accent.opacity(0.55) : Color.secondary.opacity(0.16), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 12)
            }

            Text("\(filteredFiles.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.trailing, 12)
        }
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder
    private var filesContent: some View {
        if fileStore.files.isEmpty {
            ContentUnavailableView(
                "No Files Yet",
                systemImage: "folder",
                description: Text("Tap + to choose Photos & Videos, record a video, or import Files. Turn on Sharing to upload from another device.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredFiles.isEmpty {
            ContentUnavailableView(
                "No \(mediaFilter.title)",
                systemImage: mediaFilter.systemImage,
                description: Text("Choose another media filter.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch fileViewMode {
            case .grid:
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(filteredFiles) { file in
                            MediaGridCard(
                                file: file,
                                actionLabelMode: actionLabelMode,
                                showFileSize: showFileSizes,
                                audioPlayback: audioPlayback,
                                onPreview: { openPreview(file) },
                                onRemoteShare: { openRemoteShare(file) },
                                onDelete: { filePendingDelete = file }
                            )
                        }
                    }
                    .padding(10)
                }
                .refreshable { fileStore.refresh() }
            case .list:
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredFiles) { file in
                            MediaListRow(
                                file: file,
                                actionLabelMode: actionLabelMode,
                                showFileSize: showFileSizes,
                                audioPlayback: audioPlayback,
                                onPreview: { openPreview(file) },
                                onRemoteShare: { openRemoteShare(file) },
                                onDelete: { filePendingDelete = file }
                            )
                        }
                    }
                    .padding(10)
                }
                .refreshable { fileStore.refresh() }
            }
        }
    }

    private var settingsPanel: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Spacer()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Settings", systemImage: "gearshape.fill")
                                    .font(.title3.bold())
                                Text("Shar · v\(appVersion)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                withAnimation(.snappy(duration: 0.25)) { showingSettings = false }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        settingsSection("Buttons") {
                            Picker("Button labels", selection: $actionLabelModeRaw) {
                                ForEach(ActionLabelMode.allCases) { mode in
                                    Text(mode.title).tag(mode.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        settingsSection("File layout") {
                            Picker("View", selection: $fileViewModeRaw) {
                                ForEach(FileViewMode.allCases) { mode in
                                    Label(mode.title, systemImage: mode.systemImage).tag(mode.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            Toggle("Show file sizes", isOn: $showFileSizes)
                        }

                        settingsSection("Colour theme") {
                            VStack(spacing: 8) {
                                ForEach(AppColorTheme.allCases) { theme in
                                    Button {
                                        colorThemeRaw = theme.rawValue
                                    } label: {
                                        HStack {
                                            Circle()
                                                .fill(theme.accent)
                                                .frame(width: 18, height: 18)
                                            Text(theme.title)
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            if colorTheme == theme {
                                                Image(systemName: "checkmark")
                                                    .foregroundStyle(theme.accent)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        settingsSection("Developer") {
                            Toggle("Show ⓘ updates button", isOn: $showDeveloperInfo)
                            Text("Hidden by default. When enabled, the info button appears beside Settings and shows a short list of recent Shar development changes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        settingsSection("Sharing") {
                            Toggle("Auto-start on Wi-Fi", isOn: $autoStartSharing)
                            HStack {
                                Image(systemName: networkMonitor.kind.systemImage)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(networkMonitor.kind.title)
                                    Text(networkMonitor.kind.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if webServer.isRunning {
                                Text(webServer.shareURL)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }

                        settingsSection("About") {
                            LabeledContent("Version", value: appVersion)
                            Text("Keep the app in the foreground while transferring large files. Local browser sharing requires a reachable local network.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 20)
                }
                .frame(width: min(350, proxy.size.width * 0.88))
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)
                .shadow(radius: 24, x: -8)
            }
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func openPreview(_ file: SharedFile) {
        audioPlayback.stop()
        selectedFile = file
    }

    private func openRemoteShare(_ file: SharedFile) {
        audioPlayback.stop()
        remoteShareFile = file
    }

    private var displayAddress: String {
        webServer.shareURL.replacingOccurrences(of: "http://", with: "")
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}


private struct DeveloperUpdate: Identifiable {
    let version: String
    let title: String
    let summary: String
    var id: String { version }
}

private let recentDeveloperUpdates: [DeveloperUpdate] = [
    .init(version: "2.1.1", title: "Android secure-share build fix", summary: "Fixed the Android embedded browser Base64URL helper and added a Java text-block compile guard to release verification."),
    .init(version: "2.1.0", title: "Secure Remote Share", summary: "Added AES-256-GCM content encryption, separate PIN verification, sender approval, SHA-256 integrity checks, private metadata mode, and hardened TURN/API logging."),
    .init(version: "2.0.8", title: "Remote sender startup fix", summary: "Fixed the native iOS WebRTC engine parse regression and removed Google STUN from the runtime ICE path."),
    .init(version: "2.0.7", title: "Remote completion handshake", summary: "Made successful remote downloads terminal, added receiver confirmation back to the sender, and prevented expected session cleanup from becoming a false failure."),
    .init(version: "2.0.6", title: "Native link sharing", summary: "Fixed the iPhone Remote Share button to open the native iOS share sheet so receiver links can be sent directly through Messages, Mail, AirDrop and installed messaging apps."),
    .init(version: "2.0.5", title: "Remote service readiness", summary: "Fixed the signaling-service startup race and added systemd readiness diagnostics before nginx/public-route validation."),
    .init(version: "2.0.4", title: "Native iPhone Remote Share", summary: "Remote sharing now starts directly from the native iOS file card and shows a native QR/link transfer sheet without opening the local browser UI."),
    .init(version: "2.0.3", title: "Public route verification", summary: "Made the real public HTTPS API authoritative and hardened nginx repair for duplicate or address-bound apex vhosts."),
    .init(version: "2.0.2", title: "Remote routing repair", summary: "Fixed exact mojoworks.xyz API routing and automatic repair when signaling is healthy locally but public sharing returns 404."),
    .init(version: "2.0.1", title: "Android release fix", summary: "Restored Android release compilation and made its visible version read from package metadata."),
    .init(version: "2.0.0", title: "Remote WebRTC sharing", summary: "Added expiring QR/link shares, P2P data channels, TURN fallback, and automated signaling/TURN deployment."),
    .init(version: "1.7.6", title: "Optional developer info", summary: "Added the hidden-by-default ⓘ updates panel and Settings toggle."),
    .init(version: "1.7.5", title: "Cross-platform audio fix", summary: "Kept iOS background audio while restoring the macOS release build."),
    .init(version: "1.7.4", title: "Background audio", summary: "Audio can continue with Shar minimized or the iPhone screen locked."),
    .init(version: "1.7.3", title: "Better preview", summary: "Images fit the viewer and previews gained a persistent X close control."),
    .init(version: "1.7.2", title: "More ways to add", summary: "Added Photos & Videos, camera recording, and Files from the + menu."),
    .init(version: "1.7.1", title: "Shar identity", summary: "Renamed the visible product to Shar and added the persistent iOS + importer.")
]

private struct DeveloperUpdatesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(recentDeveloperUpdates) { update in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("v\(update.version)")
                            .font(.subheadline.monospaced().weight(.bold))
                        Text(update.title)
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(update.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 3)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Developer updates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Close developer updates")
                }
            }
        }
    }
}

private struct MediaGridCard: View {
    let file: SharedFile
    let actionLabelMode: ActionLabelMode
    let showFileSize: Bool
    @ObservedObject var audioPlayback: SharedAudioPlaybackController
    let onPreview: () -> Void
    let onRemoteShare: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onPreview) {
                ThumbnailView(file: file, size: CGSize(width: 172, height: 118))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if file.mediaKind == .audio { AudioMetadataLine(file: file) }
                HStack(spacing: 5) {
                    Text(file.typeLabel)
                    if showFileSize {
                        Text("•")
                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if file.mediaKind == .audio {
                Button {
                    audioPlayback.toggle(file)
                } label: {
                    Label(
                        audioPlayback.isPlaying(file) ? "Pause" : "Play",
                        systemImage: audioPlayback.isPlaying(file) ? "pause.fill" : "play.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                Button(action: onPreview) {
                    ActionLabel(full: "Preview", short: "View", systemImage: "eye", mode: actionLabelMode)
                }
                ShareLink(item: file.url) {
                    ActionLabel(full: "Share", short: "Share", systemImage: "square.and.arrow.up", mode: actionLabelMode)
                }
                Button(action: onRemoteShare) {
                    ActionLabel(full: "Remote", short: "Remote", systemImage: "network", mode: actionLabelMode)
                }
                Button(role: .destructive, action: onDelete) {
                    ActionLabel(full: "Delete", short: "Del", systemImage: "trash", mode: actionLabelMode)
                }
            }
            .font(.caption2)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(9)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            Button(action: onPreview) { Label("Preview", systemImage: "eye") }
            ShareLink(item: file.url) { Label("Share", systemImage: "square.and.arrow.up") }
            Button(action: onRemoteShare) { Label("Remote share", systemImage: "network") }
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
    }
}

private struct MediaListRow: View {
    let file: SharedFile
    let actionLabelMode: ActionLabelMode
    let showFileSize: Bool
    @ObservedObject var audioPlayback: SharedAudioPlaybackController
    let onPreview: () -> Void
    let onRemoteShare: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPreview) {
                ThumbnailView(file: file, size: CGSize(width: 64, height: 64))
            }
            .buttonStyle(.plain)

            Button(action: onPreview) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.name)
                        .foregroundStyle(.primary)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if file.mediaKind == .audio { AudioMetadataLine(file: file) }
                    HStack(spacing: 5) {
                        Text(file.typeLabel)
                        if showFileSize {
                            Text("•")
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if file.mediaKind == .audio {
                Button { audioPlayback.toggle(file) } label: {
                    Image(systemName: audioPlayback.isPlaying(file) ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(audioPlayback.isPlaying(file) ? "Pause \(file.name)" : "Play \(file.name)")
            }

            Menu {
                Button(action: onPreview) { Label("Preview", systemImage: "eye") }
                ShareLink(item: file.url) { Label("Share", systemImage: "square.and.arrow.up") }
                Button(action: onRemoteShare) { Label("Remote share", systemImage: "network") }
                Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct RemoteShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: SharedFile
    @StateObject private var remote: NativeRemoteShareCoordinator
    @State private var showingSystemShareSheet = false

    init(file: SharedFile) {
        self.file = file
        _remote = StateObject(wrappedValue: NativeRemoteShareCoordinator(file: file))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 5) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.tint)
                        Text(file.name)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    statusCard

                    if !remote.pinCode.isEmpty {
                        securityCard
                    }

                    if remote.approvalPending {
                        approvalCard
                    }

                    if let receiverURL = remote.receiverURL {
                        qrCard(receiverURL)
                    }

                    if remote.progress > 0 || remote.isTransferring {
                        VStack(alignment: .leading, spacing: 7) {
                            ProgressView(value: remote.progress)
                            HStack {
                                Text(remote.progressLabel)
                                Spacer()
                                Text("\(Int((remote.progress * 100).rounded()))%")
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }

                    if remote.errorMessage != nil {
                        Button {
                            remote.retry()
                        } label: {
                            Label("Retry secure share", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if remote.receiverURL != nil || remote.isWorking {
                        Button(role: .destructive) {
                            remote.cancel()
                            dismiss()
                        } label: {
                            Label("Cancel share", systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("Remote Share is independent of the local Wi-Fi Sharing switch. Keep Shar open until the transfer finishes. Shar 2.1 encrypts file contents and metadata with a separate AES-256-GCM key stored only in the shared URL fragment; the signaling/TURN service never receives that key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Secure Remote Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        remote.cancel()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Close remote share")
                }
            }
            .background {
                NativeRemoteEngineView(coordinator: remote)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .task { remote.start() }
            .sheet(isPresented: $showingSystemShareSheet) {
                if let receiverURL = remote.receiverURL {
                    NativeSystemShareSheet(activityItems: [receiverURL])
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
        }
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: remote.statusSymbol)
                .foregroundStyle(remote.errorMessage == nil ? Color.accentColor : Color.red)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(remote.status)
                    .font(.subheadline.weight(.semibold))
                if let detail = remote.errorMessage {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let expires = remote.expiresAt {
                    Text("Link expires \(expires, style: .relative).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var securityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Security", systemImage: "checkmark.shield.fill")
                .font(.subheadline.weight(.semibold))
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Receiver PIN")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(remote.formattedPIN)
                        .font(.title2.monospacedDigit().weight(.bold))
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = remote.pinCode
                    remote.markPinCopied()
                } label: {
                    Label(remote.didCopyPIN ? "Copied" : "Copy PIN", systemImage: remote.didCopyPIN ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
            Divider()
            Label("AES-256-GCM end-to-end content encryption", systemImage: "lock.fill")
            Label("Encryption key never sent to Shar servers", systemImage: "key.fill")
            Label("Sender approval required before transfer", systemImage: "person.badge.shield.checkmark")
            Label("SHA-256 verified before completion", systemImage: "checkmark.seal.fill")
            Label("One receiver · 30 minute expiry", systemImage: "timer")
            Text("Send the PIN separately from the link when practical.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var approvalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Receiver requests access", systemImage: "person.crop.circle.badge.questionmark")
                .font(.subheadline.weight(.semibold))
            Text("A device entered the correct PIN. Approve it before Shar releases the WebRTC/TURN connection credentials.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(role: .destructive) {
                    remote.resolveApproval(approved: false)
                } label: {
                    Label("Reject", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    remote.resolveApproval(approved: true)
                } label: {
                    Label("Approve", systemImage: "checkmark.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func qrCard(_ url: URL) -> some View {
        VStack(spacing: 13) {
            if let image = NativeRemoteShareQR.image(for: url.absoluteString) {
                image
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            Text(url.absoluteString)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.url = url
                    remote.markCopied()
                } label: {
                    Label(remote.didCopy ? "Copied" : "Copy link", systemImage: remote.didCopy ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    showingSystemShareSheet = true
                } label: {
                    Label("Share link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Share secure remote link with another app")
            }
            Text("The link contains the 256-bit encryption key in its URL fragment. Shar's web server never receives that fragment. The separate PIN is not included in the link.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct NativeSystemShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private enum NativeRemoteShareQR {
    static func image(for string: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 9, y: 9)) else { return nil }
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return Image(uiImage: UIImage(cgImage: cgImage))
    }
}

private struct NativeRemoteEngineView: UIViewRepresentable {
    @ObservedObject var coordinator: NativeRemoteShareCoordinator

    func makeUIView(context: Context) -> WKWebView {
        coordinator.makeWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

private final class NativeRemoteShareCoordinator: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published private(set) var status = "Preparing secure remote share…"
    @Published private(set) var receiverURL: URL?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var progress: Double = 0
    @Published private(set) var transferred: Int64 = 0
    @Published private(set) var isTransferring = false
    @Published private(set) var isWorking = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var didCopy = false
    @Published private(set) var didCopyPIN = false
    @Published private(set) var pinCode = ""
    @Published private(set) var approvalPending = false

    private let file: SharedFile
    private weak var webView: WKWebView?
    private var started = false
    private var cancelled = false

    init(file: SharedFile) {
        self.file = file
        super.init()
    }

    var statusSymbol: String {
        if errorMessage != nil { return "exclamationmark.triangle.fill" }
        if progress >= 1 { return "checkmark.circle.fill" }
        if approvalPending { return "person.badge.shield.checkmark" }
        if receiverURL != nil { return "lock.shield.fill" }
        return "hourglass"
    }

    var formattedPIN: String {
        guard pinCode.count == 6 else { return pinCode }
        return "\(pinCode.prefix(3)) \(pinCode.suffix(3))"
    }

    var progressLabel: String {
        let sent = ByteCountFormatter.string(fromByteCount: transferred, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        return "\(sent) / \(total)"
    }

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "sharRemote")
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = false
        view.isOpaque = false
        view.backgroundColor = .clear
        webView = view
        DispatchQueue.main.async { [weak self] in self?.start() }
        return view
    }

    func start() {
        guard !started else { return }
        guard webView != nil else {
            status = "Preparing secure remote share…"
            return
        }
        started = true
        cancelled = false
        isWorking = true
        errorMessage = nil
        receiverURL = nil
        expiresAt = nil
        progress = 0
        transferred = 0
        isTransferring = false
        didCopy = false
        didCopyPIN = false
        pinCode = ""
        approvalPending = false
        status = "Creating end-to-end encrypted share…"
        loadEngine()
    }

    func retry() {
        cancel(deleteRemoteSession: true)
        started = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.start() }
    }

    func cancel() { cancel(deleteRemoteSession: true) }

    func markCopied() {
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.didCopy = false }
    }

    func markPinCopied() {
        didCopyPIN = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.didCopyPIN = false }
    }

    func resolveApproval(approved: Bool) {
        approvalPending = false
        webView?.callAsyncJavaScript(
            "window.sharNativeApprove && window.sharNativeApprove(approved)",
            arguments: ["approved": approved],
            in: nil,
            in: .page,
            completionHandler: { _ in }
        )
    }

    private func cancel(deleteRemoteSession: Bool) {
        cancelled = true
        isWorking = false
        isTransferring = false
        approvalPending = false
        if deleteRemoteSession {
            webView?.evaluateJavaScript("window.sharNativeCancel && window.sharNativeCancel()", completionHandler: nil)
        }
    }

    private func loadEngine() {
        guard let webView else {
            fail("Remote engine is not ready. Try again.")
            return
        }
        webView.loadHTMLString(engineHTML, baseURL: URL(string: "https://mojoworks.xyz/labs/shar/")!)
    }

    private var engineHTML: String {
        let metadata: [String: Any] = [
            "name": file.name,
            "path": file.name,
            "size": file.size,
            "mime": mimeType(for: file)
        ]
        let data = try! JSONSerialization.data(withJSONObject: metadata)
        let json = String(data: data, encoding: .utf8)!
        return """
        <!doctype html><meta charset="utf-8"><script>
        'use strict';
        const FILE=\(json);
        const API='https://mojoworks.xyz/api/shar/remote/v1';
        const RECEIVE='https://mojoworks.xyz/labs/shar/receive.html';
        const PIN_ITERATIONS=150000;
        let session=null,pc=null,dc=null,signalSeq=0,pollTimer=null,pending=[],sent=0,cancelled=false,finished=false,receiverAckResolve=null,aesKey=null,approvalRequestId='',sentHash='';
        const chunkRequests=new Map();let chunkCounter=0;
        function native(m){try{window.webkit.messageHandlers.sharRemote.postMessage(m)}catch(e){}}
        function status(value,state=''){native({type:'status',value,state})}
        function b64urlEncode(u){let s='';for(const b of u)s+=String.fromCharCode(b);return btoa(s).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'')}
        function randomPin(){const x=new Uint32Array(1);do{crypto.getRandomValues(x)}while(x[0]>=4294000000);return String(x[0]%1000000).padStart(6,'0')}
        async function pinVerifier(pin,salt){const material=await crypto.subtle.importKey('raw',new TextEncoder().encode(pin),'PBKDF2',false,['deriveBits']);const bits=await crypto.subtle.deriveBits({name:'PBKDF2',hash:'SHA-256',salt,iterations:PIN_ITERATIONS},material,256);return b64urlEncode(new Uint8Array(bits))}
        async function api(path,opt={}){let response;try{response=await fetch(API+path,{cache:'no-store',...opt,headers:{'Content-Type':'application/json','X-Shar-Client':'ios-native-2.1.1',...(opt.headers||{})}})}catch(e){throw Error('Cannot reach Shar remote service. Check Internet connection or server deployment.')}const text=await response.text();let body={};try{body=text?JSON.parse(text):{}}catch{}if(!response.ok)throw Error(body.error||`Shar remote service returned HTTP ${response.status}`);return body}
        window.__sharNativeChunk=(id,b64)=>{const p=chunkRequests.get(id);if(!p)return;chunkRequests.delete(id);try{const raw=atob(b64),out=new Uint8Array(raw.length);for(let i=0;i<raw.length;i++)out[i]=raw.charCodeAt(i);p.resolve(out)}catch(e){p.reject(e)}};
        window.__sharNativeChunkError=(id,message)=>{const p=chunkRequests.get(id);if(!p)return;chunkRequests.delete(id);p.reject(Error(message||'Could not read file'))};
        function chunk(offset,length){return new Promise((resolve,reject)=>{const id=String(++chunkCounter);chunkRequests.set(id,{resolve,reject});native({type:'chunk',requestId:id,offset,length})})}
        async function waitBuffer(){if(!dc||dc.readyState!=='open')throw Error('Remote data channel closed');if(dc.bufferedAmount<4*1024*1024)return;await new Promise((resolve,reject)=>{dc.bufferedAmountLowThreshold=1024*1024;const done=()=>resolve();dc.addEventListener('bufferedamountlow',done,{once:true});setTimeout(()=>{if(dc&&dc.bufferedAmount>=4*1024*1024)reject(Error('Receiver is not consuming data'))},30000)})}
        async function seal(type,payload){const body=payload instanceof Uint8Array?payload:new Uint8Array(payload);const plain=new Uint8Array(1+body.byteLength);plain[0]=type;plain.set(body,1);const iv=crypto.getRandomValues(new Uint8Array(12));const cipher=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv},aesKey,plain));const out=new Uint8Array(12+cipher.byteLength);out.set(iv);out.set(cipher,12);return out.buffer}
        async function openPacket(data){const u=data instanceof ArrayBuffer?new Uint8Array(data):new Uint8Array(await data.arrayBuffer());if(u.byteLength<29)throw Error('Invalid encrypted acknowledgement');const iv=u.subarray(0,12),cipher=u.subarray(12);const plain=new Uint8Array(await crypto.subtle.decrypt({name:'AES-GCM',iv},aesKey,cipher));return{type:plain[0],payload:plain.subarray(1)}}
        async function sendControl(obj){await waitBuffer();dc.send(await seal(1,new TextEncoder().encode(JSON.stringify(obj))))}
        async function sendData(bytes){await waitBuffer();dc.send(await seal(2,bytes))}
        async function signal(type,payload){if(!session)throw Error('No remote session');return api('/session/'+encodeURIComponent(session.id)+'/signal',{method:'POST',headers:{Authorization:'Bearer '+session.hostSecret},body:JSON.stringify({type,payload})})}
        async function poll(){if(!session||cancelled)return;try{const j=await api('/session/'+encodeURIComponent(session.id)+'/signal?since='+signalSeq,{headers:{Authorization:'Bearer '+session.hostSecret}});for(const m of j.messages||[]){signalSeq=Math.max(signalSeq,m.seq);if(m.type==='answer'){await pc.setRemoteDescription(m.payload);for(const c of pending.splice(0))await pc.addIceCandidate(c)}else if(m.type==='candidate'&&m.payload){if(pc.remoteDescription)await pc.addIceCandidate(m.payload);else pending.push(m.payload)}else if(m.type==='join-request'){approvalRequestId=m.payload?.requestId||'';status('Receiver entered the correct PIN — approval required');native({type:'approval',requestId:approvalRequestId})}else if(m.type==='ready'){status('Approved receiver is connecting…')}}}catch(e){if(finished||cancelled)return;native({type:'error',message:e.message});return}if(!finished&&!cancelled)pollTimer=setTimeout(poll,650)}
        window.sharNativeApprove=async approved=>{if(!session||!approvalRequestId)return;try{await api('/session/'+encodeURIComponent(session.id)+'/approve',{method:'POST',headers:{Authorization:'Bearer '+session.hostSecret},body:JSON.stringify({requestId:approvalRequestId,approved:!!approved})});native({type:'approvalResolved',approved:!!approved});status(approved?'Receiver approved — establishing secure connection…':'Receiver rejected');if(!approved)approvalRequestId=''}catch(e){native({type:'error',message:e.message})}};
        async function connectionLabel(){try{const stats=await pc.getStats();let pair=null;stats.forEach(x=>{if(x.type==='transport'&&x.selectedCandidatePairId)pair=stats.get(x.selectedCandidatePairId);if(x.type==='candidate-pair'&&x.selected)pair=x});if(pair){const l=stats.get(pair.localCandidateId),r=stats.get(pair.remoteCandidateId);if(l?.candidateType==='relay'||r?.candidateType==='relay')return 'Secure connection through Shar TURN relay';return 'Secure peer-to-peer connection'}}catch{}return 'Secure connection established'}
        function receiverAck(timeout=15000){return new Promise(resolve=>{let done=false;const finish=value=>{if(done)return;done=true;receiverAckResolve=null;resolve(value)};receiverAckResolve=ok=>finish(ok===true);setTimeout(()=>finish(false),timeout)})}
        async function serverCompletion(){for(let i=0;i<8&&!cancelled;i++){try{const s=await api('/session/'+encodeURIComponent(session.id));if(s.completed)return true}catch{}await new Promise(r=>setTimeout(r,500))}return false}
        class Sha256{constructor(){this.h=new Uint32Array([0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]);this.buf=new Uint8Array(64);this.bufLen=0;this.bytes=0;this.w=new Uint32Array(64)}static rotr(x,n){return(x>>>n)|(x<<(32-n))}_block(b,o=0){const w=this.w;for(let i=0;i<16;i++){const j=o+i*4;w[i]=((b[j]<<24)|(b[j+1]<<16)|(b[j+2]<<8)|b[j+3])>>>0}for(let i=16;i<64;i++){const x=w[i-15],y=w[i-2],s0=(Sha256.rotr(x,7)^Sha256.rotr(x,18)^(x>>>3))>>>0,s1=(Sha256.rotr(y,17)^Sha256.rotr(y,19)^(y>>>10))>>>0;w[i]=(w[i-16]+s0+w[i-7]+s1)>>>0}let[a,b1,c,d,e,f,g,h]=this.h;for(let i=0;i<64;i++){const S1=(Sha256.rotr(e,6)^Sha256.rotr(e,11)^Sha256.rotr(e,25))>>>0,ch=((e&f)^((~e)&g))>>>0,t1=(h+S1+ch+Sha256.K[i]+w[i])>>>0,S0=(Sha256.rotr(a,2)^Sha256.rotr(a,13)^Sha256.rotr(a,22))>>>0,maj=((a&b1)^(a&c)^(b1&c))>>>0,t2=(S0+maj)>>>0;h=g;g=f;f=e;e=(d+t1)>>>0;d=c;c=b1;b1=a;a=(t1+t2)>>>0}const v=[a,b1,c,d,e,f,g,h];for(let i=0;i<8;i++)this.h[i]=(this.h[i]+v[i])>>>0}update(data){const u=data instanceof Uint8Array?data:new Uint8Array(data);this.bytes+=u.length;let o=0;if(this.bufLen){const n=Math.min(64-this.bufLen,u.length);this.buf.set(u.subarray(0,n),this.bufLen);this.bufLen+=n;o+=n;if(this.bufLen===64){this._block(this.buf);this.bufLen=0}}while(o+64<=u.length){this._block(u,o);o+=64}if(o<u.length){this.buf.set(u.subarray(o),0);this.bufLen=u.length-o}return this}hex(){const bytes=this.bytes,len=this.bufLen,padLen=len<56?56-len:120-len,pad=new Uint8Array(padLen+8);pad[0]=0x80;const bits=bytes*8,hi=Math.floor(bits/0x100000000),lo=bits>>>0,n=pad.length;pad[n-8]=(hi>>>24)&255;pad[n-7]=(hi>>>16)&255;pad[n-6]=(hi>>>8)&255;pad[n-5]=hi&255;pad[n-4]=(lo>>>24)&255;pad[n-3]=(lo>>>16)&255;pad[n-2]=(lo>>>8)&255;pad[n-1]=lo&255;this.update(pad);return Array.from(this.h,x=>x.toString(16).padStart(8,'0')).join('')}}
        Sha256.K=new Uint32Array([0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]);
        async function sendFile(){sent=0;native({type:'transfer',active:true});const hasher=new Sha256();await sendControl({t:'manifest',files:[FILE]});await sendControl({t:'file-start',i:0,path:FILE.path,name:FILE.name,size:FILE.size,mime:FILE.mime});for(let offset=0;offset<FILE.size;){if(cancelled)throw Error('Share cancelled');const length=Math.min(49152,FILE.size-offset);const bytes=await chunk(offset,length);if(!bytes.length&&length)throw Error('Unexpected end of file');hasher.update(bytes);await sendData(bytes);offset+=bytes.byteLength;sent=offset;native({type:'progress',sent,total:FILE.size})}sentHash=hasher.hex();await sendControl({t:'file-end',i:0,sha256:sentHash});const ack=receiverAck();await sendControl({t:'complete'});status('Finalizing encrypted transfer with receiver…','live');const verified=await ack;const serverDone=verified?true:await serverCompletion();finished=true;if(pollTimer)clearTimeout(pollTimer);pollTimer=null;native({type:'complete',confirmed:verified,serverDone});status(verified?'Transfer complete ✓':serverDone?'Receiver reported completion — secure verification ACK unavailable':'Transfer sent — receiver confirmation unavailable','live')}
        async function start(){if(!window.RTCPeerConnection||!crypto?.subtle){native({type:'error',message:'Secure WebRTC/Web Crypto is unavailable in this iOS WebView.'});return}try{const pin=randomPin(),salt=crypto.getRandomValues(new Uint8Array(16)),verifier=await pinVerifier(pin,salt),rawKey=crypto.getRandomValues(new Uint8Array(32));aesKey=await crypto.subtle.importKey('raw',rawKey,{name:'AES-GCM'},false,['encrypt','decrypt']);session=await api('/session',{method:'POST',body:JSON.stringify({files:[{path:'Encrypted item',size:FILE.size,mime:'application/octet-stream'}],ttlSeconds:1800,oneTime:true,pinVerifier:verifier,pinSalt:b64urlEncode(salt),pinIterations:PIN_ITERATIONS,approvalRequired:true,e2ee:true,privateMetadata:true})});const receiverUrl=RECEIVE+'#share='+encodeURIComponent(session.id)+'&key='+encodeURIComponent(b64urlEncode(rawKey));native({type:'session',receiverUrl,expiresAt:session.expiresAt,pin});status('Waiting for receiver PIN…');pc=new RTCPeerConnection({iceServers:session.iceServers});dc=pc.createDataChannel('shar-file',{ordered:true});dc.binaryType='arraybuffer';dc.onopen=async()=>{status(await connectionLabel(),'live');sendFile().catch(e=>{if(!finished)native({type:'error',message:e.message})})};dc.onmessage=e=>{if(finished||typeof e.data==='string')return;(async()=>{try{const packet=await openPacket(e.data);if(packet.type!==1)return;const m=JSON.parse(new TextDecoder().decode(packet.payload));if(m.t==='receiver-complete'){const ok=m.verified===true&&Array.isArray(m.hashes)&&m.hashes[0]===sentHash;status(ok?'Receiver decrypted and SHA-256 verified the file ✓':'Receiver completion could not be cryptographically verified',ok?'live':'');receiverAckResolve?.(ok)}}catch(err){if(!finished)native({type:'error',message:'Secure receiver acknowledgement failed.'})}})()};dc.onerror=()=>{if(!finished)native({type:'error',message:'Encrypted WebRTC data channel error.'})};pc.onicecandidate=e=>{if(e.candidate)signal('candidate',e.candidate.toJSON()).catch(()=>{})};pc.onconnectionstatechange=async()=>{if(finished)return;if(pc.connectionState==='connected')status(await connectionLabel(),'live');else if(pc.connectionState==='failed')native({type:'error',message:'Could not establish a direct or Shar TURN WebRTC connection.'});else if(pc.connectionState==='disconnected')status('Receiver disconnected')};const offer=await pc.createOffer();await pc.setLocalDescription(offer);await signal('offer',pc.localDescription);poll()}catch(e){native({type:'error',message:e.message||String(e)})}}
        window.sharNativeCancel=async()=>{cancelled=true;finished=true;if(pollTimer)clearTimeout(pollTimer);try{dc&&dc.close()}catch{}try{pc&&pc.close()}catch{}if(session?.id&&session?.hostSecret)await api('/session/'+encodeURIComponent(session.id),{method:'DELETE',headers:{Authorization:'Bearer '+session.hostSecret}}).catch(()=>{});session=null};
        setTimeout(start,0);
        </script>
        """
    }

    private func mimeType(for file: SharedFile) -> String {
        if let type = UTType(filenameExtension: file.fileExtension), let mime = type.preferredMIMEType { return mime }
        return "application/octet-stream"
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "sharRemote", let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "status":
            guard let value = body["value"] as? String else { return }
            status = value
            if body["state"] as? String == "live" { errorMessage = nil }
        case "session":
            if let value = body["receiverUrl"] as? String { receiverURL = URL(string: value) }
            if let value = body["expiresAt"] as? String { expiresAt = ISO8601DateFormatter().date(from: value) }
            if let value = body["pin"] as? String { pinCode = value }
            isWorking = true
            errorMessage = nil
        case "approval":
            approvalPending = true
            status = "Receiver requests approval"
        case "approvalResolved":
            approvalPending = false
            status = ((body["approved"] as? Bool) ?? false) ? "Receiver approved — connecting…" : "Receiver rejected"
        case "transfer":
            isTransferring = (body["active"] as? Bool) ?? true
        case "progress":
            let sentValue = (body["sent"] as? NSNumber)?.int64Value ?? 0
            let totalValue = max((body["total"] as? NSNumber)?.int64Value ?? file.size, 1)
            transferred = sentValue
            progress = min(max(Double(sentValue) / Double(totalValue), 0), 1)
            isTransferring = true
        case "complete":
            transferred = file.size
            progress = 1
            isTransferring = false
            isWorking = false
            approvalPending = false
            let confirmed = (body["confirmed"] as? Bool) ?? false
            let serverDone = (body["serverDone"] as? Bool) ?? false
            status = confirmed ? "Transfer complete ✓" : (serverDone ? "Receiver reported completion" : "Transfer sent")
        case "error":
            fail((body["message"] as? String) ?? "Remote share failed")
        case "chunk":
            guard let requestID = body["requestId"] as? String,
                  let offset = (body["offset"] as? NSNumber)?.uint64Value,
                  let length = (body["length"] as? NSNumber)?.intValue else { return }
            provideChunk(requestID: requestID, offset: offset, length: length)
        default:
            break
        }
    }

    private func provideChunk(requestID: String, offset: UInt64, length: Int) {
        let fileURL = file.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                try handle.seek(toOffset: offset)
                let data = try handle.read(upToCount: max(1, min(length, 49152))) ?? Data()
                let b64 = data.base64EncodedString()
                DispatchQueue.main.async {
                    self?.webView?.callAsyncJavaScript(
                        "window.__sharNativeChunk(requestId, base64)",
                        arguments: ["requestId": requestID, "base64": b64],
                        in: nil,
                        in: .page,
                        completionHandler: { _ in }
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self?.webView?.callAsyncJavaScript(
                        "window.__sharNativeChunkError(requestId, message)",
                        arguments: ["requestId": requestID, "message": error.localizedDescription],
                        in: nil,
                        in: .page,
                        completionHandler: { _ in }
                    )
                }
            }
        }
    }

    private func fail(_ message: String) {
        isWorking = false
        isTransferring = false
        approvalPending = false
        errorMessage = message
        status = "Secure Remote Share unavailable"
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "sharRemote")
    }
}

private struct ActionLabel: View {
    let full: String
    let short: String
    let systemImage: String
    let mode: ActionLabelMode

    var body: some View {
        switch mode {
        case .text:
            Text(full)
        case .icons:
            Image(systemName: systemImage).accessibilityLabel(full)
        case .compact:
            Label(short, systemImage: systemImage)
        }
    }
}

private struct AudioMetadataLine: View {
    let file: SharedFile
    @State private var metadata = MediaMetadataInfo.empty

    var body: some View {
        Group {
            if metadata.title != nil || metadata.artist != nil {
                Text([metadata.title, metadata.artist].compactMap { $0 }.joined(separator: " — "))
                    .lineLimit(1)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .task(id: file.id) {
            metadata = await Task.detached(priority: .utility) { MediaMetadataReader.read(file.url) }.value
        }
    }
}


private struct PhotoVideoLibraryPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPicked: (URL) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, onPicked: onPicked, onError: onError)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private var isPresented: Binding<Bool>
        private let onPicked: (URL) -> Void
        private let onError: (String) -> Void

        init(isPresented: Binding<Bool>, onPicked: @escaping (URL) -> Void, onError: @escaping (String) -> Void) {
            self.isPresented = isPresented
            self.onPicked = onPicked
            self.onError = onError
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            isPresented.wrappedValue = false
            for result in results {
                importResult(result)
            }
        }

        private func importResult(_ result: PHPickerResult) {
            let provider = result.itemProvider
            let typeIdentifier: String
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                typeIdentifier = UTType.movie.identifier
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                typeIdentifier = UTType.image.identifier
            } else {
                DispatchQueue.main.async { self.onError("The selected Photos item is not an image or video.") }
                return
            }

            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] sourceURL, error in
                guard let self else { return }
                if let error {
                    DispatchQueue.main.async { self.onError(error.localizedDescription) }
                    return
                }
                guard let sourceURL else {
                    DispatchQueue.main.async { self.onError("Photos could not provide the selected item.") }
                    return
                }

                do {
                    let temporaryURL = try Self.makeTemporaryCopy(
                        from: sourceURL,
                        suggestedName: provider.suggestedName
                    )
                    DispatchQueue.main.async {
                        self.onPicked(temporaryURL)
                        try? FileManager.default.removeItem(at: temporaryURL.deletingLastPathComponent())
                    }
                } catch {
                    DispatchQueue.main.async { self.onError(error.localizedDescription) }
                }
            }
        }

        private static func makeTemporaryCopy(from sourceURL: URL, suggestedName: String?) throws -> URL {
            let fm = FileManager.default
            var filename = (suggestedName ?? sourceURL.lastPathComponent)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if filename.isEmpty { filename = "Shar Media" }
            if URL(fileURLWithPath: filename).pathExtension.isEmpty, !sourceURL.pathExtension.isEmpty {
                filename += ".\(sourceURL.pathExtension)"
            }
            let directory = fm.temporaryDirectory
                .appendingPathComponent("SharPhotoImports", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(filename)
            try fm.copyItem(at: sourceURL, to: destination)
            return destination
        }
    }
}

private struct VideoCameraPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPicked: (URL) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, onPicked: onPicked, onError: onError)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 600
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private var isPresented: Binding<Bool>
        private let onPicked: (URL) -> Void
        private let onError: (String) -> Void

        init(isPresented: Binding<Bool>, onPicked: @escaping (URL) -> Void, onError: @escaping (String) -> Void) {
            self.isPresented = isPresented
            self.onPicked = onPicked
            self.onError = onError
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            isPresented.wrappedValue = false
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let sourceURL = info[.mediaURL] as? URL else {
                isPresented.wrappedValue = false
                onError("The camera did not return a recorded video.")
                return
            }

            do {
                let fm = FileManager.default
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
                let filename = "Shar Video \(formatter.string(from: Date())).mov"
                let directory = fm.temporaryDirectory.appendingPathComponent("SharCamera", isDirectory: true)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(filename)
                try? fm.removeItem(at: destination)
                try fm.copyItem(at: sourceURL, to: destination)
                onPicked(destination)
                try? fm.removeItem(at: destination)
            } catch {
                onError(error.localizedDescription)
            }
            isPresented.wrappedValue = false
        }
    }
}
