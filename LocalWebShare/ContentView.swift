import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var fileStore: FileStore
    @EnvironmentObject private var webServer: LocalWebServer

    @State private var selectedFile: SharedFile?
    @State private var filePendingDelete: SharedFile?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image("SharLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Local Web Share")
                                .font(.title3.bold())
                            Text("Wi-Fi media sharing")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }

                Section("Wi-Fi Sharing") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(webServer.isRunning ? "Sharing is ON" : "Sharing is OFF")
                                .font(.headline)
                            Text(webServer.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle()
                            .fill(webServer.isRunning ? Color.green : Color.secondary)
                            .frame(width: 12, height: 12)
                    }

                    if webServer.isRunning {
                        Text(webServer.shareURL)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)

                        ShareLink(item: webServer.shareURL) {
                            Label("Share Address", systemImage: "square.and.arrow.up")
                        }
                    }

                    Button(webServer.isRunning ? "Stop Sharing" : "Start Sharing") {
                        if webServer.isRunning {
                            webServer.stop()
                        } else {
                            webServer.start()
                        }
                    }

                    Text("Keep this app open while transferring files. The computer and iPhone/iPad must be on the same local network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Version \(appVersion)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Section {
                    if fileStore.files.isEmpty {
                        ContentUnavailableView(
                            "No Files Yet",
                            systemImage: "folder",
                            description: Text("Start Wi-Fi Sharing and drop music, videos, images, or other files into the browser.")
                        )
                    } else {
                        ForEach(fileStore.files) { file in
                            Button {
                                selectedFile = file
                            } label: {
                                fileRow(file)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    filePendingDelete = file
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button {
                                    selectedFile = file
                                } label: {
                                    Label("Preview", systemImage: "eye")
                                }

                                ShareLink(item: file.url) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }

                                Button(role: .destructive) {
                                    filePendingDelete = file
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Files")
                        Spacer()
                        Text("\(fileStore.files.count)")
                            .foregroundStyle(.secondary)
                        Button("Refresh") {
                            fileStore.refresh()
                        }
                        .textCase(nil)
                    }
                }
            }
            .navigationTitle("Local Web Share")
            .sheet(item: $selectedFile) { file in
                MediaPlayerView(file: file) {
                    fileStore.delete(file)
                    selectedFile = nil
                }
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
                        fileStore.delete(filePendingDelete)
                    }
                    filePendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    filePendingDelete = nil
                }
            }
            .alert("Error", isPresented: Binding(
                get: { fileStore.lastError != nil || webServer.lastError != nil },
                set: { isPresented in
                    if !isPresented {
                        fileStore.lastError = nil
                        webServer.lastError = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(fileStore.lastError ?? webServer.lastError ?? "Unknown error")
            }
        }
    }

    private func fileRow(_ file: SharedFile) -> some View {
        HStack(spacing: 12) {
            ThumbnailView(file: file)

            VStack(alignment: .leading, spacing: 5) {
                Text(file.name)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(file.mediaKind.rawValue.capitalized)
                    Text("•")
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}
