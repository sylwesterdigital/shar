import Foundation
import AVFoundation

struct SharAudioAnalysisResult: Sendable {
    let waveform: [Double]
    let spectrumFrames: [[Double]]
}

enum SharAudioAnalyzer {
    private static let bandFrequencies: [Double] = (0..<20).map { index in
        let low = 55.0
        let high = 16_000.0
        let fraction = Double(index) / 19.0
        return low * pow(high / low, fraction)
    }

    static func analyze(url: URL) -> SharAudioAnalysisResult {
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            return SharAudioAnalysisResult(waveform: [], spectrumFrames: [])
        }
        let format = audioFile.processingFormat
        let sampleRate = max(1, format.sampleRate)
        let totalFrames = max(1, audioFile.length)
        let duration = Double(totalFrames) / sampleRate
        let targetFPS = min(24.0, max(10.0, 24_000.0 / max(duration, 1)))
        let hopFrames = max(AVAudioFrameCount(512), AVAudioFrameCount((sampleRate / targetFPS).rounded()))
        let spectrumWindow = 1024
        var amplitudes: [Double] = []
        var spectra: [[Double]] = []
        let expected = min(24_000, max(1, Int(duration * targetFPS) + 1))
        amplitudes.reserveCapacity(expected)
        spectra.reserveCapacity(expected)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: hopFrames) else {
            return SharAudioAnalysisResult(waveform: [], spectrumFrames: [])
        }
        while audioFile.framePosition < totalFrames {
            let remaining = totalFrames - audioFile.framePosition
            let count = AVAudioFrameCount(min(AVAudioFramePosition(hopFrames), remaining))
            do { try audioFile.read(into: buffer, frameCount: count) } catch { break }
            guard buffer.frameLength > 0 else { break }
            let allSamples = monoSamples(from: buffer)
            guard !allSamples.isEmpty else { continue }
            let rms = sqrt(allSamples.reduce(0.0) { $0 + Double($1 * $1) } / Double(allSamples.count))
            let amplitude = min(1, sqrt(max(0, rms)) * 2.7)
            amplitudes.append(amplitude)
            let countForSpectrum = min(spectrumWindow, allSamples.count)
            let start = max(0, (allSamples.count - countForSpectrum) / 2)
            let samples = Array(allSamples[start..<(start + countForSpectrum)])
            let raw = bandFrequencies.map { frequency in
                frequency < sampleRate * 0.48 ? goertzel(samples: samples, sampleRate: sampleRate, frequency: frequency) : 0
            }
            let peak = max(raw.max() ?? 0, 0.000_001)
            let energy = min(1, max(0.03, amplitude * 1.9))
            spectra.append(raw.map { min(1, pow(min(1, max(0, $0 / peak)), 0.50) * (0.03 + 0.97 * energy)) })
        }
        return SharAudioAnalysisResult(waveform: resample(amplitudes, targetCount: 104), spectrumFrames: spectra)
    }

    static func spectrum(frames: [[Double]], progress: Double) -> [Double] {
        guard let first = frames.first else { return Array(repeating: 0.05, count: 20) }
        guard frames.count > 1 else { return first }
        let clamped = min(max(progress, 0), 1)
        let exact = Double(frames.count - 1) * clamped
        let lower = min(frames.count - 1, Int(floor(exact)))
        let upper = min(frames.count - 1, lower + 1)
        let mix = exact - Double(lower)
        guard lower != upper else { return frames[lower] }
        let a = frames[lower], b = frames[upper]
        return (0..<min(a.count, b.count)).map { a[$0] + (b[$0] - a[$0]) * mix }
    }

    private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = max(1, Int(buffer.format.channelCount))
        guard frames > 0 else { return [] }
        var mono = [Float](repeating: 0, count: frames)
        if let data = buffer.floatChannelData {
            for c in 0..<channels { for i in 0..<frames { mono[i] += data[c][i] } }
            let d = Float(channels); for i in 0..<frames { mono[i] /= d }; return mono
        }
        if let data = buffer.int16ChannelData {
            let scale = Float(Int16.max)
            for c in 0..<channels { for i in 0..<frames { mono[i] += Float(data[c][i]) / scale } }
            let d = Float(channels); for i in 0..<frames { mono[i] /= d }; return mono
        }
        if let data = buffer.int32ChannelData {
            let scale = Float(Int32.max)
            for c in 0..<channels { for i in 0..<frames { mono[i] += Float(data[c][i]) / scale } }
            let d = Float(channels); for i in 0..<frames { mono[i] /= d }; return mono
        }
        return []
    }

    private static func goertzel(samples: [Float], sampleRate: Double, frequency: Double) -> Double {
        guard samples.count > 1 else { return 0 }
        let omega = 2 * Double.pi * frequency / sampleRate
        let coefficient = 2 * cos(omega)
        var s1 = 0.0, s2 = 0.0
        let denominator = Double(samples.count - 1)
        for (index, value) in samples.enumerated() {
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / denominator)
            let s0 = Double(value) * window + coefficient * s1 - s2
            s2 = s1; s1 = s0
        }
        return sqrt(max(0, s1 * s1 + s2 * s2 - coefficient * s1 * s2)) / Double(samples.count)
    }

    private static func resample(_ values: [Double], targetCount: Int) -> [Double] {
        guard !values.isEmpty, targetCount > 0 else { return [] }
        if values.count <= targetCount { return normalize(values) }
        var out: [Double] = []; out.reserveCapacity(targetCount)
        for i in 0..<targetCount {
            let start = i * values.count / targetCount
            let end = max(start + 1, (i + 1) * values.count / targetCount)
            out.append(values[start..<min(end, values.count)].max() ?? 0)
        }
        return normalize(out)
    }

    private static func normalize(_ values: [Double]) -> [Double] {
        let peak = max(values.max() ?? 0, 0.000_001)
        return values.map { min(1, max(0.04, pow($0 / peak, 0.58))) }
    }
}

struct SharTimedCaptionWord: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let start: Double
    let duration: Double
}

private struct SharWhisperSegment {
    let start: Double
    let end: Double
    let text: String
}

@_silgen_name("shar_whisper_runtime_available")
private func shar_whisper_runtime_available() -> Int32
@_silgen_name("shar_whisper_create")
private func shar_whisper_create(_ modelPath: UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
@_silgen_name("shar_whisper_destroy")
private func shar_whisper_destroy(_ handle: UnsafeMutableRawPointer?)
@_silgen_name("shar_whisper_transcribe")
private func shar_whisper_transcribe(_ handle: UnsafeMutableRawPointer?, _ samples: UnsafePointer<Float>?, _ sampleCount: Int32) -> UnsafeMutablePointer<CChar>?
@_silgen_name("shar_whisper_free_text")
private func shar_whisper_free_text(_ text: UnsafeMutablePointer<CChar>?)

enum SharLocalWhisperTranscriber {
    static let engineLabel = "Whisper · local"

    static func bundledModelURL() -> URL? {
        Bundle.main.url(forResource: "ggml-base", withExtension: "bin", subdirectory: "WhisperModels")
            ?? Bundle.main.url(forResource: "ggml-base", withExtension: "bin")
    }

    static func transcribe(url: URL, progress: @escaping @Sendable (Int, Int) -> Void) throws -> [SharTimedCaptionWord] {
        guard shar_whisper_runtime_available() != 0 else {
            throw NSError(domain: "SharLocalWhisper", code: 7, userInfo: [NSLocalizedDescriptionKey: "The bundled local Whisper runtime is not compatible with this OS/device. Shar did not upload any audio."])
        }
        guard let modelURL = bundledModelURL() else {
            throw NSError(domain: "SharLocalWhisper", code: 1, userInfo: [NSLocalizedDescriptionKey: "The bundled local transcription model is missing."])
        }
        let handle: UnsafeMutableRawPointer? = modelURL.path.withCString { shar_whisper_create($0) }
        guard let handle else {
            throw NSError(domain: "SharLocalWhisper", code: 2, userInfo: [NSLocalizedDescriptionKey: "The local Whisper model could not be loaded."])
        }
        defer { shar_whisper_destroy(handle) }

        let chunks = try pcmChunks(url: url, maxSeconds: 30)
        var words: [SharTimedCaptionWord] = []
        for (index, chunk) in chunks.enumerated() {
            progress(index + 1, chunks.count)
            let raw: UnsafeMutablePointer<CChar>? = chunk.samples.withUnsafeBufferPointer { ptr in
                shar_whisper_transcribe(handle, ptr.baseAddress, Int32(clamping: ptr.count))
            }
            guard let raw else { continue }
            let text = String(cString: raw)
            shar_whisper_free_text(raw)
            for segment in parseSegments(text) {
                words.append(contentsOf: wordsFromSegment(segment, offset: chunk.start))
            }
        }
        return words.sorted { $0.start < $1.start }
    }

    private struct PCMChunk {
        let start: Double
        let samples: [Float]
    }

    private static func pcmChunks(url: URL, maxSeconds: Double) throws -> [PCMChunk] {
        let input = try AVAudioFile(forReading: url)
        let sourceFormat = input.processingFormat
        let sourceRate = max(1, sourceFormat.sampleRate)
        let totalFrames = input.length
        let framesPerChunk = max(AVAudioFramePosition(1), AVAudioFramePosition((sourceRate * maxSeconds).rounded()))
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            throw NSError(domain: "SharLocalWhisper", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create the local transcription audio format."])
        }
        var chunks: [PCMChunk] = []
        var startFrame: AVAudioFramePosition = 0
        while startFrame < totalFrames {
            input.framePosition = startFrame
            let count = AVAudioFrameCount(min(framesPerChunk, totalFrames - startFrame))
            guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: count) else { break }
            try input.read(into: source, frameCount: count)
            guard source.frameLength > 0 else { break }
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw NSError(domain: "SharLocalWhisper", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not prepare audio for local transcription."])
            }
            let targetCapacity = AVAudioFrameCount(max(1, Int(ceil(Double(source.frameLength) * targetFormat.sampleRate / sourceRate)) + 2048))
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else { break }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, state in
                if supplied { state.pointee = .endOfStream; return nil }
                supplied = true; state.pointee = .haveData; return source
            }
            if status == .error { throw conversionError ?? NSError(domain: "SharLocalWhisper", code: 5) }
            guard let data = converted.floatChannelData else { break }
            let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength)))
            chunks.append(PCMChunk(start: Double(startFrame) / sourceRate, samples: samples))
            startFrame += AVAudioFramePosition(source.frameLength)
        }
        if chunks.isEmpty { throw NSError(domain: "SharLocalWhisper", code: 6, userInfo: [NSLocalizedDescriptionKey: "No audio could be prepared for local transcription."]) }
        return chunks
    }

    private static func parseSegments(_ text: String) -> [SharWhisperSegment] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { row in
            let parts = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let startMs = Double(parts[0]), let endMs = Double(parts[1]) else { return nil }
            return SharWhisperSegment(start: startMs / 1000.0, end: max(startMs, endMs) / 1000.0, text: String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { !$0.text.isEmpty }
    }

    private static func wordsFromSegment(_ segment: SharWhisperSegment, offset: Double) -> [SharTimedCaptionWord] {
        let tokens = segment.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let duration = max(0.12, segment.end - segment.start)
        let totalWeight = max(1, tokens.reduce(0) { $0 + max(1, $1.count) })
        var cursor = segment.start
        return tokens.enumerated().map { index, token in
            let weight = max(1, token.count)
            let tokenDuration = duration * Double(weight) / Double(totalWeight)
            let item = SharTimedCaptionWord(id: "\(offset)-\(segment.start)-\(index)-\(token)", text: token, start: offset + cursor, duration: max(0.06, tokenDuration))
            cursor += tokenDuration
            return item
        }
    }
}
