import AVFoundation
import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var fileStore: FileStore
    @EnvironmentObject private var webServer: LocalWebServer
    @EnvironmentObject private var networkMonitor: NetworkStatusMonitor

    @AppStorage("actionLabelMode") private var actionLabelModeRaw = ActionLabelMode.compact.rawValue
    @AppStorage("fileViewMode") private var fileViewModeRaw = FileViewMode.grid.rawValue
    @AppStorage("mediaFilter") private var mediaFilterRaw = MediaFilter.all.rawValue
    @AppStorage("colorTheme") private var colorThemeRaw = AppColorTheme.ocean.rawValue
    @AppStorage("autoStartSharing") private var autoStartSharing = false
    @AppStorage("showFileSizes") private var showFileSizes = true

    @StateObject private var audioPlayback = SharedAudioPlaybackController()
    @State private var selectedFile: SharedFile?
    @State private var filePendingDelete: SharedFile?
    @State private var showingSettings = false
    @State private var copiedAddress = false
    @State private var showingFileImporter = false
    @State private var showingPhotoPicker = false
    @State private var showingVideoCamera = false

    private var actionLabelMode: ActionLabelMode {
        ActionLabelMode(rawValue: actionLabelModeRaw) ?? .compact
    }

    private var fileViewMode: FileViewMode {
        FileViewMode(rawValue: fileViewModeRaw) ?? .grid
    }

    private var mediaFilter: MediaFilter {
        MediaFilter(rawValue: mediaFilterRaw) ?? .all
    }

    private var colorTheme: AppColorTheme {
        AppColorTheme(rawValue: colorThemeRaw) ?? .ocean
    }

    private var filteredFiles: [SharedFile] {
        fileStore.files.filter { mediaFilter.matches($0) }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            NavigationStack {
                VStack(spacing: 0) {
                    sharingStrip
                    Divider()
                    filterStrip
                    Divider()
                    filesContent
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button {
                                showingPhotoPicker = true
                            } label: {
                                Label("Photos & Videos", systemImage: "photo.on.rectangle.angled")
                            }

                            Button {
                                showingVideoCamera = true
                            } label: {
                                Label("Record Video", systemImage: "video.badge.plus")
                            }
                            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                            Button {
                                showingFileImporter = true
                            } label: {
                                Label("Files", systemImage: "folder")
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(colorTheme.accent, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add photos, videos, camera recordings or files")
                    }
                    ToolbarItem(placement: .principal) {
                        Text("Files")
                            .font(.headline)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) { showingSettings = true }
                        } label: {
                            Image(systemName: "gearshape.fill")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .tint(colorTheme.accent)
            .allowsHitTesting(!showingSettings)

            if showingSettings {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.25)) { showingSettings = false }
                    }
                    .transition(.opacity)

                settingsPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .sheet(item: $selectedFile) { file in
            MediaPlayerView(files: filteredFiles, initialFile: file) { deleted in
                fileStore.delete(deleted)
            }
            .tint(colorTheme.accent)
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                urls.forEach { fileStore.importFile(from: $0) }
            case .failure(let error):
                fileStore.lastError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingPhotoPicker) {
            PhotoVideoLibraryPicker(isPresented: $showingPhotoPicker) { url in
                fileStore.importFile(from: url)
            } onError: { message in
                fileStore.lastError = message
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showingVideoCamera) {
            VideoCameraPicker(isPresented: $showingVideoCamera) { url in
                fileStore.importFile(from: url)
            } onError: { message in
                fileStore.lastError = message
            }
            .ignoresSafeArea()
        }
        .confirmationDialog(
            filePendingDelete.map { "Delete \($0.name)?" } ?? "Delete file?",
            isPresented: Binding(
                get: { filePendingDelete != nil },
                set: { if !$0 { filePendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let filePendingDelete {
                    if audioPlayback.activeFileID == filePendingDelete.id { audioPlayback.stop() }
                    fileStore.delete(filePendingDelete)
                }
                filePendingDelete = nil
            }
            Button("Cancel", role: .cancel) { filePendingDelete = nil }
        }
        .alert("Error", isPresented: Binding(
            get: { fileStore.lastError != nil || webServer.lastError != nil },
            set: { isPresented in
                if !isPresented { fileStore.lastError = nil; webServer.lastError = nil }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(fileStore.lastError ?? webServer.lastError ?? "Unknown error")
        }
        .onAppear {
            fileStore.refresh()
            if autoStartSharing, networkMonitor.kind == .wifi, !webServer.isRunning {
                webServer.start()
            }
        }
        .onChange(of: networkMonitor.kind) { _, kind in
            if autoStartSharing, kind == .wifi, !webServer.isRunning {
                webServer.start()
            }
        }
    }

    private var sharingStrip: some View {
        HStack(spacing: 10) {
            Toggle("Sharing", isOn: Binding(
                get: { webServer.isRunning },
                set: { enabled in
                    enabled ? webServer.start() : webServer.stop()
                }
            ))
            .toggleStyle(.switch)
            .font(.subheadline.weight(.semibold))
            .fixedSize()

            Text(webServer.isRunning ? displayAddress : networkMonitor.kind.title)
                .font(.caption.monospaced())
                .foregroundStyle(webServer.isRunning ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                UIPasteboard.general.string = webServer.shareURL
                copiedAddress = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copiedAddress = false
                }
            } label: {
                Image(systemName: copiedAddress ? "checkmark" : "doc.on.doc")
            }
            .disabled(!webServer.isRunning)
            .accessibilityLabel("Copy sharing address")

            ShareLink(item: webServer.shareURL) {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(!webServer.isRunning)
            .accessibilityLabel("Share sharing address")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(colorTheme.accent.opacity(0.075))
    }

    private var filterStrip: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(MediaFilter.allCases) { filter in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                mediaFilterRaw = filter.rawValue
                            }
                        } label: {
                            Label(filter.title, systemImage: filter.systemImage)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    mediaFilter == filter ? colorTheme.accent.opacity(0.18) : Color(uiColor: .secondarySystemGroupedBackground),
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule()
                                        .stroke(mediaFilter == filter ? colorTheme.accent.opacity(0.55) : Color.secondary.opacity(0.16), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 12)
            }

            Text("\(filteredFiles.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.trailing, 12)
        }
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder
    private var filesContent: some View {
        if fileStore.files.isEmpty {
            ContentUnavailableView(
                "No Files Yet",
                systemImage: "folder",
                description: Text("Tap + to choose Photos & Videos, record a video, or import Files. Turn on Sharing to upload from another device.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredFiles.isEmpty {
            ContentUnavailableView(
                "No \(mediaFilter.title)",
                systemImage: mediaFilter.systemImage,
                description: Text("Choose another media filter.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch fileViewMode {
            case .grid:
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(filteredFiles) { file in
                            MediaGridCard(
                                file: file,
                                actionLabelMode: actionLabelMode,
                                showFileSize: showFileSizes,
                                audioPlayback: audioPlayback,
                                onPreview: { openPreview(file) },
                                onDelete: { filePendingDelete = file }
                            )
                        }
                    }
                    .padding(10)
                }
                .refreshable { fileStore.refresh() }
            case .list:
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredFiles) { file in
                            MediaListRow(
                                file: file,
                                actionLabelMode: actionLabelMode,
                                showFileSize: showFileSizes,
                                audioPlayback: audioPlayback,
                                onPreview: { openPreview(file) },
                                onDelete: { filePendingDelete = file }
                            )
                        }
                    }
                    .padding(10)
                }
                .refreshable { fileStore.refresh() }
            }
        }
    }

    private var settingsPanel: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Spacer()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Settings", systemImage: "gearshape.fill")
                                    .font(.title3.bold())
                                Text("Shar · v\(appVersion)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                withAnimation(.snappy(duration: 0.25)) { showingSettings = false }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        settingsSection("Buttons") {
                            Picker("Button labels", selection: $actionLabelModeRaw) {
                                ForEach(ActionLabelMode.allCases) { mode in
                                    Text(mode.title).tag(mode.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        settingsSection("File layout") {
                            Picker("View", selection: $fileViewModeRaw) {
                                ForEach(FileViewMode.allCases) { mode in
                                    Label(mode.title, systemImage: mode.systemImage).tag(mode.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            Toggle("Show file sizes", isOn: $showFileSizes)
                        }

                        settingsSection("Colour theme") {
                            VStack(spacing: 8) {
                                ForEach(AppColorTheme.allCases) { theme in
                                    Button {
                                        colorThemeRaw = theme.rawValue
                                    } label: {
                                        HStack {
                                            Circle()
                                                .fill(theme.accent)
                                                .frame(width: 18, height: 18)
                                            Text(theme.title)
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            if colorTheme == theme {
                                                Image(systemName: "checkmark")
                                                    .foregroundStyle(theme.accent)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        settingsSection("Sharing") {
                            Toggle("Auto-start on Wi-Fi", isOn: $autoStartSharing)
                            HStack {
                                Image(systemName: networkMonitor.kind.systemImage)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(networkMonitor.kind.title)
                                    Text(networkMonitor.kind.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if webServer.isRunning {
                                Text(webServer.shareURL)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }

                        settingsSection("About") {
                            LabeledContent("Version", value: appVersion)
                            Text("Keep the app in the foreground while transferring large files. Local browser sharing requires a reachable local network.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 20)
                }
                .frame(width: min(350, proxy.size.width * 0.88))
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)
                .shadow(radius: 24, x: -8)
            }
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func openPreview(_ file: SharedFile) {
        audioPlayback.stop()
        selectedFile = file
    }

    private var displayAddress: String {
        webServer.shareURL.replacingOccurrences(of: "http://", with: "")
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}

private struct MediaGridCard: View {
    let file: SharedFile
    let actionLabelMode: ActionLabelMode
    let showFileSize: Bool
    @ObservedObject var audioPlayback: SharedAudioPlaybackController
    let onPreview: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onPreview) {
                ThumbnailView(file: file, size: CGSize(width: 172, height: 118))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if file.mediaKind == .audio { AudioMetadataLine(file: file) }
                HStack(spacing: 5) {
                    Text(file.typeLabel)
                    if showFileSize {
                        Text("•")
                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if file.mediaKind == .audio {
                Button {
                    audioPlayback.toggle(file)
                } label: {
                    Label(
                        audioPlayback.isPlaying(file) ? "Pause" : "Play",
                        systemImage: audioPlayback.isPlaying(file) ? "pause.fill" : "play.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                Button(action: onPreview) {
                    ActionLabel(full: "Preview", short: "View", systemImage: "eye", mode: actionLabelMode)
                }
                ShareLink(item: file.url) {
                    ActionLabel(full: "Share", short: "Share", systemImage: "square.and.arrow.up", mode: actionLabelMode)
                }
                Button(role: .destructive, action: onDelete) {
                    ActionLabel(full: "Delete", short: "Del", systemImage: "trash", mode: actionLabelMode)
                }
            }
            .font(.caption2)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(9)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            Button(action: onPreview) { Label("Preview", systemImage: "eye") }
            ShareLink(item: file.url) { Label("Share", systemImage: "square.and.arrow.up") }
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
    }
}

private struct MediaListRow: View {
    let file: SharedFile
    let actionLabelMode: ActionLabelMode
    let showFileSize: Bool
    @ObservedObject var audioPlayback: SharedAudioPlaybackController
    let onPreview: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPreview) {
                ThumbnailView(file: file, size: CGSize(width: 64, height: 64))
            }
            .buttonStyle(.plain)

            Button(action: onPreview) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.name)
                        .foregroundStyle(.primary)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if file.mediaKind == .audio { AudioMetadataLine(file: file) }
                    HStack(spacing: 5) {
                        Text(file.typeLabel)
                        if showFileSize {
                            Text("•")
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if file.mediaKind == .audio {
                Button { audioPlayback.toggle(file) } label: {
                    Image(systemName: audioPlayback.isPlaying(file) ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(audioPlayback.isPlaying(file) ? "Pause \(file.name)" : "Play \(file.name)")
            }

            Menu {
                Button(action: onPreview) { Label("Preview", systemImage: "eye") }
                ShareLink(item: file.url) { Label("Share", systemImage: "square.and.arrow.up") }
                Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct ActionLabel: View {
    let full: String
    let short: String
    let systemImage: String
    let mode: ActionLabelMode

    var body: some View {
        switch mode {
        case .text:
            Text(full)
        case .icons:
            Image(systemName: systemImage).accessibilityLabel(full)
        case .compact:
            Label(short, systemImage: systemImage)
        }
    }
}

private struct AudioMetadataLine: View {
    let file: SharedFile
    @State private var metadata = MediaMetadataInfo.empty

    var body: some View {
        Group {
            if metadata.title != nil || metadata.artist != nil {
                Text([metadata.title, metadata.artist].compactMap { $0 }.joined(separator: " — "))
                    .lineLimit(1)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .task(id: file.id) {
            metadata = await Task.detached(priority: .utility) { MediaMetadataReader.read(file.url) }.value
        }
    }
}


private struct PhotoVideoLibraryPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPicked: (URL) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, onPicked: onPicked, onError: onError)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private var isPresented: Binding<Bool>
        private let onPicked: (URL) -> Void
        private let onError: (String) -> Void

        init(isPresented: Binding<Bool>, onPicked: @escaping (URL) -> Void, onError: @escaping (String) -> Void) {
            self.isPresented = isPresented
            self.onPicked = onPicked
            self.onError = onError
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            isPresented.wrappedValue = false
            for result in results {
                importResult(result)
            }
        }

        private func importResult(_ result: PHPickerResult) {
            let provider = result.itemProvider
            let typeIdentifier: String
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                typeIdentifier = UTType.movie.identifier
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                typeIdentifier = UTType.image.identifier
            } else {
                DispatchQueue.main.async { self.onError("The selected Photos item is not an image or video.") }
                return
            }

            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] sourceURL, error in
                guard let self else { return }
                if let error {
                    DispatchQueue.main.async { self.onError(error.localizedDescription) }
                    return
                }
                guard let sourceURL else {
                    DispatchQueue.main.async { self.onError("Photos could not provide the selected item.") }
                    return
                }

                do {
                    let temporaryURL = try Self.makeTemporaryCopy(
                        from: sourceURL,
                        suggestedName: provider.suggestedName
                    )
                    DispatchQueue.main.async {
                        self.onPicked(temporaryURL)
                        try? FileManager.default.removeItem(at: temporaryURL.deletingLastPathComponent())
                    }
                } catch {
                    DispatchQueue.main.async { self.onError(error.localizedDescription) }
                }
            }
        }

        private static func makeTemporaryCopy(from sourceURL: URL, suggestedName: String?) throws -> URL {
            let fm = FileManager.default
            var filename = (suggestedName ?? sourceURL.lastPathComponent)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if filename.isEmpty { filename = "Shar Media" }
            if URL(fileURLWithPath: filename).pathExtension.isEmpty, !sourceURL.pathExtension.isEmpty {
                filename += ".\(sourceURL.pathExtension)"
            }
            let directory = fm.temporaryDirectory
                .appendingPathComponent("SharPhotoImports", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(filename)
            try fm.copyItem(at: sourceURL, to: destination)
            return destination
        }
    }
}

private struct VideoCameraPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPicked: (URL) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, onPicked: onPicked, onError: onError)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 600
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private var isPresented: Binding<Bool>
        private let onPicked: (URL) -> Void
        private let onError: (String) -> Void

        init(isPresented: Binding<Bool>, onPicked: @escaping (URL) -> Void, onError: @escaping (String) -> Void) {
            self.isPresented = isPresented
            self.onPicked = onPicked
            self.onError = onError
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            isPresented.wrappedValue = false
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let sourceURL = info[.mediaURL] as? URL else {
                isPresented.wrappedValue = false
                onError("The camera did not return a recorded video.")
                return
            }

            do {
                let fm = FileManager.default
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
                let filename = "Shar Video \(formatter.string(from: Date())).mov"
                let directory = fm.temporaryDirectory.appendingPathComponent("SharCamera", isDirectory: true)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(filename)
                try? fm.removeItem(at: destination)
                try fm.copyItem(at: sourceURL, to: destination)
                onPicked(destination)
                try? fm.removeItem(at: destination)
            } catch {
                onError(error.localizedDescription)
            }
            isPresented.wrappedValue = false
        }
    }
}
