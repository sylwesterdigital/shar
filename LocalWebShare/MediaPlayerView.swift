import AVFoundation
import AVKit
import QuickLook
import Speech
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

private struct AudioAnalysisResult {
    let waveform: [Double]
    let spectrumFrames: [[Double]]
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
            AudioFileAnalyzer.analyze(url: url)
        }.value
        guard loadedPath == path else { return }
        waveform = result.waveform
        spectrumFrames = result.spectrumFrames
        isLoading = false
    }

    /// Returns a time-aligned spectrum interpolated between analysis frames.
    /// Playback time is published at 20 Hz, so the bars move fluidly instead
    /// of stepping only when the next precomputed frame is reached.
    func spectrum(at progress: Double) -> [Double] {
        guard let first = spectrumFrames.first else { return Array(repeating: 0.08, count: 12) }
        guard spectrumFrames.count > 1 else { return first }
        let clamped = min(max(progress, 0), 1)
        let exact = Double(spectrumFrames.count - 1) * clamped
        let lower = min(spectrumFrames.count - 1, Int(floor(exact)))
        let upper = min(spectrumFrames.count - 1, lower + 1)
        let mix = exact - Double(lower)
        guard lower != upper else { return spectrumFrames[lower] }
        let a = spectrumFrames[lower]
        let b = spectrumFrames[upper]
        let count = min(a.count, b.count)
        return (0..<count).map { index in
            a[index] + (b[index] - a[index]) * mix
        }
    }
}

private enum AudioFileAnalyzer {
    private static let bandFrequencies: [Double] = [63, 125, 250, 500, 1_000, 2_000, 3_150, 5_000, 8_000, 10_000, 12_500, 16_000]

    static func analyze(url: URL) -> AudioAnalysisResult {
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            return AudioAnalysisResult(waveform: [], spectrumFrames: [])
        }
        let format = audioFile.processingFormat
        let sampleRate = max(1, format.sampleRate)
        let totalFrames = max(1, audioFile.length)
        let duration = Double(totalFrames) / sampleRate

        // About 12 spectrum samples/second for normal tracks. Long recordings
        // automatically reduce the analysis rate to cap memory/CPU, while the
        // displayed spectrum still interpolates at the 20 Hz playback clock.
        let targetFPS = min(12.0, max(3.0, 12_000.0 / max(duration, 1)))
        let hopFrames = max(AVAudioFrameCount(1_024), AVAudioFrameCount((sampleRate / targetFPS).rounded()))
        let spectrumWindow = 1_024

        var amplitudes: [Double] = []
        var spectra: [[Double]] = []
        let expected = min(12_000, max(1, Int(duration * targetFPS) + 1))
        amplitudes.reserveCapacity(expected)
        spectra.reserveCapacity(expected)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: hopFrames) else {
            return AudioAnalysisResult(waveform: [], spectrumFrames: [])
        }

        while audioFile.framePosition < totalFrames {
            let remaining = totalFrames - audioFile.framePosition
            let count = AVAudioFrameCount(min(AVAudioFramePosition(hopFrames), remaining))
            do {
                try audioFile.read(into: buffer, frameCount: count)
            } catch {
                break
            }
            guard buffer.frameLength > 0 else { break }
            let allSamples = monoSamples(from: buffer)
            guard !allSamples.isEmpty else { continue }

            let rms = sqrt(allSamples.reduce(0.0) { partial, sample in
                partial + Double(sample * sample)
            } / Double(allSamples.count))
            let amplitude = min(1, sqrt(max(0, rms)) * 2.5)
            amplitudes.append(amplitude)

            let samples: [Float]
            if allSamples.count > spectrumWindow {
                let start = max(0, (allSamples.count - spectrumWindow) / 2)
                samples = Array(allSamples[start..<min(allSamples.count, start + spectrumWindow)])
            } else {
                samples = allSamples
            }

            let raw = bandFrequencies.map { frequency in
                frequency < sampleRate * 0.48 ? goertzel(samples: samples, sampleRate: sampleRate, frequency: frequency) : 0
            }
            let peak = max(raw.max() ?? 0, 0.000_001)
            let energy = min(1, max(0.08, amplitude * 1.7))
            spectra.append(raw.map { value in
                let relative = min(1, max(0, value / peak))
                return min(1, pow(relative, 0.42) * (0.15 + 0.85 * energy))
            })
        }

        return AudioAnalysisResult(
            waveform: resample(amplitudes, targetCount: 104),
            spectrumFrames: spectra
        )
    }

    private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frameLength = Int(buffer.frameLength)
        let channels = max(1, Int(buffer.format.channelCount))
        guard frameLength > 0 else { return [] }
        var mono = [Float](repeating: 0, count: frameLength)

        if let data = buffer.floatChannelData {
            for channel in 0..<channels {
                for frame in 0..<frameLength { mono[frame] += data[channel][frame] }
            }
            let divisor = Float(channels)
            for frame in 0..<frameLength { mono[frame] /= divisor }
            return mono
        }
        if let data = buffer.int16ChannelData {
            let scale = Float(Int16.max)
            for channel in 0..<channels {
                for frame in 0..<frameLength { mono[frame] += Float(data[channel][frame]) / scale }
            }
            let divisor = Float(channels)
            for frame in 0..<frameLength { mono[frame] /= divisor }
            return mono
        }
        if let data = buffer.int32ChannelData {
            let scale = Float(Int32.max)
            for channel in 0..<channels {
                for frame in 0..<frameLength { mono[frame] += Float(data[channel][frame]) / scale }
            }
            let divisor = Float(channels)
            for frame in 0..<frameLength { mono[frame] /= divisor }
            return mono
        }
        return []
    }

    private static func goertzel(samples: [Float], sampleRate: Double, frequency: Double) -> Double {
        guard samples.count > 1 else { return 0 }
        let omega = 2 * Double.pi * frequency / sampleRate
        let coefficient = 2 * cos(omega)
        var s1 = 0.0
        var s2 = 0.0
        let denominator = Double(samples.count - 1)
        for (index, value) in samples.enumerated() {
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / denominator)
            let s0 = Double(value) * window + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = max(0, s1 * s1 + s2 * s2 - coefficient * s1 * s2)
        return sqrt(power) / Double(samples.count)
    }

    private static func resample(_ values: [Double], targetCount: Int) -> [Double] {
        guard !values.isEmpty, targetCount > 0 else { return [] }
        if values.count <= targetCount { return normalize(values) }
        var output: [Double] = []
        output.reserveCapacity(targetCount)
        for index in 0..<targetCount {
            let start = index * values.count / targetCount
            let end = max(start + 1, (index + 1) * values.count / targetCount)
            output.append(values[start..<min(end, values.count)].max() ?? 0)
        }
        return normalize(output)
    }

    private static func normalize(_ values: [Double]) -> [Double] {
        let peak = max(values.max() ?? 0, 0.000_001)
        return values.map { min(1, max(0.04, pow($0 / peak, 0.58))) }
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
            .animation(.linear(duration: 0.05), value: bands)
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

private struct TimedCaptionWord: Identifiable, Equatable {
    let id: String
    let text: String
    let start: Double
    let duration: Double
}

private struct AudioCaptionChunk: Sendable {
    let url: URL
    let start: Double
    let isTemporary: Bool
}

private enum AudioCaptionChunker {
    static func makeChunks(url: URL, maxSeconds: Double = 45) throws -> [AudioCaptionChunk] {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let sampleRate = max(1, format.sampleRate)
        let totalFrames = input.length
        let totalDuration = Double(totalFrames) / sampleRate
        if totalDuration <= maxSeconds {
            return [AudioCaptionChunk(url: url, start: 0, isTemporary: false)]
        }

        let framesPerChunk = max(AVAudioFramePosition(1), AVAudioFramePosition((sampleRate * maxSeconds).rounded()))
        var chunks: [AudioCaptionChunk] = []
        var startFrame: AVAudioFramePosition = 0
        let bufferCapacity: AVAudioFrameCount = 8_192

        while startFrame < totalFrames {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("shar-caption-\(UUID().uuidString)")
                .appendingPathExtension("caf")
            let output = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            var remaining = min(framesPerChunk, totalFrames - startFrame)

            while remaining > 0 {
                let count = AVAudioFrameCount(min(AVAudioFramePosition(bufferCapacity), remaining))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { break }
                try input.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                remaining -= AVAudioFramePosition(buffer.frameLength)
            }

            chunks.append(AudioCaptionChunk(
                url: tempURL,
                start: Double(startFrame) / sampleRate,
                isTemporary: true
            ))
            startFrame += framesPerChunk
        }
        return chunks
    }

    static func removeTemporary(_ chunks: [AudioCaptionChunk]) {
        for chunk in chunks where chunk.isTemporary {
            try? FileManager.default.removeItem(at: chunk.url)
        }
    }
}

@MainActor
private enum AudioCaptionMemoryCache {
    static var wordsByPath: [String: [TimedCaptionWord]] = [:]
}

@MainActor
private final class AudioCaptionController: ObservableObject {
    @Published private(set) var words: [TimedCaptionWord] = []
    @Published private(set) var isTranscribing = false
    @Published private(set) var message: String?
    @Published private(set) var canTryAppleOnline = false
    @Published private(set) var progressLabel: String?

    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var activePath: String?

    func prepare(file: SharedFile) {
        activePath = file.url.path
        words = AudioCaptionMemoryCache.wordsByPath[file.url.path] ?? []
        message = nil
        canTryAppleOnline = false
        progressLabel = nil
    }

    func generate(file: SharedFile, allowAppleOnline: Bool = false) {
        let path = file.url.path
        activePath = path
        recognitionTask?.cancel()
        recognitionTask = nil
        message = nil
        canTryAppleOnline = false
        progressLabel = nil
        if allowAppleOnline {
            words = []
            AudioCaptionMemoryCache.wordsByPath[path] = []
        }

        Task {
            let authorization = await requestAuthorization()
            guard activePath == path else { return }
            guard authorization == .authorized else {
                message = "Speech Recognition permission is needed to create captions."
                return
            }
            guard let speechRecognizer = SFSpeechRecognizer(locale: Locale.current), speechRecognizer.isAvailable else {
                message = "Apple Speech is not available for the current language right now."
                return
            }
            if !allowAppleOnline && !speechRecognizer.supportsOnDeviceRecognition {
                message = "On-device captions are unavailable for this language. You can try Apple online transcription instead."
                canTryAppleOnline = true
                return
            }

            recognizer = speechRecognizer
            isTranscribing = true
            var chunks: [AudioCaptionChunk] = []
            do {
                chunks = try await Task.detached(priority: .utility) {
                    try AudioCaptionChunker.makeChunks(url: file.url)
                }.value
                guard activePath == path else {
                    AudioCaptionChunker.removeTemporary(chunks)
                    isTranscribing = false
                    return
                }

                var combined: [TimedCaptionWord] = []
                for (chunkIndex, chunk) in chunks.enumerated() {
                    guard activePath == path else { break }
                    progressLabel = chunks.count > 1 ? "Creating captions \(chunkIndex + 1)/\(chunks.count)…" : "Creating captions…"
                    let chunkWords = try await recognize(
                        chunk: chunk,
                        recognizer: speechRecognizer,
                        requiresOnDevice: !allowAppleOnline
                    )
                    combined.append(contentsOf: chunkWords)
                    words = combined
                    AudioCaptionMemoryCache.wordsByPath[path] = combined
                }

                if activePath == path {
                    if combined.isEmpty {
                        message = allowAppleOnline
                            ? "Apple Speech did not find recognizable speech in this audio. Songs and heavily mixed audio can be difficult to transcribe."
                            : "On-device Speech did not find recognizable speech. You can try Apple online transcription."
                        canTryAppleOnline = !allowAppleOnline
                    } else {
                        message = nil
                    }
                }
            } catch {
                guard activePath == path else {
                    AudioCaptionChunker.removeTemporary(chunks)
                    isTranscribing = false
                    return
                }
                if !allowAppleOnline {
                    message = "On-device transcription could not process this audio. Try Apple online transcription."
                    canTryAppleOnline = true
                } else {
                    message = friendlySpeechError(error)
                }
            }
            AudioCaptionChunker.removeTemporary(chunks)
            if activePath == path {
                isTranscribing = false
                progressLabel = nil
                recognitionTask = nil
            }
        }
    }

    private func recognize(
        chunk: AudioCaptionChunk,
        recognizer speechRecognizer: SFSpeechRecognizer,
        requiresOnDevice: Bool
    ) async throws -> [TimedCaptionWord] {
        let request = SFSpeechURLRecognitionRequest(url: chunk.url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = requiresOnDevice
        request.taskHint = .dictation
        request.addsPunctuation = true

        let words: [TimedCaptionWord] = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognitionTask = speechRecognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                finished = true
                let mapped = result.bestTranscription.segments.enumerated().map { index, segment in
                    TimedCaptionWord(
                        id: "\(chunk.start)-\(index)-\(segment.timestamp)-\(segment.substring)",
                        text: segment.substring,
                        start: chunk.start + segment.timestamp,
                        duration: max(0.05, segment.duration)
                    )
                }
                continuation.resume(returning: mapped)
            }
        }
        recognitionTask = nil
        return words
    }

    private func friendlySpeechError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "kAFAssistantErrorDomain" || ns.domain.localizedCaseInsensitiveContains("speech") {
            return "Apple Speech could not transcribe this audio. Spoken voice works best; music or heavily mixed vocals may still fail."
        }
        return "Captions could not be created: \(error.localizedDescription)"
    }

    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
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

            if captions.canTryAppleOnline && !captions.isTranscribing {
                Button {
                    captions.generate(file: file, allowAppleOnline: true)
                } label: {
                    Label("Try Apple online transcription", systemImage: "icloud.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text("Optional fallback • the audio may be sent to Apple for transcription")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if !captions.words.isEmpty && captions.message == nil {
                Text("Apple Speech captions • best for spoken voice; songs may be imperfect")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
