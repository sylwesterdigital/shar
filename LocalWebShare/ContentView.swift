import AVFoundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var fileStore: FileStore
    @EnvironmentObject private var webServer: LocalWebServer

    @AppStorage("actionLabelMode") private var actionLabelModeRaw = ActionLabelMode.compact.rawValue
    @State private var selectedFile: SharedFile?
    @State private var filePendingDelete: SharedFile?

    private var actionLabelMode: ActionLabelMode {
        ActionLabelMode(rawValue: actionLabelModeRaw) ?? .compact
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image("SharLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Local Web Share")
                                .font(.title3.bold())
                            Text("Wi-Fi media sharing")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }

                Section("Wi-Fi Sharing") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(webServer.isRunning ? "Sharing is ON" : "Sharing is OFF")
                                .font(.headline)
                            Text(webServer.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle()
                            .fill(webServer.isRunning ? Color.green : Color.secondary)
                            .frame(width: 12, height: 12)
                    }

                    if webServer.isRunning {
                        Text(webServer.shareURL)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)

                        ShareLink(item: webServer.shareURL) {
                            ActionLabel(full: "Share Address", short: "Share", systemImage: "square.and.arrow.up", mode: actionLabelMode)
                        }
                    }

                    Button {
                        webServer.isRunning ? webServer.stop() : webServer.start()
                    } label: {
                        ActionLabel(
                            full: webServer.isRunning ? "Stop Sharing" : "Start Sharing",
                            short: webServer.isRunning ? "Stop" : "Start",
                            systemImage: webServer.isRunning ? "stop.fill" : "play.fill",
                            mode: actionLabelMode
                        )
                    }

                    Picker("Button labels", selection: $actionLabelModeRaw) {
                        ForEach(ActionLabelMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Keep this app open while transferring files. The computer and iPhone/iPad must be on the same local network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Version \(appVersion)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Section {
                    if fileStore.files.isEmpty {
                        ContentUnavailableView(
                            "No Files Yet",
                            systemImage: "folder",
                            description: Text("Start Wi-Fi Sharing and drop music, videos, images, or other files into the browser.")
                        )
                    } else {
                        ForEach(fileStore.files) { file in
                            fileRow(file)
                                .contentShape(Rectangle())
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        filePendingDelete = file
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button { selectedFile = file } label: { Label("Preview", systemImage: "eye") }
                                    ShareLink(item: file.url) { Label("Share", systemImage: "square.and.arrow.up") }
                                    Button(role: .destructive) { filePendingDelete = file } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                } header: {
                    HStack {
                        Text("Files")
                        Spacer()
                        Text("\(fileStore.files.count)")
                            .foregroundStyle(.secondary)
                        Button { fileStore.refresh() } label: {
                            ActionLabel(full: "Refresh", short: "Refresh", systemImage: "arrow.clockwise", mode: actionLabelMode)
                        }
                        .textCase(nil)
                    }
                }
            }
            .navigationTitle("Local Web Share")
            .sheet(item: $selectedFile) { file in
                MediaPlayerView(files: fileStore.files, initialFile: file) { deleted in
                    fileStore.delete(deleted)
                }
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
                    if let filePendingDelete { fileStore.delete(filePendingDelete) }
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
        }
    }

    private func fileRow(_ file: SharedFile) -> some View {
        HStack(spacing: 10) {
            Button { selectedFile = file } label: {
                HStack(spacing: 12) {
                    ThumbnailView(file: file)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(file.name).foregroundStyle(.primary).lineLimit(2)
                        if file.mediaKind == .audio { AudioMetadataLine(file: file) }
                        HStack(spacing: 6) {
                            Text(file.mediaKind.rawValue.capitalized); Text("•"); Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
            }
            .buttonStyle(.plain)

            if file.mediaKind == .audio { InlineAudioPlayButton(file: file) }

            Button { selectedFile = file } label: {
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(file.name)")
        }
        .padding(.vertical, 3)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
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
        .font(.caption)
        .foregroundStyle(.secondary)
        .task(id: file.id) {
            metadata = await Task.detached(priority: .utility) { MediaMetadataReader.read(file.url) }.value
        }
    }
}

private struct InlineAudioPlayButton: View {
    let file: SharedFile
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var observer: Any?

    var body: some View {
        Button {
            if player == nil { player = AVPlayer(url: file.url) }
            guard let player else { return }
            if isPlaying { player.pause() } else { player.play() }
            isPlaying.toggle()
        } label: {
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.title2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause \(file.name)" : "Play \(file.name)")
        .onAppear {
            if player == nil { player = AVPlayer(url: file.url) }
            if let player {
                observer = player.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 0.3, preferredTimescale: 600),
                    queue: .main
                ) { _ in isPlaying = player.timeControlStatus == .playing }
            }
        }
        .onDisappear {
            if let observer, let player { player.removeTimeObserver(observer) }
            observer = nil
            player?.pause()
            player = nil
        }
    }
}
