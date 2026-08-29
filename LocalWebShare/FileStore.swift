import Foundation
import Combine

struct SharedFile: Identifiable, Hashable {
    enum MediaKind: String, Codable {
        case image
        case audio
        case video
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

    private static let documentExtensions: Set<String> = [
        "pdf", "txt", "rtf", "html", "htm", "json", "xml", "md", "csv"
    ]

    private static let quickLookFriendlyExtensions = imageExtensions
        .union(audioExtensions)
        .union(videoExtensions)
        .union(documentExtensions)
        .union(["zip"])
}

extension Notification.Name {
    static let localWebShareFilesChanged = Notification.Name("LocalWebShareFilesChanged")
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
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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

    func delete(_ file: SharedFile) {
        do {
            try FileManager.default.removeItem(at: file.url)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
