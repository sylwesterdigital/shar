import AVFoundation
import SwiftUI
import UIKit

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

    @StateObject private var audioPlayback = SharedAudioPlaybackController()
    @State private var selectedFile: SharedFile?
    @State private var filePendingDelete: SharedFile?
    @State private var showingSettings = false
    @State private var copiedAddress = false

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
                        Text("Files")
                            .font(.headline)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) { showingSettings = true }
                        } label: {
                            Image(systemName: "gearshape.fill")
                        }
                        .accessibilityLabel("Settings")
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
                description: Text("Turn on Sharing and drop files into the browser.")
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
                        HStack {
                            Label("Settings", systemImage: "gearshape.fill")
                                .font(.title3.bold())
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
                    .padding(20)
                }
                .frame(width: min(350, proxy.size.width * 0.88))
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)
                .shadow(radius: 24, x: -8)
            }
        }
        .ignoresSafeArea()
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

    private var displayAddress: String {
        webServer.shareURL.replacingOccurrences(of: "http://", with: "")
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}

private struct MediaGridCard: View {
    let file: SharedFile
    let actionLabelMode: ActionLabelMode
    let showFileSize: Bool
    @ObservedObject var audioPlayback: SharedAudioPlaybackController
    let onPreview: () -> Void
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
