import Foundation
import Combine

struct SharedFile: Identifiable, Hashable {
    enum MediaKind: String, Codable {
        case image
        case audio
        case video
        case threeD
        case document
        case file
    }

    let url: URL
    let size: Int64
    let modifiedAt: Date?

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.lowercased() }

    var mediaKind: MediaKind {
        if Self.imageExtensions.contains(fileExtension) { return .image }
        if Self.audioExtensions.contains(fileExtension) { return .audio }
        if Self.videoExtensions.contains(fileExtension) { return .video }
        if Self.threeDExtensions.contains(fileExtension) { return .threeD }
        if Self.documentExtensions.contains(fileExtension) { return .document }
        return .file
    }

    var isPlayableMedia: Bool {
        mediaKind == .audio || mediaKind == .video
    }

    var canPreview: Bool {
        mediaKind != .file || Self.quickLookFriendlyExtensions.contains(fileExtension)
    }

    var systemImageName: String {
        switch mediaKind {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .threeD: return "cube.transparent"
        case .document: return "doc.text"
        case .file: return "doc"
        }
    }

    var typeLabel: String {
        if !fileExtension.isEmpty { return fileExtension.uppercased() }
        return mediaKind.rawValue.capitalized
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"
    ]

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac"
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mpeg", "mpg"
    ]

    static let threeDExtensions: Set<String> = [
        "glb", "gltf",
        "usd", "usda", "usdc", "usdz",
        "obj", "stl", "ply", "abc", "dae",
        "fbx", "3ds", "3mf", "blend",
        "step", "stp", "iges", "igs"
    ]

    private static let documentExtensions: Set<String> = [
        "pdf", "txt", "rtf", "html", "htm", "json", "xml", "md", "csv"
    ]

    private static let quickLookFriendlyExtensions = imageExtensions
        .union(audioExtensions)
        .union(videoExtensions)
        .union(threeDExtensions)
        .union(documentExtensions)
        .union(["zip"])
}

extension Notification.Name {
    static let localWebShareFilesChanged = Notification.Name("LocalWebShareFilesChanged")
    static let sharThreeDThumbnailChanged = Notification.Name("SharThreeDThumbnailChanged")
}

@MainActor
final class FileStore: ObservableObject {
    @Published private(set) var files: [SharedFile] = []
    @Published var lastError: String?

    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: .localWebShareFilesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    nonisolated static var documentsDirectory: URL {
#if os(macOS)
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalWebShare", isDirectory: true)
            .appendingPathComponent("Shared", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
#else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
#endif
    }

    func refresh() {
        do {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: Self.documentsDirectory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )

            files = urls.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true else {
                    return nil
                }
                return SharedFile(
                    url: url,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func importFile(from sourceURL: URL) {
        do {
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

            let name = sourceURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let destination = uniqueDestination(for: name)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            refresh()
            if SharedFile.threeDExtensions.contains(destination.pathExtension.lowercased()) {
                Task { @MainActor in
                    _ = await ThreeDThumbnailCache.generateDefault(for: destination)
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func uniqueDestination(for filename: String) -> URL {
        let proposed = Self.documentsDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }
        let ext = proposed.pathExtension
        let base = proposed.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let newName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = Self.documentsDirectory.appendingPathComponent(newName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    func delete(_ file: SharedFile) {
        do {
            try FileManager.default.removeItem(at: file.url)
            if file.mediaKind == .threeD { ThreeDThumbnailCache.remove(for: file.url) }
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
