import AppKit
import AVFoundation
import AVKit
import QuickLookUI
import SwiftUI

@main
struct LocalWebShareMacApp: App {
    @StateObject private var fileStore = FileStore()
    @StateObject private var webServer = LocalWebServer()

    var body: some Scene {
        WindowGroup {
            MacContentView()
                .environmentObject(fileStore)
                .environmentObject(webServer)
                .frame(minWidth: 820, minHeight: 600)
        }
        .windowStyle(.titleBar)
    }
}

struct MacContentView: View {
    @EnvironmentObject private var fileStore: FileStore
    @EnvironmentObject private var webServer: LocalWebServer

    @State private var selectedFile: SharedFile?
    @State private var deleteCandidate: SharedFile?
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                appHeader
                sharingCard
                importCard
                Spacer()
                Text("Shared folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(FileStore.documentsDirectory.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Text("Version \(appVersion)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            filesPane
        }
        .sheet(item: $selectedFile) { file in
            MacMediaPreview(file: file) {
                fileStore.delete(file)
                selectedFile = nil
            }
            .frame(minWidth: 720, minHeight: 520)
        }
        .confirmationDialog(
            deleteCandidate.map { "Delete \($0.name)?" } ?? "Delete file?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let deleteCandidate { fileStore.delete(deleteCandidate) }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        }
        .alert("Error", isPresented: Binding(
            get: { fileStore.lastError != nil || webServer.lastError != nil },
            set: { if !$0 { fileStore.lastError = nil; webServer.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(fileStore.lastError ?? webServer.lastError ?? "Unknown error")
        }
    }

    private var appHeader: some View {
        HStack(spacing: 12) {
            if let image = Bundle.main.url(forResource: "shar-logo-1024", withExtension: "png").flatMap(NSImage.init(contentsOf:)) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Local Web Share")
                    .font(.title2.bold())
                Text("Wi-Fi media sharing")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sharingCard: some View {
        GroupBox("Wi-Fi Sharing") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle()
                        .fill(webServer.isRunning ? Color.green : Color.secondary)
                        .frame(width: 10, height: 10)
                    Text(webServer.isRunning ? "Sharing is ON" : "Sharing is OFF")
                        .fontWeight(.semibold)
                }
                Text(webServer.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if webServer.isRunning {
                    Text(webServer.shareURL)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    HStack {
                        Button("Copy Address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(webServer.shareURL, forType: .string)
                        }
                        Button("Open in Browser") {
                            if let url = URL(string: webServer.shareURL) { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                Button(webServer.isRunning ? "Stop Sharing" : "Start Sharing") {
                    webServer.isRunning ? webServer.stop() : webServer.start()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private var importCard: some View {
        GroupBox("Import") {
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 30))
                Text("Drop files here")
                    .fontWeight(.semibold)
                Text("They are copied into Local Web Share immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Choose Files…") { chooseFiles() }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .dropDestination(for: URL.self) { urls, _ in
                urls.forEach { fileStore.importFile(from: $0) }
                return !urls.isEmpty
            } isTargeted: { isDropTargeted = $0 }
        }
    }

    private var filesPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Files")
                    .font(.title2.bold())
                Text("\(fileStore.files.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSWorkspace.shared.open(FileStore.documentsDirectory)
                } label: {
                    Label("Show Folder", systemImage: "folder")
                }
                Button {
                    fileStore.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .padding(18)

            Divider()

            if fileStore.files.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("No Files Yet").font(.title3.bold())
                    Text("Drop files into this window or upload them from the browser.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(fileStore.files) { file in
                    HStack(spacing: 12) {
                        MacThumbnail(file: file)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name).fontWeight(.medium)
                            Text("\(file.mediaKind.rawValue.capitalized) • \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            selectedFile = file
                        } label: {
                            Image(systemName: "eye")
                        }
                        .buttonStyle(.borderless)
                        Button(role: .destructive) {
                            deleteCandidate = file
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { selectedFile = file }
                    .contextMenu {
                        Button("Preview") { selectedFile = file }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                        Divider()
                        Button("Delete", role: .destructive) { deleteCandidate = file }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            panel.urls.forEach { fileStore.importFile(from: $0) }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}

private struct MacThumbnail: View {
    let file: SharedFile
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(.quaternary)
            if file.mediaKind == .image, let image = NSImage(contentsOf: file.url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: file.systemImageName).font(.title2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(alignment: .bottomTrailing) {
            Text(file.typeLabel).font(.system(size: 8, weight: .semibold))
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule()).padding(3)
        }
    }
}

private struct MacMediaPreview: View {
    let file: SharedFile
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var confirmDelete = false

    init(file: SharedFile, onDelete: @escaping () -> Void) {
        self.file = file
        self.onDelete = onDelete
        _player = State(initialValue: file.isPlayableMedia ? AVPlayer(url: file.url) : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(file.name).font(.headline).lineLimit(1)
                Spacer()
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                Button("Done") { dismiss() }
            }
            .padding(14)
            Divider()
            Group {
                switch file.mediaKind {
                case .image:
                    if let image = NSImage(contentsOf: file.url) {
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image).resizable().scaledToFit().padding(16)
                        }
                        .background(Color.black)
                    } else { unavailable("Cannot preview image") }
                case .video:
                    if let player { VideoPlayer(player: player).onAppear { player.play() } }
                case .audio:
                    VStack(spacing: 22) {
                        Spacer()
                        Image(systemName: "waveform.circle.fill").font(.system(size: 120)).foregroundStyle(.secondary)
                        Text(file.name).font(.title3.bold())
                        if let player { MacAudioControls(player: player) }
                        Spacer()
                    }.padding(28)
                case .document, .file:
                    MacQuickLook(url: file.url)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text(file.typeLabel)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
            }
            .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .confirmationDialog("Delete \(file.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { onDelete(); dismiss() }
            Button("Cancel", role: .cancel) {}
        }
        .onDisappear { player?.pause() }
    }

    @ViewBuilder private func unavailable(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.questionmark").font(.system(size: 44))
            Text(text).font(.headline)
        }
        .foregroundStyle(.secondary)
    }
}

private struct MacAudioControls: View {
    let player: AVPlayer
    @State private var isPlaying = false
    @State private var current = 0.0
    @State private var duration = 0.0
    @State private var observer: Any?

    var body: some View {
        VStack(spacing: 12) {
            Slider(value: Binding(get: { min(current, max(duration, 0.01)) }, set: { value in
                current = value
                player.seek(to: CMTime(seconds: value, preferredTimescale: 600))
            }), in: 0...max(duration, 0.01))
            HStack {
                Text(time(current)).monospacedDigit()
                Spacer()
                Button { toggle() } label: { Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 48)) }
                    .buttonStyle(.plain)
                Spacer()
                Text(time(duration)).monospacedDigit()
            }.font(.caption)
        }
        .frame(maxWidth: 520)
        .onAppear {
            Task {
                if let item = player.currentItem, let d = try? await item.asset.load(.duration), d.seconds.isFinite { duration = d.seconds }
            }
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { t in
                current = max(0, t.seconds)
                isPlaying = player.timeControlStatus == .playing
            }
            player.play(); isPlaying = true
        }
        .onDisappear {
            if let observer { player.removeTimeObserver(observer); self.observer = nil }
            player.pause()
        }
    }

    private func toggle() { isPlaying ? player.pause() : player.play(); isPlaying.toggle() }
    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let v = Int(seconds)
        return String(format: "%d:%02d", v / 60, v % 60)
    }
}

private struct MacQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ nsView: QLPreviewView, context: Context) { nsView.previewItem = url as NSURL }
}
