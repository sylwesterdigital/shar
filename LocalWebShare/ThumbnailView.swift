import QuickLookThumbnailing
import SwiftUI
import UIKit

struct ThumbnailView: View {
    let file: SharedFile
    var size: CGSize = CGSize(width: 58, height: 58)

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: file.systemImageName)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomTrailing) {
            Text(file.typeLabel)
                .font(.system(size: 8, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(4)
        }
        .task(id: file.id) {
            await loadThumbnail()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sharThreeDThumbnailChanged)) { notification in
            guard file.mediaKind == .threeD,
                  let path = notification.object as? String,
                  path == file.url.path else { return }
            thumbnail = ThreeDThumbnailCache.cachedImage(for: file.url)
        }
    }

    @MainActor
    private func loadThumbnail() async {
        if file.mediaKind == .image, let image = UIImage(contentsOfFile: file.url.path) {
            thumbnail = image
            return
        }

        if file.mediaKind == .audio {
            let data = await Task.detached(priority: .utility) {
                MediaMetadataReader.read(file.url).artworkData
            }.value
            if let data, let image = UIImage(data: data) {
                thumbnail = image
                return
            }
        }

        if file.mediaKind == .threeD {
            if let cached = ThreeDThumbnailCache.cachedImage(for: file.url) {
                thumbnail = cached
                return
            }
            if let rendered = await ThreeDThumbnailCache.generateDefault(for: file.url) {
                thumbnail = rendered
                return
            }
        }

        let scale = UIScreen.main.scale
        let request = QLThumbnailGenerator.Request(
            fileAt: file.url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )

        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            thumbnail = representation.uiImage
        } catch {
            thumbnail = nil
        }
    }
}
