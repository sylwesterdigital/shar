import Foundation
import AVKit
import QuickLook
import SwiftUI
import UIKit

struct MediaPlayerView: View {
    let file: SharedFile
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var showDeleteConfirmation = false

    init(file: SharedFile, onDelete: (() -> Void)? = nil) {
        self.file = file
        self.onDelete = onDelete
        _player = State(initialValue: file.isPlayableMedia ? AVPlayer(url: file.url) : nil)
    }

    var body: some View {
        NavigationStack {
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
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: file.url) {
                        Image(systemName: "square.and.arrow.up")
                    }

                    if onDelete != nil {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete \(file.name)?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    onDelete?()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            .onDisappear {
                player?.pause()
            }
        }
    }

    private var imagePreview: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                if let image = UIImage(contentsOfFile: file.url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            minWidth: proxy.size.width,
                            minHeight: proxy.size.height
                        )
                } else {
                    ContentUnavailableView("Cannot Preview Image", systemImage: "photo.badge.exclamationmark")
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .background(Color.black)
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

            ThumbnailView(file: file, size: CGSize(width: 180, height: 180))

            VStack(spacing: 8) {
                Text(file.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            if let player {
                AudioControls(player: player)
            }

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
            Task {
                if let item = player.currentItem,
                   let loadedDuration = try? await item.asset.load(.duration) {
                    let seconds = loadedDuration.seconds
                    if seconds.isFinite {
                        duration = seconds
                    }
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
            if let observer {
                player.removeTimeObserver(observer)
                self.observer = nil
            }
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

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
