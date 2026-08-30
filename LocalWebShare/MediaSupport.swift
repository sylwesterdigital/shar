import AVFoundation
import Foundation
import Network
import SwiftUI

struct MediaMetadataInfo: Equatable {
    let title: String?
    let artist: String?
    let artworkData: Data?

    static let empty = MediaMetadataInfo(title: nil, artist: nil, artworkData: nil)
}

enum MediaMetadataReader {
    static func read(_ url: URL) -> MediaMetadataInfo {
        let asset = AVURLAsset(url: url)
        var title: String?
        var artist: String?
        var artwork: Data?

        for item in asset.commonMetadata {
            switch item.commonKey?.rawValue {
            case "title":
                title = item.stringValue ?? title
            case "artist":
                artist = item.stringValue ?? artist
            case "artwork":
                if let data = item.dataValue { artwork = data }
            default:
                break
            }
        }

        return MediaMetadataInfo(title: title, artist: artist, artworkData: artwork)
    }
}

enum ActionLabelMode: String, CaseIterable, Identifiable {
    case text
    case icons
    case compact

    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: return "Text"
        case .icons: return "Icons"
        case .compact: return "Icon + short"
        }
    }
}

enum FileViewMode: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var systemImage: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

enum MediaFilter: String, CaseIterable, Identifiable {
    case all
    case image
    case audio
    case video
    case document
    case file

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .image: return "Images"
        case .audio: return "Audio"
        case .video: return "Video"
        case .document: return "Docs"
        case .file: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .document: return "doc.text"
        case .file: return "doc"
        }
    }

    func matches(_ file: SharedFile) -> Bool {
        switch self {
        case .all: return true
        case .image: return file.mediaKind == .image
        case .audio: return file.mediaKind == .audio
        case .video: return file.mediaKind == .video
        case .document: return file.mediaKind == .document
        case .file: return file.mediaKind == .file
        }
    }
}

enum AppColorTheme: String, CaseIterable, Identifiable {
    case system
    case ocean
    case forest
    case sunset
    case violet

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var accent: Color {
        switch self {
        case .system: return .accentColor
        case .ocean: return Color(red: 0.05, green: 0.48, blue: 0.95)
        case .forest: return Color(red: 0.12, green: 0.58, blue: 0.34)
        case .sunset: return Color(red: 0.94, green: 0.37, blue: 0.19)
        case .violet: return Color(red: 0.52, green: 0.30, blue: 0.93)
        }
    }
}

enum SharProductInfo {
    static let builderName = "MojoWorks"
    static let builderURL = URL(string: "https://mojoworks.xyz/")!
    static let productURL = URL(string: "https://mojoworks.xyz/labs/shar/")!
    static let sourceURL = URL(string: "https://github.com/sylwesterdigital/shar")!
    static let supportURL = URL(string: "https://mojoworks.xyz/labs/shar/support.html")!
}

enum NetworkConnectionKind: String {
    case wifi
    case cellular
    case wired
    case other
    case offline
    case checking

    var title: String {
        switch self {
        case .wifi: return "Wi-Fi connected"
        case .cellular: return "Mobile data connected"
        case .wired: return "Wired network connected"
        case .other: return "Network connected"
        case .offline: return "No network connection"
        case .checking: return "Checking network…"
        }
    }

    var detail: String {
        switch self {
        case .wifi: return "Ready for local browser sharing"
        case .cellular: return "Direct inbound sharing is usually blocked by the mobile carrier; use Wi-Fi or a private tunnel/relay"
        case .wired: return "Ready for local browser sharing"
        case .other: return "Local sharing availability depends on this connection"
        case .offline: return "Enable Wi-Fi or mobile data"
        case .checking: return ""
        }
    }

    var systemImage: String {
        switch self {
        case .wifi: return "wifi"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .wired: return "network"
        case .other: return "network"
        case .offline: return "wifi.slash"
        case .checking: return "ellipsis"
        }
    }
}

@MainActor
final class NetworkStatusMonitor: ObservableObject {
    @Published private(set) var kind: NetworkConnectionKind = .checking
    @Published private(set) var isSatisfied = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "LocalWebShare.NetworkStatus")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let kind: NetworkConnectionKind
            if path.status != .satisfied {
                kind = .offline
            } else if path.usesInterfaceType(.wifi) {
                kind = .wifi
            } else if path.usesInterfaceType(.cellular) {
                kind = .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                kind = .wired
            } else {
                kind = .other
            }
            Task { @MainActor [weak self] in
                self?.kind = kind
                self?.isSatisfied = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}

enum BackgroundAudioSession {
    static func activatePlayback() {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("Shar background audio session error: \(error.localizedDescription)")
        }
#endif
    }
}

@MainActor
final class SharedAudioPlaybackController: ObservableObject {
    @Published private(set) var activeFileID: String?
    @Published private(set) var isPlaying = false

    private var player: AVPlayer?
    private var statusObserver: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?
    private var shouldResumeAfterInterruption = false

    init() {
#if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in self?.handleInterruption(note) }
        }
#endif
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    func toggle(_ file: SharedFile) {
        BackgroundAudioSession.activatePlayback()
        if activeFileID == file.id, let player {
            if player.timeControlStatus == .playing {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
            }
            return
        }

        stop()
        let player = AVPlayer(url: file.url)
        self.player = player
        activeFileID = file.id
        statusObserver = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
        player.play()
        isPlaying = true
    }

    func stop() {
        player?.pause()
        player = nil
        statusObserver = nil
        activeFileID = nil
        isPlaying = false
    }

#if os(iOS)
    private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            shouldResumeAfterInterruption = isPlaying
            player?.pause()
            isPlaying = false
        case .ended:
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if shouldResumeAfterInterruption && options.contains(.shouldResume) {
                BackgroundAudioSession.activatePlayback()
                player?.play()
                isPlaying = true
            }
            shouldResumeAfterInterruption = false
        @unknown default:
            break
        }
    }
#endif

    func isPlaying(_ file: SharedFile) -> Bool {
        activeFileID == file.id && isPlaying
    }
}
