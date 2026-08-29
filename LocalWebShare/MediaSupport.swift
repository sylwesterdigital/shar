import AVFoundation
import Foundation

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
