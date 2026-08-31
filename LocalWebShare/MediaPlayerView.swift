import AVFoundation
import AVKit
import QuickLook
import SwiftUI
import UIKit

struct MediaPlayerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var files: [SharedFile]
    @State private var index: Int
    @State private var showDeleteConfirmation = false

    let audioPlayback: SharedAudioPlaybackController
    let onDelete: ((SharedFile) -> Void)?

    init(
        files: [SharedFile],
        initialFile: SharedFile,
        audioPlayback: SharedAudioPlaybackController,
        onDelete: ((SharedFile) -> Void)? = nil
    ) {
        let start = files.firstIndex(of: initialFile) ?? 0
        _files = State(initialValue: files)
        _index = State(initialValue: min(max(0, start), max(0, files.count - 1)))
        self.audioPlayback = audioPlayback
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
                    MediaPreviewContent(file: file, audioPlayback: audioPlayback)
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
                    Button { dismiss() } label: {
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

    private func previous() { if index > 0 { index -= 1 } }
    private func next() { if index + 1 < files.count { index += 1 } }

    private func deleteCurrent() {
        guard let current = file else { return }
        if audioPlayback.activeFileID == current.id { audioPlayback.stop() }
        onDelete?(current)
        files.remove(at: index)
        if files.isEmpty { dismiss() }
        else if index >= files.count { index = files.count - 1 }
    }
}

private struct MediaPreviewContent: View {
    @Environment(\.scenePhase) private var scenePhase
    let file: SharedFile
    @ObservedObject var audioPlayback: SharedAudioPlaybackController
    @State private var videoPlayer: AVPlayer?

    init(file: SharedFile, audioPlayback: SharedAudioPlaybackController) {
        self.file = file
        self.audioPlayback = audioPlayback
        _videoPlayer = State(initialValue: file.mediaKind == .video ? AVPlayer(url: file.url) : nil)
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
            case .threeD:
                ThreeDPreviewView(file: file)
            case .document, .file:
                QuickLookPreview(url: file.url)
            }
        }
        .onDisappear { videoPlayer?.pause() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && file.mediaKind == .video { videoPlayer?.pause() }
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
            if let videoPlayer {
                VideoPlayer(player: videoPlayer)
                    .background(Color.black)
                    .onAppear { videoPlayer.play() }
            }
            fileMetadata
        }
    }

    private var audioPreview: some View {
        VStack(spacing: 24) {
            Spacer()
            ThumbnailView(file: file, size: CGSize(width: 200, height: 200))
            AudioMetadataBlock(file: file)
            AudioVisualizationView(file: file, playback: audioPlayback)
            AudioCaptionStrip(file: file, playback: audioPlayback)
            SharedAudioControls(file: file, playback: audioPlayback)
            Spacer()
        }
        .padding()
        .onAppear {
            // If the card was already playing/paused, preserve its exact player and position.
            // Only a previously inactive file begins from the start when first opened.
            audioPlayback.ensureLoaded(file, autoplayIfNew: true)
        }
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
            if let artist = metadata.artist, !artist.isEmpty { Text(artist).foregroundStyle(.secondary) }
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

private struct SharedAudioControls: View {
    let file: SharedFile
    @ObservedObject var playback: SharedAudioPlaybackController

    var body: some View {
        VStack(spacing: 12) {
            Slider(
                value: Binding(
                    get: { playback.isActive(file) ? min(max(playback.currentTime, 0), max(playback.duration, 0.01)) : 0 },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(playback.duration, 0.01)
            )
            HStack {
                Text(format(playback.isActive(file) ? playback.currentTime : 0))
                Spacer()
                Button { playback.toggle(file) } label: {
                    Image(systemName: playback.isPlaying(file) ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                }
                .buttonStyle(.plain)
                Spacer()
                Text(format(playback.isActive(file) ? playback.duration : 0))
            }
            .font(.caption.monospacedDigit())
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


// MARK: - Audio visualization + synchronized captions

private enum AudioVisualizationMode: String, CaseIterable {
    case spectrum = "Live spectrum"
    case waveform = "Waveform"
}

@MainActor
private final class AudioVisualizationModel: ObservableObject {
    @Published private(set) var waveform: [Double] = []
    @Published private(set) var spectrumFrames: [[Double]] = []
    @Published private(set) var isLoading = false
    private var loadedPath: String?

    func load(file: SharedFile) async {
        let path = file.url.path
        if loadedPath == path, !waveform.isEmpty { return }
        loadedPath = path
        isLoading = true
        let url = file.url
        let result = await Task.detached(priority: .utility) {
            SharAudioAnalyzer.analyze(url: url)
        }.value
        guard loadedPath == path else { return }
        waveform = result.waveform
        spectrumFrames = result.spectrumFrames
        isLoading = false
    }

    func spectrum(at progress: Double) -> [Double] {
        SharAudioAnalyzer.spectrum(frames: spectrumFrames, progress: progress)
    }
}

private struct AudioVisualizationView: View {
    let file: SharedFile
    @ObservedObject var playback: SharedAudioPlaybackController
    @StateObject private var analysis = AudioVisualizationModel()
    @State private var mode: AudioVisualizationMode = .spectrum

    private var progress: Double {
        guard playback.isActive(file), playback.duration > 0 else { return 0 }
        return min(max(playback.currentTime / playback.duration, 0), 1)
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.20)) {
                mode = mode == .spectrum ? .waveform : .spectrum
            }
        } label: {
            VStack(spacing: 5) {
                HStack {
                    Label(mode.rawValue, systemImage: mode == .spectrum ? "waveform.path.ecg" : "waveform")
                        .font(.caption.weight(.semibold))
                    if mode == .spectrum, playback.isPlaying(file) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    Spacer()
                    Text("tap to switch")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Group {
                    if analysis.isLoading && analysis.waveform.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 64)
                    } else if mode == .spectrum {
                        spectrum
                    } else {
                        waveform
                    }
                }
                .frame(height: 68)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Audio \(mode.rawValue). Tap to switch visualization")
        .task(id: file.id) { await analysis.load(file: file) }
    }

    private var spectrum: some View {
        let bands = analysis.spectrum(at: progress)
        return GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(bands.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(Color(hue: Double(index) / Double(max(1, bands.count - 1)) * 0.76, saturation: 0.82, brightness: 0.94))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(4, proxy.size.height * value))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var waveform: some View {
        GeometryReader { proxy in
            let values = analysis.waveform.isEmpty ? Array(repeating: 0.10, count: 72) : analysis.waveform
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    Capsule(style: .continuous)
                        .fill(Double(index) / Double(max(1, values.count - 1)) <= progress ? Color.accentColor : Color.secondary.opacity(0.28))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, proxy.size.height * value))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.linear(duration: 0.05), value: progress)
        }
    }
}

@MainActor
private enum AudioCaptionMemoryCache {
    static var wordsByPath: [String: [SharTimedCaptionWord]] = [:]
}

@MainActor
private final class AudioCaptionController: ObservableObject {
    @Published private(set) var words: [SharTimedCaptionWord] = []
    @Published private(set) var isTranscribing = false
    @Published private(set) var message: String?
    @Published private(set) var progressLabel: String?
    @Published private(set) var recognizerLabel: String?
    private var activePath: String?

    func prepare(file: SharedFile) {
        activePath = file.url.path
        words = AudioCaptionMemoryCache.wordsByPath[file.url.path] ?? []
        message = nil
        progressLabel = nil
        recognizerLabel = SharLocalWhisperTranscriber.engineLabel
    }

    func generate(file: SharedFile) {
        let path = file.url.path
        activePath = path
        message = nil
        progressLabel = "Loading local transcription model…"
        recognizerLabel = SharLocalWhisperTranscriber.engineLabel
        words = []
        AudioCaptionMemoryCache.wordsByPath[path] = []
        isTranscribing = true

        Task {
            do {
                let url = file.url
                let generated = try await Task.detached(priority: .userInitiated) {
                    try SharLocalWhisperTranscriber.transcribe(url: url) { current, total in
                        Task { @MainActor in
                            guard self.activePath == path else { return }
                            self.progressLabel = total > 1 ? "Creating captions \(current)/\(total)…" : "Creating captions…"
                        }
                    }
                }.value
                guard activePath == path else { return }
                words = generated
                AudioCaptionMemoryCache.wordsByPath[path] = generated
                if generated.isEmpty {
                    message = "No speech was recognized. The transcription stayed entirely on this device."
                }
            } catch {
                guard activePath == path else { return }
                message = "Local captions could not be created: \(error.localizedDescription)"
            }
            if activePath == path {
                isTranscribing = false
                progressLabel = nil
            }
        }
    }
}

private struct AudioCaptionStrip: View {
    let file: SharedFile
    @ObservedObject var playback: SharedAudioPlaybackController
    @StateObject private var captions = AudioCaptionController()

    private var currentIndex: Int? {
        guard !captions.words.isEmpty else { return nil }
        let time = playback.isActive(file) ? playback.currentTime : 0
        if let exact = captions.words.lastIndex(where: { $0.start <= time && time <= $0.start + max($0.duration, 0.12) }) {
            return exact
        }
        return captions.words.lastIndex(where: { $0.start <= time })
    }

    var body: some View {
        VStack(spacing: 8) {
            if captions.words.isEmpty {
                Button {
                    captions.generate(file: file)
                } label: {
                    HStack(spacing: 8) {
                        if captions.isTranscribing { ProgressView().controlSize(.small) }
                        Image(systemName: "captions.bubble")
                        Text(captions.progressLabel ?? (captions.isTranscribing ? "Creating captions…" : "Create captions"))
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(captions.isTranscribing)
            } else {
                HStack {
                    Label("Captions", systemImage: "captions.bubble.fill")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if captions.isTranscribing { ProgressView().controlSize(.mini) }
                    Button("Refresh") { captions.generate(file: file) }
                        .font(.caption)
                        .buttonStyle(.plain)
                }
                captionText
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .animation(.easeOut(duration: 0.12), value: currentIndex)
            }

            if let message = captions.message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                Text("Local Whisper • audio is never uploaded")
                if let label = captions.recognizerLabel, !label.isEmpty {
                    Text("• \(label)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onAppear { captions.prepare(file: file) }
    }

    private var captionText: Text {
        guard let currentIndex else { return Text(captions.words.prefix(8).map(\.text).joined(separator: " ")) }
        let lower = max(0, currentIndex - 5)
        let upper = min(captions.words.count, currentIndex + 7)
        var output = Text("")
        for index in lower..<upper {
            var token = Text((index == lower ? "" : " ") + captions.words[index].text)
            if index == currentIndex {
                token = token.foregroundColor(Color.accentColor).bold().underline()
            } else {
                token = token.foregroundColor(Color.primary)
            }
            output = output + token
        }
        return output
    }
}
