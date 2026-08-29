import AVKit
import QuickLook
import SwiftUI
import UIKit

struct MediaPlayerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var files: [SharedFile]
    @State private var index: Int
    @State private var showDeleteConfirmation = false

    let onDelete: ((SharedFile) -> Void)?

    init(files: [SharedFile], initialFile: SharedFile, onDelete: ((SharedFile) -> Void)? = nil) {
        let start = files.firstIndex(of: initialFile) ?? 0
        _files = State(initialValue: files)
        _index = State(initialValue: min(max(0, start), max(0, files.count - 1)))
        self.onDelete = onDelete
    }

    private var file: SharedFile? {
        guard files.indices.contains(index) else { return nil }
        return files[index]
    }

    var body: some View {
        NavigationStack {
            Group {
                if let file {
                    MediaPreviewContent(file: file)
                        .id(file.id)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 35)
                                .onEnded { value in
                                    let dx = value.translation.width
                                    if dx < -60 { next() }
                                    else if dx > 60 { previous() }
                                }
                        )
                } else {
                    ContentUnavailableView("No Files", systemImage: "folder")
                }
            }
            .navigationTitle(file?.name ?? "Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { previous() } label: { Image(systemName: "chevron.left") }
                        .disabled(index <= 0)
                        .accessibilityLabel("Previous file")
                    Button { next() } label: { Image(systemName: "chevron.right") }
                        .disabled(index >= files.count - 1)
                        .accessibilityLabel("Next file")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let file {
                        ShareLink(item: file.url) { Image(systemName: "square.and.arrow.up") }
                        if onDelete != nil {
                            Button(role: .destructive) { showDeleteConfirmation = true } label: { Image(systemName: "trash") }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    if files.count > 1 {
                        Text("\(index + 1) of \(files.count) • swipe left/right for next/previous")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    Spacer(minLength: 8)
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.bold))
                            .frame(width: 36, height: 36)
                            .background(.thinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close preview")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial)
            }
            .confirmationDialog(
                file.map { "Delete \($0.name)?" } ?? "Delete file?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deleteCurrent() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func previous() {
        guard index > 0 else { return }
        index -= 1
    }

    private func next() {
        guard index + 1 < files.count else { return }
        index += 1
    }

    private func deleteCurrent() {
        guard let current = file else { return }
        onDelete?(current)
        files.remove(at: index)
        if files.isEmpty {
            dismiss()
        } else if index >= files.count {
            index = files.count - 1
        }
    }
}

private struct MediaPreviewContent: View {
    @Environment(\.scenePhase) private var scenePhase
    let file: SharedFile
    @State private var player: AVPlayer?

    init(file: SharedFile) {
        self.file = file
        _player = State(initialValue: file.isPlayableMedia ? AVPlayer(url: file.url) : nil)
    }

    var body: some View {
        Group {
            switch file.mediaKind {
            case .image:
                imagePreview
            case .audio:
                audioPreview
            case .video:
                videoPreview
            case .document, .file:
                QuickLookPreview(url: file.url)
            }
        }
        .onDisappear { player?.pause() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && file.mediaKind == .video {
                player?.pause()
            }
        }
    }

    private var imagePreview: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let image = UIImage(contentsOfFile: file.url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    ContentUnavailableView("Cannot Preview Image", systemImage: "photo.badge.exclamationmark")
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .clipped()
        }
    }

    private var videoPreview: some View {
        VStack(spacing: 16) {
            if let player {
                VideoPlayer(player: player)
                    .background(Color.black)
                    .onAppear { player.play() }
            }
            fileMetadata
        }
    }

    private var audioPreview: some View {
        VStack(spacing: 24) {
            Spacer()
            ThumbnailView(file: file, size: CGSize(width: 200, height: 200))
            AudioMetadataBlock(file: file)
            if let player { AudioControls(player: player) }
            Spacer()
        }
        .padding()
    }

    private var fileMetadata: some View {
        HStack {
            Text(file.typeLabel)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
    }
}

private struct AudioMetadataBlock: View {
    let file: SharedFile
    @State private var metadata = MediaMetadataInfo.empty

    var body: some View {
        VStack(spacing: 6) {
            Text(metadata.title ?? file.name)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let artist = metadata.artist, !artist.isEmpty {
                Text(artist).foregroundStyle(.secondary)
            }
            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .task(id: file.id) {
            metadata = await Task.detached(priority: .utility) { MediaMetadataReader.read(file.url) }.value
        }
    }
}

private struct AudioControls: View {
    let player: AVPlayer
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var observer: Any?

    var body: some View {
        VStack(spacing: 12) {
            Slider(
                value: Binding(
                    get: { min(max(currentTime, 0), max(duration, 0.01)) },
                    set: { newValue in
                        currentTime = newValue
                        player.seek(to: CMTime(seconds: newValue, preferredTimescale: 600))
                    }
                ),
                in: 0...max(duration, 0.01)
            )
            HStack {
                Text(format(currentTime))
                Spacer()
                Button {
                    if isPlaying {
                        player.pause()
                    } else {
                        BackgroundAudioSession.activatePlayback()
                        player.play()
                    }
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                }
                .buttonStyle(.plain)
                Spacer()
                Text(format(duration))
            }
            .font(.caption.monospacedDigit())
        }
        .onAppear {
            BackgroundAudioSession.activatePlayback()
            Task {
                if let item = player.currentItem,
                   let loadedDuration = try? await item.asset.load(.duration),
                   loadedDuration.seconds.isFinite {
                    duration = loadedDuration.seconds
                }
            }
            observer = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { time in
                currentTime = max(0, time.seconds)
                isPlaying = player.timeControlStatus == .playing
            }
            player.play()
            isPlaying = true
        }
        .onDisappear {
            if let observer { player.removeTimeObserver(observer); self.observer = nil }
            player.pause()
        }
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
