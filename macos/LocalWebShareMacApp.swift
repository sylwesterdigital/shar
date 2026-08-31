import AppKit
import AVFoundation
import AVKit
import QuickLookUI
import SwiftUI
import WebKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

@main
struct LocalWebShareMacApp: App {
    @StateObject private var fileStore = FileStore()
    @StateObject private var webServer = LocalWebServer()
    var body: some Scene {
        WindowGroup {
            MacContentView()
                .environmentObject(fileStore)
                .environmentObject(webServer)
                .frame(minWidth: 860, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Shar") {
                    MacAboutPanelController.shared.show()
                }
            }
        }
    }
}

struct MacContentView: View {
    @EnvironmentObject private var fileStore: FileStore
    @EnvironmentObject private var webServer: LocalWebServer
    @AppStorage("actionLabelMode") private var actionLabelModeRaw = ActionLabelMode.compact.rawValue
    @AppStorage("macFileViewMode") private var fileViewModeRaw = FileViewMode.grid.rawValue
    @AppStorage("macMediaFilter") private var mediaFilterRaw = MediaFilter.all.rawValue
    @AppStorage("macShowFileSizes") private var showFileSizes = true
    @AppStorage("macColorTheme") private var colorThemeRaw = AppColorTheme.system.rawValue
    @AppStorage("showDeveloperInfo") private var showDeveloperInfo = false
    @StateObject private var audioPlayback = SharedAudioPlaybackController()
    @State private var selectedFile: SharedFile?
    @State private var deleteCandidate: SharedFile?
    @State private var isDropTargeted = false
    @State private var showingDeveloperUpdates = false
    @State private var showingSettings = false
    @State private var remoteShareFile: SharedFile?
    @State private var copiedAddress = false

    private var mode: ActionLabelMode { ActionLabelMode(rawValue: actionLabelModeRaw) ?? .compact }
    private var fileViewMode: FileViewMode { FileViewMode(rawValue: fileViewModeRaw) ?? .grid }
    private var mediaFilter: MediaFilter { MediaFilter(rawValue: mediaFilterRaw) ?? .all }
    private var colorTheme: AppColorTheme { AppColorTheme(rawValue: colorThemeRaw) ?? .system }
    private var filteredFiles: [SharedFile] { fileStore.files.filter { mediaFilter.matches($0) } }

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                topBar
                Divider()
                sharingStrip
                Divider()
                filterStrip
                Divider()
                filesContent
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .allowsHitTesting(!showingSettings)
            .opacity(showingSettings ? 0.92 : 1)
            .dropDestination(for: URL.self) { urls, _ in
                urls.forEach { fileStore.importFile(from: $0) }
                return !urls.isEmpty
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(colorTheme.accent, style: StrokeStyle(lineWidth: 3, dash: [9, 7]))
                        .padding(12)
                        .background(colorTheme.accent.opacity(0.08))
                        .allowsHitTesting(false)
                }
            }

            if showingSettings {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { showingSettings = false } }
                settingsPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .tint(colorTheme.accent)
        .sheet(item: $selectedFile) { file in
            MacMediaGallery(files: filteredFiles, initialFile: file, audioPlayback: audioPlayback) { deleted in
                if audioPlayback.activeFileID == deleted.id { audioPlayback.stop() }
                fileStore.delete(deleted)
            }
                .frame(minWidth: 760, minHeight: 560)
        }
        .sheet(item: $remoteShareFile) { file in
            MacRemoteShareSheet(file: file)
                .frame(width: 700, height: 670)
        }
        .sheet(isPresented: $showingDeveloperUpdates) {
            MacDeveloperUpdatesView()
                .frame(minWidth: 520, minHeight: 430)
        }
        .confirmationDialog(deleteCandidate.map { "Delete \($0.name)?" } ?? "Delete file?", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } })) {
            Button("Delete", role: .destructive) {
                if let f = deleteCandidate {
                    if audioPlayback.activeFileID == f.id { audioPlayback.stop() }
                    fileStore.delete(f)
                }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { chooseFiles() } label: {
                Image(systemName: "plus.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .help("Import files")

            if let image = Bundle.main.url(forResource: "shar-logo-1024", withExtension: "png").flatMap(NSImage.init(contentsOf:)) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: 9))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Shar").font(.title2.bold())
                Text("Local + secure remote sharing").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { NSWorkspace.shared.open(FileStore.documentsDirectory) } label: { Image(systemName: "folder") }
                .buttonStyle(.plain).help("Show shared folder")
            Button { fileStore.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Refresh")
            if showDeveloperInfo {
                Button { showingDeveloperUpdates = true } label: {
                    Image(systemName: "info.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .help("Developer updates")
            }
            Button { NSWorkspace.shared.open(SharProductInfo.supportURL) } label: {
                Image(systemName: "dollarsign.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .help("Support Shar")
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showingSettings = true }
            } label: {
                Image(systemName: "gearshape.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .help("Config")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var sharingStrip: some View {
        HStack(spacing: 12) {
            Toggle("Sharing", isOn: Binding(
                get: { webServer.isRunning },
                set: { enabled in enabled ? webServer.start() : webServer.stop() }
            ))
            .toggleStyle(.switch)
            .fontWeight(.semibold)

            if webServer.isRunning {
                Text(webServer.shareURL.replacingOccurrences(of: "http://", with: ""))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text(webServer.statusMessage).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(webServer.shareURL, forType: .string)
                copiedAddress = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedAddress = false }
            } label: { Image(systemName: copiedAddress ? "checkmark" : "doc.on.doc") }
                .disabled(!webServer.isRunning)
                .help("Copy sharing address")
            ShareLink(item: webServer.shareURL) { Image(systemName: "square.and.arrow.up") }
                .disabled(!webServer.isRunning)
                .help("Share sharing address")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(colorTheme.accent.opacity(0.065))
    }

    private var filterStrip: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(MediaFilter.allCases) { filter in
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) { mediaFilterRaw = filter.rawValue }
                        } label: {
                            Label(filter.title, systemImage: filter.systemImage)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(mediaFilter == filter ? colorTheme.accent.opacity(0.18) : Color(nsColor: .controlBackgroundColor), in: Capsule())
                                .overlay { Capsule().stroke(mediaFilter == filter ? colorTheme.accent.opacity(0.55) : Color.secondary.opacity(0.16), lineWidth: 1) }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 18)
            }
            Text("\(filteredFiles.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Picker("View", selection: $fileViewModeRaw) {
                ForEach(FileViewMode.allCases) { view in
                    Image(systemName: view.systemImage).tag(view.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 82)
            .padding(.trailing, 18)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var filesContent: some View {
        if fileStore.files.isEmpty {
            MacEmptyStateView(title: "No Files Yet", systemImage: "folder", message: "Click + or drop files into Shar. Turn on Sharing to upload from another device on the LAN.")
        } else if filteredFiles.isEmpty {
            MacEmptyStateView(title: "No \(mediaFilter.title)", systemImage: mediaFilter.systemImage, message: "Choose another media filter.")
        } else {
            switch fileViewMode {
            case .grid:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 12)], spacing: 12) {
                        ForEach(filteredFiles) { file in
                            MacLibraryGridCard(file: file, mode: mode, showFileSize: showFileSizes, audioPlayback: audioPlayback, onPreview: { selectedFile = file }, onRemote: { openRemoteShare(file) }, onDelete: { deleteCandidate = file })
                        }
                    }
                    .padding(14)
                }
            case .list:
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredFiles) { file in
                            MacLibraryListRow(file: file, mode: mode, showFileSize: showFileSizes, audioPlayback: audioPlayback, onPreview: { selectedFile = file }, onRemote: { openRemoteShare(file) }, onDelete: { deleteCandidate = file })
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Config", systemImage: "gearshape.fill").font(.title2.bold())
                        Text("Shar · v\(appVersion)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.18)) { showingSettings = false } } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }

                macSettingsSection("Buttons") {
                    Picker("Button labels", selection: $actionLabelModeRaw) {
                        ForEach(ActionLabelMode.allCases) { option in Text(option.title).tag(option.rawValue) }
                    }.pickerStyle(.segmented)
                }

                macSettingsSection("File layout") {
                    Picker("View", selection: $fileViewModeRaw) {
                        ForEach(FileViewMode.allCases) { option in Label(option.title, systemImage: option.systemImage).tag(option.rawValue) }
                    }.pickerStyle(.segmented)
                    Toggle("Show file sizes", isOn: $showFileSizes)
                }

                macSettingsSection("Colour theme") {
                    ForEach(AppColorTheme.allCases) { theme in
                        Button { colorThemeRaw = theme.rawValue } label: {
                            HStack {
                                Circle().fill(theme.accent).frame(width: 16, height: 16)
                                Text(theme.title).foregroundStyle(.primary)
                                Spacer()
                                if colorTheme == theme { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
                            }
                        }.buttonStyle(.plain)
                    }
                }

                macSettingsSection("Developer") {
                    Toggle("Show ⓘ developer updates", isOn: $showDeveloperInfo)
                }

                macSettingsSection("Sharing") {
                    Text(webServer.isRunning ? webServer.shareURL : "LAN browser sharing is off")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Show Shared Folder") { NSWorkspace.shared.open(FileStore.documentsDirectory) }
                }

                macSettingsSection("About & Support") {
                    HStack { Text("Version"); Spacer(); Text(appShortVersion).monospacedDigit() }
                    HStack { Text("Build"); Spacer(); Text(appBuild).monospacedDigit() }
                    Divider()
                    HStack { Text("Company"); Spacer(); Link(SharProductInfo.builderName, destination: SharProductInfo.builderURL) }
                    Text(SharProductInfo.copyrightLine).font(.caption).foregroundStyle(.secondary)
                    Link(destination: SharProductInfo.productURL) { Label("Shar website", systemImage: "globe") }
                    Link(destination: SharProductInfo.sourceURL) { Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Link(destination: SharProductInfo.supportURL) {
                        Label("Support Shar", systemImage: "heart.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Support opens Shar's Stripe-backed support checkout. Shar never receives card details.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(22)
        }
        .frame(width: 390)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .shadow(radius: 22, x: -8)
    }

    private func macSettingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach { fileStore.importFile(from: $0) } }
    }

    private func openRemoteShare(_ file: SharedFile) { remoteShareFile = file }
    private var appShortVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    private var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
    private var appVersion: String { "\(appShortVersion) (\(appBuild))" }
}


private struct MacRemoteShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: SharedFile
    @StateObject private var remote: MacNativeRemoteShareCoordinator

    init(file: SharedFile) {
        self.file = file
        _remote = StateObject(wrappedValue: MacNativeRemoteShareCoordinator(file: file))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Secure Remote Share").font(.title2.bold())
                    Text("End-to-end encrypted Internet sharing").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    remote.cancel()
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close remote share")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            Divider()

            VStack(spacing: 11) {
                fileAndStatus
                if !remote.pinCode.isEmpty { securityCard }
                if remote.approvalPending { approvalCard }
                if let receiverURL = remote.receiverURL { qrCard(receiverURL) }

                if remote.progress > 0 || remote.isTransferring {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: remote.progress)
                        HStack {
                            Text(remote.progressLabel)
                            Spacer()
                            Text("\(Int((remote.progress * 100).rounded()))%")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                }

                if remote.errorMessage != nil {
                    Button { remote.retry() } label: {
                        Label("Retry secure share", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()
            actionBar
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .background {
            MacNativeRemoteEngineView(coordinator: remote)
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .task { remote.start() }
        .onDisappear { remote.cancel() }
    }

    private var fileAndStatus: some View {
        HStack(spacing: 12) {
            MacThumbnail(file: file, size: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.headline).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                Image(systemName: remote.statusSymbol)
                    .foregroundStyle(remote.errorMessage == nil ? Color.accentColor : Color.red)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(remote.status).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let detail = remote.errorMessage {
                        Text(detail).font(.caption).foregroundStyle(.red).lineLimit(2)
                    } else if let expires = remote.expiresAt {
                        Text("Expires \(expires, style: .relative)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var securityCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Receiver PIN").font(.caption).foregroundStyle(.secondary)
                Text(remote.formattedPIN)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(remote.pinCode, forType: .string)
                    remote.markPinCopied()
                } label: {
                    Label(remote.didCopyPIN ? "Copied" : "Copy PIN", systemImage: remote.didCopyPIN ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 104, minHeight: 26)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Text("AES-256-GCM · SHA-256 · approval · 1 receiver · 30 min")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var approvalCard: some View {
        HStack(spacing: 12) {
            Label("Receiver entered the PIN", systemImage: "person.crop.circle.badge.questionmark")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button(role: .destructive) { remote.resolveApproval(approved: false) } label: {
                Label("Reject", systemImage: "xmark").frame(minWidth: 80, minHeight: 24)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Button { remote.resolveApproval(approved: true) } label: {
                Label("Approve", systemImage: "checkmark.shield").frame(minWidth: 92, minHeight: 24)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func qrCard(_ url: URL) -> some View {
        HStack(spacing: 18) {
            if let image = MacNativeRemoteShareQR.image(for: url.absoluteString) {
                image
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 214, height: 214)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 9) {
                Label("Scan or send the link", systemImage: "qrcode")
                    .font(.headline)
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .lineLimit(7)
                Spacer(minLength: 0)
                Text("The encryption key stays in the URL fragment and is never sent to Shar's server. Send the PIN separately when practical.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: 214, alignment: .topLeading)
        }
        .padding(11)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var actionBar: some View {
        if let url = remote.receiverURL {
            HStack(spacing: 12) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    remote.markCopied()
                } label: {
                    Label(remote.didCopy ? "Copied" : "Copy link", systemImage: remote.didCopy ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button { MacNativeSharing.present(url: url) } label: {
                    Label("Share link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(role: .destructive) {
                    remote.cancel()
                    dismiss()
                } label: {
                    Label("Cancel share", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        } else {
            HStack(spacing: 12) {
                if remote.errorMessage != nil {
                    Button { remote.retry() } label: {
                        Label("Retry", systemImage: "arrow.clockwise").frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button(role: .destructive) {
                    remote.cancel()
                    dismiss()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle").frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }
}

private enum MacNativeSharing {
    static func present(url: URL) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let anchor = window.contentView else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            return
        }
        let picker = NSSharingServicePicker(items: [url])
        let rect = NSRect(x: anchor.bounds.midX, y: anchor.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
    }
}

private enum MacNativeRemoteShareQR {
    static func image(for string: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 9, y: 9)) else { return nil }
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return Image(nsImage: NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height)))
    }
}

private struct MacNativeRemoteEngineView: NSViewRepresentable {
    @ObservedObject var coordinator: MacNativeRemoteShareCoordinator
    func makeNSView(context: Context) -> WKWebView { coordinator.makeWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private final class MacNativeRemoteShareCoordinator: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published private(set) var status = "Preparing secure remote share…"
    @Published private(set) var receiverURL: URL?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var progress: Double = 0
    @Published private(set) var transferred: Int64 = 0
    @Published private(set) var isTransferring = false
    @Published private(set) var isWorking = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var didCopy = false
    @Published private(set) var didCopyPIN = false
    @Published private(set) var pinCode = ""
    @Published private(set) var approvalPending = false

    private let file: SharedFile
    private weak var webView: WKWebView?
    private var started = false
    private var cancelled = false

    init(file: SharedFile) { self.file = file; super.init() }

    var statusSymbol: String {
        if errorMessage != nil { return "exclamationmark.triangle.fill" }
        if progress >= 1 { return "checkmark.circle.fill" }
        if approvalPending { return "person.badge.shield.checkmark" }
        if receiverURL != nil { return "lock.shield.fill" }
        return "hourglass"
    }

    var formattedPIN: String {
        guard pinCode.count == 6 else { return pinCode }
        return "\(pinCode.prefix(3)) \(pinCode.suffix(3))"
    }

    var progressLabel: String {
        let sent = ByteCountFormatter.string(fromByteCount: transferred, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        return "\(sent) / \(total)"
    }

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "sharRemote")
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = false
        webView = view
        DispatchQueue.main.async { [weak self] in self?.start() }
        return view
    }

    func start() {
        guard !started else { return }
        guard webView != nil else { status = "Preparing secure remote share…"; return }
        started = true
        cancelled = false
        isWorking = true
        errorMessage = nil
        receiverURL = nil
        expiresAt = nil
        progress = 0
        transferred = 0
        isTransferring = false
        didCopy = false
        didCopyPIN = false
        pinCode = ""
        approvalPending = false
        status = "Creating end-to-end encrypted share…"
        loadEngine()
    }

    func retry() {
        cancel(deleteRemoteSession: true)
        started = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.start() }
    }
    func cancel() { cancel(deleteRemoteSession: true) }
    func markCopied() { didCopy = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.didCopy = false } }
    func markPinCopied() { didCopyPIN = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.didCopyPIN = false } }

    func resolveApproval(approved: Bool) {
        approvalPending = false
        webView?.callAsyncJavaScript(
            "window.sharNativeApprove && window.sharNativeApprove(approved)",
            arguments: ["approved": approved], in: nil, in: .page, completionHandler: { _ in }
        )
    }

    private func cancel(deleteRemoteSession: Bool) {
        cancelled = true
        isWorking = false
        isTransferring = false
        approvalPending = false
        if deleteRemoteSession { webView?.evaluateJavaScript("window.sharNativeCancel && window.sharNativeCancel()", completionHandler: nil) }
    }

    private func loadEngine() {
        guard let webView else { fail("Remote engine is not ready. Try again."); return }
        webView.loadHTMLString(engineHTML, baseURL: URL(string: "https://mojoworks.xyz/labs/shar/")!)
    }

    private var engineHTML: String {
                let metadata: [String: Any] = [
                    "name": file.name,
                    "path": file.name,
                    "size": file.size,
                    "mime": mimeType(for: file)
                ]
                let data = try! JSONSerialization.data(withJSONObject: metadata)
                let json = String(data: data, encoding: .utf8)!
                return """
                <!doctype html><meta charset="utf-8"><script>
                'use strict';
                const FILE=\(json);
                const API='https://mojoworks.xyz/api/shar/remote/v1';
                const RECEIVE='https://mojoworks.xyz/labs/shar/receive.html';
                const PIN_ITERATIONS=150000;
                let session=null,pc=null,dc=null,signalSeq=0,pollTimer=null,pending=[],sent=0,cancelled=false,finished=false,receiverAckResolve=null,aesKey=null,approvalRequestId='',sentHash='';
                const chunkRequests=new Map();let chunkCounter=0;
                function native(m){try{window.webkit.messageHandlers.sharRemote.postMessage(m)}catch(e){}}
                function status(value,state=''){native({type:'status',value,state})}
                function b64urlEncode(u){let s='';for(const b of u)s+=String.fromCharCode(b);return btoa(s).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'')}
                function randomPin(){const x=new Uint32Array(1);do{crypto.getRandomValues(x)}while(x[0]>=4294000000);return String(x[0]%1000000).padStart(6,'0')}
                async function pinVerifier(pin,salt){const material=await crypto.subtle.importKey('raw',new TextEncoder().encode(pin),'PBKDF2',false,['deriveBits']);const bits=await crypto.subtle.deriveBits({name:'PBKDF2',hash:'SHA-256',salt,iterations:PIN_ITERATIONS},material,256);return b64urlEncode(new Uint8Array(bits))}
                async function api(path,opt={}){let response;try{response=await fetch(API+path,{cache:'no-store',...opt,headers:{'Content-Type':'application/json','X-Shar-Client':'macos-native-2.2.43',...(opt.headers||{})}})}catch(e){throw Error('Cannot reach Shar remote service. Check Internet connection or server deployment.')}const text=await response.text();let body={};try{body=text?JSON.parse(text):{}}catch{}if(!response.ok)throw Error(body.error||`Shar remote service returned HTTP ${response.status}`);return body}
                window.__sharNativeChunk=(id,b64)=>{const p=chunkRequests.get(id);if(!p)return;chunkRequests.delete(id);try{const raw=atob(b64),out=new Uint8Array(raw.length);for(let i=0;i<raw.length;i++)out[i]=raw.charCodeAt(i);p.resolve(out)}catch(e){p.reject(e)}};
                window.__sharNativeChunkError=(id,message)=>{const p=chunkRequests.get(id);if(!p)return;chunkRequests.delete(id);p.reject(Error(message||'Could not read file'))};
                function chunk(offset,length){return new Promise((resolve,reject)=>{const id=String(++chunkCounter);chunkRequests.set(id,{resolve,reject});native({type:'chunk',requestId:id,offset,length})})}
                async function waitBuffer(){if(!dc||dc.readyState!=='open')throw Error('Remote data channel closed');if(dc.bufferedAmount<4*1024*1024)return;await new Promise((resolve,reject)=>{dc.bufferedAmountLowThreshold=1024*1024;const done=()=>resolve();dc.addEventListener('bufferedamountlow',done,{once:true});setTimeout(()=>{if(dc&&dc.bufferedAmount>=4*1024*1024)reject(Error('Receiver is not consuming data'))},30000)})}
                async function seal(type,payload){const body=payload instanceof Uint8Array?payload:new Uint8Array(payload);const plain=new Uint8Array(1+body.byteLength);plain[0]=type;plain.set(body,1);const iv=crypto.getRandomValues(new Uint8Array(12));const cipher=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv},aesKey,plain));const out=new Uint8Array(12+cipher.byteLength);out.set(iv);out.set(cipher,12);return out.buffer}
                async function openPacket(data){const u=data instanceof ArrayBuffer?new Uint8Array(data):new Uint8Array(await data.arrayBuffer());if(u.byteLength<29)throw Error('Invalid encrypted acknowledgement');const iv=u.subarray(0,12),cipher=u.subarray(12);const plain=new Uint8Array(await crypto.subtle.decrypt({name:'AES-GCM',iv},aesKey,cipher));return{type:plain[0],payload:plain.subarray(1)}}
                async function sendControl(obj){await waitBuffer();dc.send(await seal(1,new TextEncoder().encode(JSON.stringify(obj))))}
                async function sendData(bytes){await waitBuffer();dc.send(await seal(2,bytes))}
                async function signal(type,payload){if(!session)throw Error('No remote session');return api('/session/'+encodeURIComponent(session.id)+'/signal',{method:'POST',headers:{Authorization:'Bearer '+session.hostSecret},body:JSON.stringify({type,payload})})}
                async function poll(){if(!session||cancelled)return;try{const j=await api('/session/'+encodeURIComponent(session.id)+'/signal?since='+signalSeq,{headers:{Authorization:'Bearer '+session.hostSecret}});for(const m of j.messages||[]){signalSeq=Math.max(signalSeq,m.seq);if(m.type==='answer'){await pc.setRemoteDescription(m.payload);for(const c of pending.splice(0))await pc.addIceCandidate(c)}else if(m.type==='candidate'&&m.payload){if(pc.remoteDescription)await pc.addIceCandidate(m.payload);else pending.push(m.payload)}else if(m.type==='join-request'){approvalRequestId=m.payload?.requestId||'';status('Receiver entered the correct PIN — approval required');native({type:'approval',requestId:approvalRequestId})}else if(m.type==='ready'){status('Approved receiver is connecting…')}}}catch(e){if(finished||cancelled)return;native({type:'error',message:e.message});return}if(!finished&&!cancelled)pollTimer=setTimeout(poll,650)}
                window.sharNativeApprove=async approved=>{if(!session||!approvalRequestId)return;try{await api('/session/'+encodeURIComponent(session.id)+'/approve',{method:'POST',headers:{Authorization:'Bearer '+session.hostSecret},body:JSON.stringify({requestId:approvalRequestId,approved:!!approved})});native({type:'approvalResolved',approved:!!approved});status(approved?'Receiver approved — establishing secure connection…':'Receiver rejected');if(!approved)approvalRequestId=''}catch(e){native({type:'error',message:e.message})}};
                async function connectionLabel(){try{const stats=await pc.getStats();let pair=null;stats.forEach(x=>{if(x.type==='transport'&&x.selectedCandidatePairId)pair=stats.get(x.selectedCandidatePairId);if(x.type==='candidate-pair'&&x.selected)pair=x});if(pair){const l=stats.get(pair.localCandidateId),r=stats.get(pair.remoteCandidateId);if(l?.candidateType==='relay'||r?.candidateType==='relay')return 'Secure connection through Shar TURN relay';return 'Secure peer-to-peer connection'}}catch{}return 'Secure connection established'}
                function receiverAck(timeout=15000){return new Promise(resolve=>{let done=false;const finish=value=>{if(done)return;done=true;receiverAckResolve=null;resolve(value)};receiverAckResolve=ok=>finish(ok===true);setTimeout(()=>finish(false),timeout)})}
                async function serverCompletion(){for(let i=0;i<8&&!cancelled;i++){try{const s=await api('/session/'+encodeURIComponent(session.id));if(s.completed)return true}catch{}await new Promise(r=>setTimeout(r,500))}return false}
                class Sha256{constructor(){this.h=new Uint32Array([0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]);this.buf=new Uint8Array(64);this.bufLen=0;this.bytes=0;this.w=new Uint32Array(64)}static rotr(x,n){return(x>>>n)|(x<<(32-n))}_block(b,o=0){const w=this.w;for(let i=0;i<16;i++){const j=o+i*4;w[i]=((b[j]<<24)|(b[j+1]<<16)|(b[j+2]<<8)|b[j+3])>>>0}for(let i=16;i<64;i++){const x=w[i-15],y=w[i-2],s0=(Sha256.rotr(x,7)^Sha256.rotr(x,18)^(x>>>3))>>>0,s1=(Sha256.rotr(y,17)^Sha256.rotr(y,19)^(y>>>10))>>>0;w[i]=(w[i-16]+s0+w[i-7]+s1)>>>0}let[a,b1,c,d,e,f,g,h]=this.h;for(let i=0;i<64;i++){const S1=(Sha256.rotr(e,6)^Sha256.rotr(e,11)^Sha256.rotr(e,25))>>>0,ch=((e&f)^((~e)&g))>>>0,t1=(h+S1+ch+Sha256.K[i]+w[i])>>>0,S0=(Sha256.rotr(a,2)^Sha256.rotr(a,13)^Sha256.rotr(a,22))>>>0,maj=((a&b1)^(a&c)^(b1&c))>>>0,t2=(S0+maj)>>>0;h=g;g=f;f=e;e=(d+t1)>>>0;d=c;c=b1;b1=a;a=(t1+t2)>>>0}const v=[a,b1,c,d,e,f,g,h];for(let i=0;i<8;i++)this.h[i]=(this.h[i]+v[i])>>>0}update(data){const u=data instanceof Uint8Array?data:new Uint8Array(data);this.bytes+=u.length;let o=0;if(this.bufLen){const n=Math.min(64-this.bufLen,u.length);this.buf.set(u.subarray(0,n),this.bufLen);this.bufLen+=n;o+=n;if(this.bufLen===64){this._block(this.buf);this.bufLen=0}}while(o+64<=u.length){this._block(u,o);o+=64}if(o<u.length){this.buf.set(u.subarray(o),0);this.bufLen=u.length-o}return this}hex(){const bytes=this.bytes,len=this.bufLen,padLen=len<56?56-len:120-len,pad=new Uint8Array(padLen+8);pad[0]=0x80;const bits=bytes*8,hi=Math.floor(bits/0x100000000),lo=bits>>>0,n=pad.length;pad[n-8]=(hi>>>24)&255;pad[n-7]=(hi>>>16)&255;pad[n-6]=(hi>>>8)&255;pad[n-5]=hi&255;pad[n-4]=(lo>>>24)&255;pad[n-3]=(lo>>>16)&255;pad[n-2]=(lo>>>8)&255;pad[n-1]=lo&255;this.update(pad);return Array.from(this.h,x=>x.toString(16).padStart(8,'0')).join('')}}
                Sha256.K=new Uint32Array([0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]);
                async function sendFile(){sent=0;native({type:'transfer',active:true});const hasher=new Sha256();await sendControl({t:'manifest',files:[FILE]});await sendControl({t:'file-start',i:0,path:FILE.path,name:FILE.name,size:FILE.size,mime:FILE.mime});for(let offset=0;offset<FILE.size;){if(cancelled)throw Error('Share cancelled');const length=Math.min(49152,FILE.size-offset);const bytes=await chunk(offset,length);if(!bytes.length&&length)throw Error('Unexpected end of file');hasher.update(bytes);await sendData(bytes);offset+=bytes.byteLength;sent=offset;native({type:'progress',sent,total:FILE.size})}sentHash=hasher.hex();await sendControl({t:'file-end',i:0,sha256:sentHash});const ack=receiverAck();await sendControl({t:'complete'});status('Finalizing encrypted transfer with receiver…','live');const verified=await ack;const serverDone=verified?true:await serverCompletion();finished=true;if(pollTimer)clearTimeout(pollTimer);pollTimer=null;native({type:'complete',confirmed:verified,serverDone});status(verified?'Transfer complete ✓':serverDone?'Receiver reported completion — secure verification ACK unavailable':'Transfer sent — receiver confirmation unavailable','live')}
                async function start(){if(!window.RTCPeerConnection||!crypto?.subtle){native({type:'error',message:'Secure WebRTC/Web Crypto is unavailable in this macOS WebView.'});return}try{const pin=randomPin(),salt=crypto.getRandomValues(new Uint8Array(16)),verifier=await pinVerifier(pin,salt),rawKey=crypto.getRandomValues(new Uint8Array(32));aesKey=await crypto.subtle.importKey('raw',rawKey,{name:'AES-GCM'},false,['encrypt','decrypt']);session=await api('/session',{method:'POST',body:JSON.stringify({files:[{path:'Encrypted item',size:FILE.size,mime:'application/octet-stream'}],ttlSeconds:1800,oneTime:true,pinVerifier:verifier,pinSalt:b64urlEncode(salt),pinIterations:PIN_ITERATIONS,approvalRequired:true,e2ee:true,privateMetadata:true})});const receiverUrl=RECEIVE+'#share='+encodeURIComponent(session.id)+'&key='+encodeURIComponent(b64urlEncode(rawKey));native({type:'session',receiverUrl,expiresAt:session.expiresAt,pin});status('Waiting for receiver PIN…');pc=new RTCPeerConnection({iceServers:session.iceServers});dc=pc.createDataChannel('shar-file',{ordered:true});dc.binaryType='arraybuffer';dc.onopen=async()=>{status(await connectionLabel(),'live');sendFile().catch(e=>{if(!finished)native({type:'error',message:e.message})})};dc.onmessage=e=>{if(finished||typeof e.data==='string')return;(async()=>{try{const packet=await openPacket(e.data);if(packet.type!==1)return;const m=JSON.parse(new TextDecoder().decode(packet.payload));if(m.t==='receiver-complete'){const ok=m.verified===true&&Array.isArray(m.hashes)&&m.hashes[0]===sentHash;status(ok?'Receiver decrypted and SHA-256 verified the file ✓':'Receiver completion could not be cryptographically verified',ok?'live':'');receiverAckResolve?.(ok)}}catch(err){if(!finished)native({type:'error',message:'Secure receiver acknowledgement failed.'})}})()};dc.onerror=()=>{if(!finished)native({type:'error',message:'Encrypted WebRTC data channel error.'})};pc.onicecandidate=e=>{if(e.candidate)signal('candidate',e.candidate.toJSON()).catch(()=>{})};pc.onconnectionstatechange=async()=>{if(finished)return;if(pc.connectionState==='connected')status(await connectionLabel(),'live');else if(pc.connectionState==='failed')native({type:'error',message:'Could not establish a direct or Shar TURN WebRTC connection.'});else if(pc.connectionState==='disconnected')status('Receiver disconnected')};const offer=await pc.createOffer();await pc.setLocalDescription(offer);await signal('offer',pc.localDescription);poll()}catch(e){native({type:'error',message:e.message||String(e)})}}
                window.sharNativeCancel=async()=>{cancelled=true;finished=true;if(pollTimer)clearTimeout(pollTimer);try{dc&&dc.close()}catch{}try{pc&&pc.close()}catch{}if(session?.id&&session?.hostSecret)await api('/session/'+encodeURIComponent(session.id),{method:'DELETE',headers:{Authorization:'Bearer '+session.hostSecret}}).catch(()=>{});session=null};
                setTimeout(start,0);
                </script>
                """
    }

    private func mimeType(for file: SharedFile) -> String {
        if let type = UTType(filenameExtension: file.fileExtension), let mime = type.preferredMIMEType { return mime }
        return "application/octet-stream"
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "sharRemote", let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "status":
            guard let value = body["value"] as? String else { return }
            status = value
            if body["state"] as? String == "live" { errorMessage = nil }
        case "session":
            if let value = body["receiverUrl"] as? String { receiverURL = URL(string: value) }
            if let value = body["expiresAt"] as? String { expiresAt = ISO8601DateFormatter().date(from: value) }
            if let value = body["pin"] as? String { pinCode = value }
            isWorking = true
            errorMessage = nil
        case "approval":
            approvalPending = true
            status = "Receiver requests approval"
        case "approvalResolved":
            approvalPending = false
            status = ((body["approved"] as? Bool) ?? false) ? "Receiver approved — connecting…" : "Receiver rejected"
        case "transfer":
            isTransferring = (body["active"] as? Bool) ?? true
        case "progress":
            let sentValue = (body["sent"] as? NSNumber)?.int64Value ?? 0
            let totalValue = max((body["total"] as? NSNumber)?.int64Value ?? file.size, 1)
            transferred = sentValue
            progress = min(max(Double(sentValue) / Double(totalValue), 0), 1)
            isTransferring = true
        case "complete":
            transferred = file.size
            progress = 1
            isTransferring = false
            isWorking = false
            approvalPending = false
            let confirmed = (body["confirmed"] as? Bool) ?? false
            let serverDone = (body["serverDone"] as? Bool) ?? false
            status = confirmed ? "Transfer complete ✓" : (serverDone ? "Receiver reported completion" : "Transfer sent")
        case "error":
            fail((body["message"] as? String) ?? "Remote share failed")
        case "chunk":
            guard let requestID = body["requestId"] as? String,
                  let offset = (body["offset"] as? NSNumber)?.uint64Value,
                  let length = (body["length"] as? NSNumber)?.intValue else { return }
            provideChunk(requestID: requestID, offset: offset, length: length)
        default: break
        }
    }

    private func provideChunk(requestID: String, offset: UInt64, length: Int) {
        let fileURL = file.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                try handle.seek(toOffset: offset)
                let data = try handle.read(upToCount: max(1, min(length, 49152))) ?? Data()
                let b64 = data.base64EncodedString()
                DispatchQueue.main.async {
                    self?.webView?.callAsyncJavaScript(
                        "window.__sharNativeChunk(requestId, base64)",
                        arguments: ["requestId": requestID, "base64": b64], in: nil, in: .page, completionHandler: { _ in }
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self?.webView?.callAsyncJavaScript(
                        "window.__sharNativeChunkError(requestId, message)",
                        arguments: ["requestId": requestID, "message": error.localizedDescription], in: nil, in: .page, completionHandler: { _ in }
                    )
                }
            }
        }
    }

    private func fail(_ message: String) {
        isWorking = false
        isTransferring = false
        approvalPending = false
        errorMessage = message
        status = "Secure Remote Share unavailable"
    }

    deinit { webView?.configuration.userContentController.removeScriptMessageHandler(forName: "sharRemote") }
}

private final class MacAboutPanelController {
    static let shared = MacAboutPanelController()
    private var panel: NSPanel?

    private init() {}

    func show() {
        if let panel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingController(rootView: MacAboutView(onClose: { [weak panel] in
            panel?.close()
        }))
        panel.title = "About Shar"
        panel.contentViewController = host
        panel.contentMinSize = NSSize(width: 560, height: 420)
        panel.contentMaxSize = NSSize(width: 560, height: 420)
        panel.isReleasedWhenClosed = false
        panel.center()
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct MacAboutView: View {
    let onClose: () -> Void
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("About Shar").font(.title2.bold())
                    Text("Version \(version) · Build \(build)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title2) }.buttonStyle(.plain)
            }
            Divider()
            LabeledContent("Company") { Link(SharProductInfo.builderName, destination: SharProductInfo.builderURL) }
            Text("Shar is developed and published by WORKWORK.FUN LTD. MojoWorks is a creative sub-brand used for selected labs and experiments.")
                .font(.callout).foregroundStyle(.secondary)
            Text(SharProductInfo.copyrightLine).font(.callout.weight(.semibold))
            Link(destination: SharProductInfo.productURL) { Label("Shar website", systemImage: "globe") }
            Link(destination: SharProductInfo.sourceURL) { Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right") }
            Spacer()
            Link(destination: SharProductInfo.supportURL) {
                Label("Support Shar", systemImage: "dollarsign.circle.fill").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 560, height: 420, alignment: .topLeading)
    }
}

private struct MacDeveloperUpdatesView: View {
    @Environment(\.dismiss) private var dismiss
    private let updates: [(String, String, String, String)] = [
        ("2.2.43", "2026-08-31", "macOS Whisper platform/compiler fix", "Fixed the macOS local-Whisper bridge build to use Apple clang correctly and select only the MacOSX XCFramework slice instead of a same-architecture tvOS simulator slice."),
        ("2.2.42", "2026-08-31", "Coloured build + watcher output", "Added shared TTY-aware terminal styling across the foreground watcher and release/build scripts while keeping redirected logs plain text."),
        ("2.2.41", "2026-08-31", "Whisper Apple-mode build exit fix", "Fixed the successful Apple-only Whisper preparation path returning status 1 and aborting the macOS release before compilation under set -e."),
        ("2.2.40", "2026-08-31", "macOS Whisper build handoff hardening", "Hardened the macOS local-Whisper build handoff with architecture-based framework selection and explicit pre-compile diagnostics; also fixed an Android Developer Updates Java declaration regression."),
        ("2.2.39", "2026-08-31", "Whisper Release-asset pin fix", "Corrected the strict whisper.cpp Apple XCFramework integrity pin to the SHA-256 and byte count of the actual GitHub Release asset. Local captions remain fully on-device across iOS/iPadOS, macOS and Android."),
        ("2.2.38", "2026-08-31", "Whisper dependency download hardening", "Kept fully local cross-platform Whisper and hardened Apple framework preparation with verified retries across independent GitHub release transports when a direct download is corrupted or stale."),
        ("2.2.37", "2026-08-31", "Cross-platform local Whisper + audio parity", "iOS, macOS and Android now share local captions plus switchable Live spectrum / whole-track Waveform. Captions run with bundled local Whisper and media is never uploaded for transcription."),
        ("2.2.36", "2026-08-31", "Private local captions + responsive spectrum", "Hardened the first local-only caption prototype and improved the iOS 20-band spectrum. The caption engine is superseded by cross-platform local Whisper in v2.2.37."),
        ("2.2.35", "2026-08-31", "Live spectrum + resilient captions", "Improved iOS spectrum timing and chunked caption processing. The temporary caption engine is superseded by fully local Whisper in v2.2.37."),
        ("2.2.34", "2026-08-31", "Audio continuity + visual captions", "Introduced persistent iOS Preview playback, switchable spectrum/waveform visualization, and synchronized highlighted caption UI."),
        ("2.2.33", "2026-08-31", "Remote Share help + media feedback", "Simplified the iOS Remote Share flow with bottom-left quick Help and added clearer pressed/active Grid-card feedback on iOS and macOS."),
        ("2.2.32", "2026-08-31", "macOS 3D thumbnail build hotfix", "Fixed the async 3D thumbnail fallback compile regression and added a release guard for invalid async nil-coalescing."),
        ("2.2.3", "2026-08-31", "3D thumbnails + compact iOS workflow", "Added background 3D thumbnail capture/recapture, visual file confirmation in Secure Remote Share, compact iOS Settings, main Grid/List switching, first-run add affordance, clearer Files access and dated update history."),
        ("2.2.2", "2026-08-31", "iOS grid controls + release resilience", "Restored fixed-size iOS grid action controls and made an attached device running out of storage non-blocking for the distribution release after successful build/sign validation."),
        ("2.2.1", "2026-08-30", "macOS presentation polish", "Fixed the About panel size, made newly opened images fit the preview window, and compacted Secure Remote Share so its larger primary actions remain visible without scrolling."),
        ("2.2.0", "2026-08-30", "Polished 3D preview", "Added native lighting, floor, background and fit controls plus a fully local WebGL browser renderer and bundled Previous/Next icons."),
        ("2.1.9", "2026-08-30", "3D preview build compatibility", "Fixed the macOS 13 3D-preview compile blockers and hardened the SceneKit/Model I/O compatibility checks."),
        ("2.1.8", "2026-08-30", "3D previews + persistent playback", "Added a 3D media filter and local interactive GLB/glTF plus Apple-native model previews. Audio keeps the same player, position and play/pause state when switching Grid/List or opening Preview."),
        ("2.1.7", "2026-08-30", "Native Mac identity + About routing", "The macOS ⓘ toolbar control now opens Developer updates like iOS, About Shar is owned by the application menu, and the visible macOS application name is Shar instead of LocalWebShare."),
        ("2.1.6", "2026-08-30", "Playback + identity polish", "macOS now has one persistent inline audio session across Grid/List, top Support/About/Config controls, refreshed Stripe website support, and WORKWORK.FUN LTD ownership/copyright information."),
        ("2.1.5", "2026-08-30", "Stripe support checkout", "Connected Shar Support to the production Stripe Payment Link and official Buy Button."),
        ("2.1.4", "2026-08-30", "Release pipeline resilience", "A locked iPhone no longer aborts the full distribution release after successful installation."),
        ("2.1.3", "2026-08-30", "Unified native library UI", "Added iOS-style media filters, grid/list library modes, cog-based Config, explicit version/build information and About/Support links on macOS."),
        ("2.1.2", "2026-08-30", "Native macOS Secure Remote Share", "Remote sharing now stays inside the macOS app with native PIN, QR/link, approval, encrypted-transfer progress and completion UI instead of opening the localhost browser."),
        ("2.1.1", "2026-08-30", "Secure Android build fix", "Fixed the Android embedded secure-share JavaScript escaping regression and added a javac release guard."),
        ("2.1.0", "2026-08-30", "Secure Remote Share", "Added AES-256-GCM content encryption, receiver PIN, sender approval, SHA-256 verification and private metadata mode."),
        ("2.0.8", "2026-08-30", "Remote sender startup fix", "Fixed native iOS Remote Share startup and removed Google STUN from the runtime ICE path."),
        ("2.0.7", "2026-08-30", "Remote completion handshake", "Made successful remote downloads terminal and added receiver confirmation so cleanup cannot appear as a false failure."),
        ("2.0.6", "2026-08-30", "Native link sharing", "Fixed iPhone Remote Share so Share link opens the native iOS share sheet for Messages, Mail, AirDrop and installed messaging apps."),
        ("2.0.5", "2026-08-30", "Remote service readiness", "Fixed the signaling-service startup race and added readiness diagnostics before nginx/public-route validation."),
        ("2.0.4", "2026-08-30", "Native iPhone Remote Share", "Remote sharing now starts directly from the native iOS file card and shows a native QR/link transfer sheet without opening the local browser UI."),
        ("2.0.3", "2026-08-30", "Public route verification", "Made the real public HTTPS API authoritative and hardened nginx repair for duplicate/address-bound apex vhosts."),
        ("2.0.2", "2026-08-30", "Remote routing repair", "Fixed exact mojoworks.xyz API routing and automatic repair when the public share endpoint returns 404."),
        ("2.0.1", "2026-08-30", "Android release fix", "Restored Android release compilation and made its visible version read from package metadata."),
        ("2.0.0", "2026-08-29", "Remote WebRTC sharing", "Added expiring QR/link shares, peer-to-peer data channels, TURN fallback, and automated signaling/TURN deployment."),
        ("1.7.6", "2026-08-29", "Optional developer info", "Added the hidden-by-default ⓘ updates panel and preference."),
        ("1.7.5", "2026-08-29", "Cross-platform audio fix", "Kept iOS background audio while restoring the macOS release build."),
        ("1.7.4", "2026-08-29", "Background audio", "Audio can continue while Shar is minimized or the iPhone screen is locked."),
        ("1.7.3", "2026-08-29", "Better preview", "Images fit the viewer and previews gained a persistent X close control."),
        ("1.7.2", "2026-08-29", "More ways to add", "Added Photos & Videos, camera recording, and Files from the + menu."),
        ("1.7.1", "2026-08-29", "Shar identity", "Renamed the visible product to Shar and added the persistent iOS + importer.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let image = Bundle.main.url(forResource: "shar-logo-1024", withExtension: "png").flatMap(NSImage.init(contentsOf:)) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shar").font(.title3.bold())
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text("Developer updates").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            }
            .padding(16)
            Divider()
            List(Array(updates.enumerated()), id: \.offset) { _, update in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text("v\(update.0)").font(.caption.monospaced().bold()); Text(update.2).font(.subheadline.bold()) }
                    Text(update.1).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    Text(update.3).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
        }
    }
}

private struct MacLibraryGridCard: View {
    let file: SharedFile
    let mode: ActionLabelMode
    let showFileSize: Bool
    @ObservedObject var audioPlayback: SharedAudioPlaybackController
    let onPreview: () -> Void
    let onRemote: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onPreview) {
                MacThumbnail(file: file, size: 142)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MacMediaPreviewPressButtonStyle())
            Text(file.name).font(.headline).lineLimit(2)
            MacAudioMetadataLine(file: file)
            HStack(spacing: 5) {
                Text(file.mediaKind.rawValue.uppercased())
                if showFileSize {
                    Text("•")
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if file.mediaKind == .audio { MacInlineAudioButton(file: file, playback: audioPlayback) }
                MacActionButton(full: "Preview", short: "View", icon: "eye", mode: mode, action: onPreview).buttonStyle(.borderless)
                MacActionButton(full: "Remote", short: "Remote", icon: "network", mode: mode, action: onRemote).buttonStyle(.borderless)
                Spacer(minLength: 0)
                MacActionButton(full: "Delete", short: "Del", icon: "trash", mode: mode, action: onDelete).buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(
            audioPlayback.isActive(file) ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    audioPlayback.isActive(file) ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.12),
                    lineWidth: audioPlayback.isActive(file) ? 2 : 1
                )
        }
        .animation(.easeOut(duration: 0.16), value: audioPlayback.activeFileID)
        .contextMenu {
            Button("Preview", action: onPreview)
            Button("Remote share", action: onRemote)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

private struct MacLibraryListRow: View {
    let file: SharedFile
    let mode: ActionLabelMode
    let showFileSize: Bool
    @ObservedObject var audioPlayback: SharedAudioPlaybackController
    let onPreview: () -> Void
    let onRemote: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPreview) { MacThumbnail(file: file) }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name).fontWeight(.medium).lineLimit(1)
                MacAudioMetadataLine(file: file)
                HStack(spacing: 5) {
                    Text(file.mediaKind.rawValue.uppercased())
                    if showFileSize {
                        Text("•")
                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if file.mediaKind == .audio { MacInlineAudioButton(file: file, playback: audioPlayback) }
            MacActionButton(full: "Preview", short: "View", icon: "eye", mode: mode, action: onPreview).buttonStyle(.borderless)
            MacActionButton(full: "Remote", short: "Remote", icon: "network", mode: mode, action: onRemote).buttonStyle(.borderless)
            MacActionButton(full: "Delete", short: "Del", icon: "trash", mode: mode, action: onDelete).buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onPreview)
        .contextMenu {
            Button("Preview", action: onPreview)
            Button("Remote share", action: onRemote)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

private struct MacEmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.bold())
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct MacMediaPreviewPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.accentColor.opacity(configuration.isPressed ? 0.14 : 0),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(Color.accentColor.opacity(configuration.isPressed ? 0.95 : 0), lineWidth: 3)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

private struct MacActionButton: View {
    let full:String;let short:String;let icon:String;let mode:ActionLabelMode;let action:()->Void
    var body: some View { Button(action:action){switch mode{case .text:Text(full);case .icons:Image(systemName:icon).accessibilityLabel(full);case .compact:Label(short,systemImage:icon)}} }
}

private struct MacThumbnail: View {
    let file: SharedFile
    var size: CGFloat = 54
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(.quaternary)
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: file.systemImageName)
                    .font(size > 80 ? .system(size: 42) : .title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(alignment: .bottomTrailing) {
            Text(file.typeLabel).font(.system(size: 8, weight: .semibold))
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule()).padding(3)
        }
        .task(id: file.id) { await loadThumbnail() }
        .onReceive(NotificationCenter.default.publisher(for: .sharThreeDThumbnailChanged)) { notification in
            guard file.mediaKind == .threeD,
                  let path = notification.object as? String,
                  path == file.url.path else { return }
            thumbnail = ThreeDThumbnailCache.cachedImage(for: file.url)
        }
    }

    @MainActor
    private func loadThumbnail() async {
        if file.mediaKind == .image {
            thumbnail = NSImage(contentsOf: file.url)
            return
        }
        if file.mediaKind == .audio, let data = MediaMetadataReader.read(file.url).artworkData {
            thumbnail = NSImage(data: data)
            return
        }
        if file.mediaKind == .threeD {
            if let cached = ThreeDThumbnailCache.cachedImage(for: file.url) {
                thumbnail = cached
            } else {
                thumbnail = await ThreeDThumbnailCache.generateDefault(for: file.url)
            }
        }
    }
}

private struct MacAudioMetadataLine: View {
    let file:SharedFile
    var body: some View { if file.mediaKind == .audio { let m=MediaMetadataReader.read(file.url);if m.title != nil || m.artist != nil {Text([m.title,m.artist].compactMap{$0}.joined(separator:" — ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)}} }
}

private struct MacInlineAudioButton: View {
    let file: SharedFile
    @ObservedObject var playback: SharedAudioPlaybackController
    private var isThisFilePlaying: Bool { playback.activeFileID == file.id && playback.isPlaying }

    var body: some View {
        Button { playback.toggle(file) } label: {
            Image(systemName: isThisFilePlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.title2)
        }
        .buttonStyle(.borderless)
        .help(isThisFilePlaying ? "Pause \(file.name)" : "Play \(file.name)")
    }
}

private struct MacMediaGallery: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files:[SharedFile];@State private var index:Int;@State private var confirmDelete=false
    @ObservedObject var audioPlayback: SharedAudioPlaybackController
    let onDelete:(SharedFile)->Void
    init(files:[SharedFile],initialFile:SharedFile,audioPlayback:SharedAudioPlaybackController,onDelete:@escaping(SharedFile)->Void){_files=State(initialValue:files);_index=State(initialValue:files.firstIndex(of:initialFile) ?? 0);self.audioPlayback=audioPlayback;self.onDelete=onDelete}
    private var file:SharedFile?{files.indices.contains(index) ? files[index]:nil}
    var body: some View { VStack(spacing:0){HStack{Button{prev()}label:{Image(systemName:"chevron.left")}.disabled(index<=0);Button{next()}label:{Image(systemName:"chevron.right")}.disabled(index>=files.count-1);Text(file?.name ?? "Preview").font(.headline).lineLimit(1);Spacer();Text(files.isEmpty ? "":"\(index+1) / \(files.count)").foregroundStyle(.secondary);if let f=file{Button("Reveal"){NSWorkspace.shared.activateFileViewerSelecting([f.url])};Button(role:.destructive){confirmDelete=true}label:{Image(systemName:"trash")}};Button("Done"){dismiss()}}.padding(14);Divider();if let f=file{MacPreviewContent(file:f,audioPlayback:audioPlayback).id(f.id).simultaneousGesture(DragGesture(minimumDistance:35).onEnded{v in if v.translation.width < -60 {next()} else if v.translation.width > 60 {prev()}})}else{MacEmptyStateView(title:"No Files",systemImage:"folder",message:nil)}}.confirmationDialog(file.map{"Delete \($0.name)?"} ?? "Delete file?",isPresented:$confirmDelete){Button("Delete",role:.destructive){deleteCurrent()};Button("Cancel",role:.cancel){}} }
    private func prev(){if index>0{index-=1}};private func next(){if index+1<files.count{index+=1}};private func deleteCurrent(){guard let f=file else{return};onDelete(f);files.remove(at:index);if files.isEmpty{dismiss()}else if index>=files.count{index=files.count-1}}
}

private struct MacPreviewContent: View {
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
                if let image = NSImage(contentsOf: file.url) {
                    GeometryReader { proxy in
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: max(0, proxy.size.width - 24), height: max(0, proxy.size.height - 24))
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                    .background(Color.black)
                } else { unavailable }
            case .video:
                if let videoPlayer {
                    VideoPlayer(player: videoPlayer)
                        .onAppear { videoPlayer.play() }
                }
            case .audio:
                VStack(spacing: 20) {
                    Spacer()
                    MacThumbnail(file: file).scaleEffect(3)
                    let metadata = MediaMetadataReader.read(file.url)
                    Text(metadata.title ?? file.name).font(.title3.bold())
                    if let artist = metadata.artist { Text(artist).foregroundStyle(.secondary) }
                    MacAudioVisualizationView(file: file, playback: audioPlayback)
                    MacAudioCaptionStrip(file: file, playback: audioPlayback)
                    MacSharedAudioControls(file: file, playback: audioPlayback)
                    Spacer()
                }
                .padding(28)
                .onAppear {
                    // Reuse the exact inline AVPlayer. Opening Preview must not reset a track
                    // that has already been playing or paused in Grid/List.
                    audioPlayback.ensureLoaded(file, autoplayIfNew: true)
                }
            case .threeD:
                ThreeDPreviewView(file: file)
            case .document, .file:
                MacQuickLook(url: file.url)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { videoPlayer?.pause() }
    }

    private var unavailable: some View {
        MacEmptyStateView(title: "Cannot Preview", systemImage: "doc.questionmark", message: nil)
    }
}

private struct MacSharedAudioControls: View {
    let file: SharedFile
    @ObservedObject var playback: SharedAudioPlaybackController

    var body: some View {
        VStack(spacing: 12) {
            Slider(
                value: Binding(
                    get: { playback.isActive(file) ? min(playback.currentTime, max(playback.duration, 0.01)) : 0 },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(playback.duration, 0.01)
            )
            HStack {
                Text(time(playback.isActive(file) ? playback.currentTime : 0))
                Spacer()
                Button { playback.toggle(file) } label: {
                    Image(systemName: playback.isPlaying(file) ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48))
                }
                .buttonStyle(.plain)
                Spacer()
                Text(time(playback.isActive(file) ? playback.duration : 0))
            }
            .font(.caption.monospacedDigit())
        }
        .frame(maxWidth: 520)
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}


private enum MacAudioVisualizationMode: String { case spectrum = "Live spectrum"; case waveform = "Waveform" }

@MainActor
private final class MacAudioVisualizationModel: ObservableObject {
    @Published var waveform: [Double] = []
    @Published var spectrumFrames: [[Double]] = []
    @Published var loading = false
    private var path: String?
    func load(_ file: SharedFile) async {
        if path == file.url.path, !waveform.isEmpty { return }
        path = file.url.path; loading = true
        let expected = file.url.path
        let result = await Task.detached(priority: .utility) { SharAudioAnalyzer.analyze(url: file.url) }.value
        guard path == expected else { return }
        waveform = result.waveform; spectrumFrames = result.spectrumFrames; loading = false
    }
}

private struct MacAudioVisualizationView: View {
    let file: SharedFile
    @ObservedObject var playback: SharedAudioPlaybackController
    @StateObject private var analysis = MacAudioVisualizationModel()
    @State private var mode: MacAudioVisualizationMode = .spectrum
    private var progress: Double { guard playback.isActive(file), playback.duration > 0 else { return 0 }; return min(max(playback.currentTime / playback.duration, 0), 1) }
    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.16)) { mode = mode == .spectrum ? .waveform : .spectrum } } label: {
            VStack(spacing: 5) {
                HStack { Label(mode.rawValue, systemImage: mode == .spectrum ? "waveform.path.ecg" : "waveform").font(.caption.weight(.semibold)); Spacer(); Text("click to switch").font(.caption2).foregroundStyle(.secondary) }
                if analysis.loading && analysis.waveform.isEmpty { ProgressView().frame(height: 68) }
                else if mode == .spectrum { spectrum } else { waveform }
            }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).frame(maxWidth: 560).task(id: file.id) { await analysis.load(file) }
    }
    private var spectrum: some View {
        let bands = SharAudioAnalyzer.spectrum(frames: analysis.spectrumFrames, progress: progress)
        return GeometryReader { proxy in HStack(alignment: .bottom, spacing: 3) { ForEach(Array(bands.enumerated()), id: \.offset) { index, value in RoundedRectangle(cornerRadius: 2.5).fill(Color(hue: Double(index) / Double(max(1,bands.count-1)) * 0.76, saturation: 0.82, brightness: 0.94)).frame(maxWidth: .infinity).frame(height: max(4, proxy.size.height * value)) } }.frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .bottom) }.frame(height: 68)
    }
    private var waveform: some View {
        GeometryReader { proxy in let vals = analysis.waveform.isEmpty ? Array(repeating: 0.1,count:72) : analysis.waveform; HStack(alignment:.center,spacing:1.5){ForEach(Array(vals.enumerated()),id:\.offset){i,v in Capsule().fill(Double(i)/Double(max(1,vals.count-1)) <= progress ? Color.accentColor : Color.secondary.opacity(0.28)).frame(maxWidth:.infinity).frame(height:max(3,proxy.size.height*v))}}.frame(maxWidth:.infinity,maxHeight:.infinity) }.frame(height:68)
    }
}

@MainActor
private enum MacCaptionCache { static var words: [String:[SharTimedCaptionWord]] = [:] }

@MainActor
private final class MacAudioCaptionController: ObservableObject {
    @Published var words: [SharTimedCaptionWord] = []
    @Published var running = false
    @Published var status: String?
    @Published var progress: String?
    private var path: String?
    func prepare(_ file: SharedFile) { path=file.url.path; words=MacCaptionCache.words[path!] ?? []; status=nil; progress=nil }
    func generate(_ file: SharedFile) {
        let expected=file.url.path; path=expected; words=[]; MacCaptionCache.words[expected]=[]; running=true; status=nil; progress="Loading local transcription model…"
        Task {
            do {
                let generated = try await Task.detached(priority:.userInitiated) { try SharLocalWhisperTranscriber.transcribe(url:file.url) { current,total in Task { @MainActor in guard self.path == expected else{return}; self.progress = total > 1 ? "Creating captions \(current)/\(total)…" : "Creating captions…" } } }.value
                guard path==expected else{return}; words=generated; MacCaptionCache.words[expected]=generated; if generated.isEmpty { status="No speech was recognized. Nothing left this Mac." }
            } catch { guard path==expected else{return}; status="Local captions could not be created: \(error.localizedDescription)" }
            if path==expected { running=false; progress=nil }
        }
    }
}

private struct MacAudioCaptionStrip: View {
    let file: SharedFile
    @ObservedObject var playback: SharedAudioPlaybackController
    @StateObject private var captions=MacAudioCaptionController()
    private var current:Int? { guard !captions.words.isEmpty else{return nil}; let t=playback.isActive(file) ? playback.currentTime : 0; return captions.words.lastIndex(where:{$0.start <= t}) }
    var body: some View {
        VStack(spacing:8){
            if captions.words.isEmpty { Button { captions.generate(file) } label: { HStack(spacing:8){ if captions.running { ProgressView().controlSize(.small) }; Image(systemName:"captions.bubble"); Text(captions.progress ?? (captions.running ? "Creating captions…":"Create captions")).font(.subheadline.weight(.semibold)) }.frame(maxWidth:.infinity) }.buttonStyle(.bordered).disabled(captions.running) }
            else { HStack { Label("Captions",systemImage:"captions.bubble.fill").font(.caption.weight(.semibold)); Spacer(); if captions.running { ProgressView().controlSize(.small) }; Button("Refresh"){captions.generate(file)}.buttonStyle(.plain).font(.caption) }; captionText.font(.body).multilineTextAlignment(.center).frame(maxWidth:.infinity,minHeight:42) }
            if let status=captions.status { Text(status).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            Label("Local Whisper • audio is never uploaded",systemImage:"lock.shield").font(.caption2).foregroundStyle(.secondary)
        }.padding(10).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12)).frame(maxWidth:560).onAppear{captions.prepare(file)}
    }
    private var captionText: Text { guard let idx=current else{return Text(captions.words.prefix(8).map(\.text).joined(separator:" "))}; let lo=max(0,idx-5), hi=min(captions.words.count,idx+7); var out=Text(""); for i in lo..<hi { var tok=Text((i==lo ? "":" ")+captions.words[i].text); tok = i==idx ? tok.foregroundColor(.accentColor).bold().underline() : tok.foregroundColor(.primary); out=out+tok }; return out }
}

private struct MacQuickLook:NSViewRepresentable{let url:URL;func makeNSView(context:Context)->QLPreviewView{let v=QLPreviewView(frame:.zero,style:.normal)!;v.autostarts=true;v.previewItem=url as NSURL;return v};func updateNSView(_ nsView:QLPreviewView,context:Context){nsView.previewItem=url as NSURL}}
