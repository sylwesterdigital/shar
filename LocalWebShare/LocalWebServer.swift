import Foundation
import Combine
import Network
import Darwin

final class LocalWebServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Server stopped"
    @Published private(set) var shareURL = ""
    @Published var lastError: String?

    private let port: NWEndpoint.Port = 8080
    private let queue = DispatchQueue(label: "LocalWebShare.Server", qos: .userInitiated)
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: HTTPConnectionSession] = [:]

    func start() {
        guard listener == nil else { return }

        do {
            let listener = try NWListener(using: .tcp, on: port)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let ip = Self.localIPv4Address() ?? "<device-ip>"
                    DispatchQueue.main.async {
                        self.isRunning = true
                        self.shareURL = "http://\(ip):\(self.port.rawValue)"
                        self.statusMessage = "Open this address in a browser"
                    }
                case .failed(let error):
                    DispatchQueue.main.async {
                        self.lastError = error.localizedDescription
                        self.statusMessage = "Server failed"
                    }
                    self.stop()
                case .cancelled:
                    DispatchQueue.main.async {
                        self.isRunning = false
                        self.shareURL = ""
                        self.statusMessage = "Server stopped"
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            listener.start(queue: queue)
            DispatchQueue.main.async {
                self.statusMessage = "Starting server…"
            }
        } catch {
            DispatchQueue.main.async {
                self.lastError = error.localizedDescription
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for session in sessions.values {
            session.cancel()
        }
        sessions.removeAll()
        DispatchQueue.main.async {
            self.isRunning = false
            self.shareURL = ""
            self.statusMessage = "Server stopped"
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)

        let session = HTTPConnectionSession(
            connection: connection,
            documentRoot: FileStore.documentsDirectory
        ) { [weak self, weak connection] in
            connection?.cancel()
            self?.queue.async {
                self?.sessions.removeValue(forKey: id)
            }
        }

        sessions[id] = session
        connection.start(queue: queue)
        session.start()
    }

    private static func localIPv4Address() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let socketAddress = interface.ifa_addr else { continue }
            let family = socketAddress.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name == "en1" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                address = String(cString: hostname)
                break
            }
        }
        return address
    }
}

private final class HTTPConnectionSession {
    private let connection: NWConnection
    private let documentRoot: URL
    private let didFinish: () -> Void

    private var headerBuffer = Data()
    private var uploadHandle: FileHandle?
    private var uploadTemporaryURL: URL?
    private var uploadFinalURL: URL?
    private var remainingUploadBytes: Int64 = 0

    init(connection: NWConnection, documentRoot: URL, didFinish: @escaping () -> Void) {
        self.connection = connection
        self.documentRoot = documentRoot
        self.didFinish = didFinish
    }

    func start() {
        receiveHeaders()
    }

    func cancel() {
        cleanupUpload()
        connection.cancel()
    }

    private func receiveHeaders() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.finishWithError(error)
                return
            }

            if let data, !data.isEmpty {
                self.headerBuffer.append(data)

                if let range = self.headerBuffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = self.headerBuffer.subdata(in: 0..<range.lowerBound)
                    let bodyStart = range.upperBound
                    let bodyPrefix = bodyStart < self.headerBuffer.endIndex
                        ? self.headerBuffer.subdata(in: bodyStart..<self.headerBuffer.endIndex)
                        : Data()
                    self.handleHeaders(headerData, initialBody: bodyPrefix)
                    return
                }

                if self.headerBuffer.count > 64 * 1024 {
                    self.sendText(status: "431 Request Header Fields Too Large", text: "Request headers are too large.")
                    return
                }
            }

            if isComplete {
                self.didFinish()
            } else {
                self.receiveHeaders()
            }
        }
    }

    private func handleHeaders(_ data: Data, initialBody: Data) {
        guard let text = String(data: data, encoding: .utf8) else {
            sendText(status: "400 Bad Request", text: "Invalid request headers.")
            return
        }

        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendText(status: "400 Bad Request", text: "Missing request line.")
            return
        }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            sendText(status: "400 Bad Request", text: "Invalid request line.")
            return
        }

        let method = requestParts[0].uppercased()
        let target = requestParts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        switch (method, pathOnly(target)) {
        case ("GET", "/"):
            sendHTML()
        case ("GET", "/api/files"):
            sendFileListJSON()
        case ("POST", "/upload"):
            beginUpload(target: target, headers: headers, initialBody: initialBody)
        case ("GET", let path) where path.hasPrefix("/files/"):
            sendFile(fromPath: path, headers: headers, inline: false)
        case ("GET", let path) where path.hasPrefix("/media/"):
            sendFile(fromPath: path, headers: headers, inline: true)
        case ("DELETE", let path) where path.hasPrefix("/files/"):
            deleteFile(fromPath: path)
        default:
            sendText(status: "404 Not Found", text: "Not found.")
        }
    }

    private func beginUpload(target: String, headers: [String: String], initialBody: Data) {
        guard let lengthString = headers["content-length"],
              let contentLength = Int64(lengthString),
              contentLength >= 0 else {
            sendText(status: "411 Length Required", text: "This prototype requires Content-Length for uploads.")
            return
        }

        guard let filename = queryValue(named: "filename", in: target),
              let safeName = sanitizedFilename(filename) else {
            sendText(status: "400 Bad Request", text: "Missing or invalid filename.")
            return
        }

        let finalURL = uniqueDestination(for: safeName)
        let tempURL = documentRoot.appendingPathComponent(".upload-\(UUID().uuidString).tmp")

        do {
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempURL)
            uploadHandle = handle
            uploadTemporaryURL = tempURL
            uploadFinalURL = finalURL
            remainingUploadBytes = contentLength

            if !initialBody.isEmpty {
                let count = min(Int64(initialBody.count), remainingUploadBytes)
                try handle.write(contentsOf: initialBody.prefix(Int(count)))
                remainingUploadBytes -= count
            }

            if remainingUploadBytes == 0 {
                completeUpload()
            } else {
                receiveUploadBody()
            }
        } catch {
            cleanupUpload()
            sendText(status: "500 Internal Server Error", text: error.localizedDescription)
        }
    }

    private func receiveUploadBody() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.cleanupUpload()
                self.finishWithError(error)
                return
            }

            do {
                if let data, !data.isEmpty, let handle = self.uploadHandle {
                    let count = min(Int64(data.count), self.remainingUploadBytes)
                    try handle.write(contentsOf: data.prefix(Int(count)))
                    self.remainingUploadBytes -= count
                }

                if self.remainingUploadBytes == 0 {
                    self.completeUpload()
                } else if isComplete {
                    self.cleanupUpload()
                    self.sendText(status: "400 Bad Request", text: "Upload ended before the declared file size was received.")
                } else {
                    self.receiveUploadBody()
                }
            } catch {
                self.cleanupUpload()
                self.sendText(status: "500 Internal Server Error", text: error.localizedDescription)
            }
        }
    }

    private func completeUpload() {
        do {
            try uploadHandle?.close()
            uploadHandle = nil

            guard let tempURL = uploadTemporaryURL, let finalURL = uploadFinalURL else {
                throw CocoaError(.fileNoSuchFile)
            }

            try FileManager.default.moveItem(at: tempURL, to: finalURL)
            uploadTemporaryURL = nil
            uploadFinalURL = nil

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .localWebShareFilesChanged, object: nil)
            }

            sendJSON(status: "201 Created", object: ["ok": true, "name": finalURL.lastPathComponent])
        } catch {
            cleanupUpload()
            sendText(status: "500 Internal Server Error", text: error.localizedDescription)
        }
    }

    private func cleanupUpload() {
        try? uploadHandle?.close()
        uploadHandle = nil
        if let uploadTemporaryURL {
            try? FileManager.default.removeItem(at: uploadTemporaryURL)
        }
        uploadTemporaryURL = nil
        uploadFinalURL = nil
    }

    private func sendFile(fromPath path: String, headers: [String: String], inline: Bool) {
        let prefix = inline ? "/media/" : "/files/"
        let encodedName = String(path.dropFirst(prefix.count))
        guard let decodedName = encodedName.removingPercentEncoding,
              let safeName = sanitizedFilename(decodedName) else {
            sendText(status: "400 Bad Request", text: "Invalid filename.")
            return
        }

        let fileURL = documentRoot.appendingPathComponent(safeName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            sendText(status: "404 Not Found", text: "File not found.")
            return
        }

        do {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                sendText(status: "404 Not Found", text: "File not found.")
                return
            }

            let size = Int64(values.fileSize ?? 0)
            let contentType = mimeType(for: fileURL.pathExtension)
            let dispositionName = safeName.replacingOccurrences(of: "\"", with: "_")
            let requestedRange = headers["range"].flatMap { parseByteRange($0, fileSize: size) }

            if headers["range"] != nil && requestedRange == nil {
                let responseHeaders = [
                    "HTTP/1.1 416 Range Not Satisfiable",
                    "Content-Range: bytes */\(size)",
                    "Content-Length: 0",
                    "Connection: close",
                    "",
                    ""
                ].joined(separator: "\r\n")
                connection.send(content: Data(responseHeaders.utf8), completion: .contentProcessed { [weak self] _ in
                    self?.didFinish()
                })
                return
            }

            let startOffset = requestedRange?.lowerBound ?? 0
            let endOffset = requestedRange?.upperBound ?? max(0, size - 1)
            let responseLength = size == 0 ? 0 : max(0, endOffset - startOffset + 1)
            let status = requestedRange == nil ? "200 OK" : "206 Partial Content"
            let disposition = inline ? "inline" : "attachment"

            var responseHeaders = [
                "HTTP/1.1 \(status)",
                "Content-Length: \(responseLength)",
                "Content-Type: \(contentType)",
                "Content-Disposition: \(disposition); filename=\"\(dispositionName)\"",
                "Accept-Ranges: bytes",
                "Cache-Control: no-store",
                "Connection: close"
            ]
            if requestedRange != nil {
                responseHeaders.append("Content-Range: bytes \(startOffset)-\(endOffset)/\(size)")
            }
            responseHeaders.append(contentsOf: ["", ""])

            connection.send(content: Data(responseHeaders.joined(separator: "\r\n").utf8), completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.finishWithError(error)
                    return
                }
                if responseLength == 0 {
                    self.didFinish()
                } else {
                    self.streamFile(fileURL, offset: startOffset, remaining: responseLength)
                }
            })
        } catch {
            sendText(status: "500 Internal Server Error", text: error.localizedDescription)
        }
    }

    private func streamFile(_ url: URL, offset: Int64, remaining: Int64) {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: UInt64(max(0, offset)))
            sendNextChunk(handle, remaining: remaining)
        } catch {
            finishWithError(error)
        }
    }

    private func sendNextChunk(_ handle: FileHandle, remaining: Int64) {
        guard remaining > 0 else {
            try? handle.close()
            didFinish()
            return
        }

        do {
            let requested = min(Int64(256 * 1024), remaining)
            let chunk = try handle.read(upToCount: Int(requested)) ?? Data()
            if chunk.isEmpty {
                try? handle.close()
                didFinish()
                return
            }

            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    try? handle.close()
                    self.finishWithError(error)
                } else {
                    self.sendNextChunk(handle, remaining: remaining - Int64(chunk.count))
                }
            })
        } catch {
            try? handle.close()
            finishWithError(error)
        }
    }

    private func parseByteRange(_ header: String, fileSize: Int64) -> ClosedRange<Int64>? {
        guard fileSize > 0, header.lowercased().hasPrefix("bytes=") else { return nil }
        let value = String(header.dropFirst("bytes=".count))
        guard !value.contains(","), let dash = value.firstIndex(of: "-") else { return nil }
        let startText = String(value[..<dash]).trimmingCharacters(in: .whitespaces)
        let endText = String(value[value.index(after: dash)...]).trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            guard let suffix = Int64(endText), suffix > 0 else { return nil }
            let length = min(suffix, fileSize)
            return (fileSize - length)...(fileSize - 1)
        }

        guard let start = Int64(startText), start >= 0, start < fileSize else { return nil }
        let end: Int64
        if endText.isEmpty {
            end = fileSize - 1
        } else {
            guard let parsedEnd = Int64(endText), parsedEnd >= start else { return nil }
            end = min(parsedEnd, fileSize - 1)
        }
        return start...end
    }

    private func deleteFile(fromPath path: String) {
        let encodedName = String(path.dropFirst("/files/".count))
        guard let decodedName = encodedName.removingPercentEncoding,
              let safeName = sanitizedFilename(decodedName) else {
            sendText(status: "400 Bad Request", text: "Invalid filename.")
            return
        }

        let fileURL = documentRoot.appendingPathComponent(safeName)
        do {
            try FileManager.default.removeItem(at: fileURL)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .localWebShareFilesChanged, object: nil)
            }
            sendJSON(status: "200 OK", object: ["ok": true])
        } catch {
            sendText(status: "404 Not Found", text: "File not found.")
        }
    }

    private func sendFileListJSON() {
        let items: [[String: Any]] = ((try? FileManager.default.contentsOfDirectory(
            at: documentRoot,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { return nil }
            return [
                "name": url.lastPathComponent,
                "size": values.fileSize ?? 0,
                "kind": mediaKind(for: url.pathExtension),
                "mime": mimeType(for: url.pathExtension),
                "modified": values.contentModificationDate?.timeIntervalSince1970 ?? 0
            ]
        }.sorted {
            (($0["name"] as? String) ?? "").localizedCaseInsensitiveCompare(($1["name"] as? String) ?? "") == .orderedAscending
        }

        sendJSON(status: "200 OK", object: items)
    }

    private func sendHTML() {
        let html = #"""
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <title>Local Web Share</title>
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
            * { box-sizing: border-box; }
            body { margin: 0; background: Canvas; color: CanvasText; }
            .shell { max-width: 1100px; margin: 0 auto; padding: 28px 18px 70px; }
            h1 { margin: 0; font-size: clamp(28px, 5vw, 42px); }
            h2 { margin: 0 0 14px; font-size: 18px; }
            .sub { opacity: .68; margin: 7px 0 22px; }
            .card { border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); border-radius: 18px; padding: 18px; margin: 18px 0; background: color-mix(in srgb, Canvas 94%, CanvasText 6%); }
            .drop { border: 2px dashed color-mix(in srgb, CanvasText 28%, transparent); border-radius: 16px; min-height: 150px; padding: 24px; display: grid; place-items: center; text-align: center; transition: .15s ease; cursor: pointer; }
            .drop.drag { border-color: #0a84ff; background: color-mix(in srgb, #0a84ff 12%, Canvas); transform: scale(1.005); }
            .drop strong { display: block; font-size: 18px; margin-bottom: 5px; }
            .drop small { opacity: .65; }
            #picker { display: none; }
            #status { white-space: pre-wrap; font-size: 13px; margin: 12px 0 7px; min-height: 18px; }
            progress { width: 100%; height: 8px; }
            .toolbar { display: flex; align-items: center; gap: 10px; justify-content: space-between; margin-bottom: 14px; }
            .count { opacity: .6; font-size: 13px; }
            .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 14px; }
            .file { border: 1px solid color-mix(in srgb, CanvasText 14%, transparent); border-radius: 15px; overflow: hidden; background: Canvas; min-width: 0; }
            .preview { width: 100%; height: 150px; border: 0; padding: 0; margin: 0; display: grid; place-items: center; background: color-mix(in srgb, CanvasText 7%, Canvas); cursor: pointer; overflow: hidden; }
            .preview img, .preview video { width: 100%; height: 100%; object-fit: cover; display: block; }
            .preview video { pointer-events: none; }
            .icon { font-size: 46px; opacity: .72; }
            .body { padding: 12px; }
            .name { font-weight: 650; overflow-wrap: anywhere; line-height: 1.25; cursor: pointer; }
            .meta { font-size: 12px; opacity: .62; margin-top: 5px; }
            .audio-inline { width: 100%; margin-top: 10px; height: 34px; }
            .actions { display: flex; gap: 8px; margin-top: 12px; }
            button, .btn { appearance: none; border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); border-radius: 9px; background: color-mix(in srgb, CanvasText 6%, Canvas); color: inherit; padding: 7px 10px; font: inherit; text-decoration: none; cursor: pointer; }
            button:hover, .btn:hover { background: color-mix(in srgb, CanvasText 11%, Canvas); }
            .danger { margin-left: auto; }
            dialog { width: min(900px, calc(100vw - 28px)); max-height: calc(100vh - 28px); border: 0; border-radius: 18px; padding: 0; background: Canvas; color: CanvasText; box-shadow: 0 25px 80px #0008; }
            dialog::backdrop { background: #0009; backdrop-filter: blur(5px); }
            .modal-head { display: flex; gap: 12px; align-items: center; border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent); padding: 14px 16px; }
            .modal-title { font-weight: 700; overflow-wrap: anywhere; flex: 1; }
            .modal-content { min-height: 260px; max-height: calc(100vh - 165px); overflow: auto; display: grid; place-items: center; background: #000; }
            .modal-content img, .modal-content video { max-width: 100%; max-height: calc(100vh - 165px); }
            .modal-content audio { width: min(680px, calc(100% - 30px)); margin: 80px 15px; }
            .modal-file { color: white; padding: 70px 30px; text-align: center; }
            @media (max-width: 520px) { .grid { grid-template-columns: 1fr; } .shell { padding-inline: 12px; } }
          </style>
        </head>
        <body>
          <main class="shell">
            <h1>Local Web Share</h1>
            <p class="sub">Drop files to upload. Preview images, audio and video directly in the browser.</p>

            <section class="card">
              <div id="drop" class="drop" tabindex="0">
                <div>
                  <strong>Drop files here</strong>
                  <small>or click to choose files — upload starts automatically</small>
                </div>
              </div>
              <input id="picker" type="file" multiple>
              <div id="status"></div>
              <progress id="progress" value="0" max="1" hidden></progress>
            </section>

            <section class="card">
              <div class="toolbar"><h2>Files</h2><span id="count" class="count"></span></div>
              <div id="files" class="grid">Loading…</div>
            </section>
          </main>

          <dialog id="viewer">
            <div class="modal-head">
              <div id="viewerTitle" class="modal-title"></div>
              <a id="viewerDownload" class="btn" download>Download</a>
              <button id="viewerClose" type="button">Close</button>
            </div>
            <div id="viewerContent" class="modal-content"></div>
          </dialog>

          <script>
            const filesEl = document.getElementById('files');
            const countEl = document.getElementById('count');
            const statusEl = document.getElementById('status');
            const progressEl = document.getElementById('progress');
            const dropEl = document.getElementById('drop');
            const pickerEl = document.getElementById('picker');
            const viewer = document.getElementById('viewer');
            const viewerTitle = document.getElementById('viewerTitle');
            const viewerContent = document.getElementById('viewerContent');
            const viewerDownload = document.getElementById('viewerDownload');

            function bytes(n) {
              const u = ['B','KB','MB','GB','TB'];
              let i = 0, v = Number(n);
              while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
              return `${v.toFixed(i ? 1 : 0)} ${u[i]}`;
            }

            function icon(kind) {
              return ({ image:'🖼️', audio:'🎵', video:'🎬', document:'📄', file:'📦' })[kind] || '📦';
            }

            function mediaURL(file) { return '/media/' + encodeURIComponent(file.name); }
            function downloadURL(file) { return '/files/' + encodeURIComponent(file.name); }

            function previewElement(file, large = false) {
              const url = mediaURL(file);
              if (file.kind === 'image') {
                const img = document.createElement('img');
                img.src = url; img.alt = file.name; img.loading = large ? 'eager' : 'lazy';
                return img;
              }
              if (file.kind === 'video') {
                const video = document.createElement('video');
                video.src = url; video.preload = 'metadata'; video.playsInline = true;
                if (large) video.controls = true; else { video.muted = true; video.tabIndex = -1; }
                return video;
              }
              if (file.kind === 'audio' && large) {
                const audio = document.createElement('audio');
                audio.src = url; audio.controls = true; audio.autoplay = true; audio.preload = 'metadata';
                return audio;
              }
              const div = document.createElement('div');
              div.className = large ? 'modal-file' : 'icon';
              div.textContent = icon(file.kind);
              return div;
            }

            function openPreview(file) {
              viewerTitle.textContent = file.name;
              viewerDownload.href = downloadURL(file);
              viewerDownload.download = file.name;
              viewerContent.replaceChildren(previewElement(file, true));
              viewer.showModal();
            }

            function closePreview() {
              viewer.close();
              viewerContent.replaceChildren();
            }

            document.getElementById('viewerClose').onclick = closePreview;
            viewer.addEventListener('click', e => { if (e.target === viewer) closePreview(); });

            async function removeFile(file) {
              if (!confirm(`Delete ${file.name}?`)) return;
              const res = await fetch('/files/' + encodeURIComponent(file.name), { method: 'DELETE' });
              if (!res.ok) throw new Error(await res.text());
              await refresh();
            }

            async function refresh() {
              const res = await fetch('/api/files', { cache: 'no-store' });
              if (!res.ok) throw new Error(await res.text());
              const files = await res.json();
              filesEl.innerHTML = '';
              countEl.textContent = `${files.length} file${files.length === 1 ? '' : 's'}`;
              if (!files.length) {
                filesEl.textContent = 'No files yet. Drop something above.';
                return;
              }

              for (const file of files) {
                const card = document.createElement('article'); card.className = 'file';
                const preview = document.createElement('button'); preview.className = 'preview'; preview.type = 'button';
                preview.append(previewElement(file)); preview.onclick = () => openPreview(file);

                const body = document.createElement('div'); body.className = 'body';
                const name = document.createElement('div'); name.className = 'name'; name.textContent = file.name; name.onclick = () => openPreview(file);
                const meta = document.createElement('div'); meta.className = 'meta'; meta.textContent = `${file.kind.toUpperCase()} • ${bytes(file.size)}`;
                body.append(name, meta);

                if (file.kind === 'audio') {
                  const audio = document.createElement('audio'); audio.className = 'audio-inline'; audio.src = mediaURL(file); audio.controls = true; audio.preload = 'metadata';
                  body.append(audio);
                }

                const actions = document.createElement('div'); actions.className = 'actions';
                const view = document.createElement('button'); view.textContent = 'Preview'; view.onclick = () => openPreview(file);
                const download = document.createElement('a'); download.className = 'btn'; download.textContent = 'Download'; download.href = downloadURL(file); download.download = file.name;
                const del = document.createElement('button'); del.className = 'danger'; del.textContent = 'Delete'; del.onclick = () => removeFile(file).catch(showError);
                actions.append(view, download, del);
                body.append(actions); card.append(preview, body); filesEl.append(card);
              }
            }

            async function uploadFile(file, index, total) {
              statusEl.textContent = `Uploading ${index + 1}/${total}: ${file.name}`;
              progressEl.hidden = false; progressEl.value = index / total;
              const res = await fetch('/upload?filename=' + encodeURIComponent(file.name), {
                method: 'POST',
                headers: { 'Content-Type': file.type || 'application/octet-stream' },
                body: file
              });
              if (!res.ok) throw new Error(await res.text());
              progressEl.value = (index + 1) / total;
            }

            async function uploadFiles(list) {
              const selected = [...list].filter(Boolean);
              if (!selected.length) return;
              try {
                for (let i = 0; i < selected.length; i++) await uploadFile(selected[i], i, selected.length);
                statusEl.textContent = `Uploaded ${selected.length} file${selected.length === 1 ? '' : 's'}.`;
                pickerEl.value = '';
                await refresh();
              } catch (err) {
                showError(err);
              } finally {
                setTimeout(() => { progressEl.hidden = true; }, 900);
              }
            }

            function showError(err) { statusEl.textContent = 'Error: ' + (err?.message || err); }

            dropEl.onclick = () => pickerEl.click();
            dropEl.onkeydown = e => { if (e.key === 'Enter' || e.key === ' ') pickerEl.click(); };
            pickerEl.onchange = () => uploadFiles(pickerEl.files);
            for (const event of ['dragenter','dragover']) {
              document.addEventListener(event, e => { e.preventDefault(); dropEl.classList.add('drag'); });
            }
            for (const event of ['dragleave','drop']) {
              document.addEventListener(event, e => { e.preventDefault(); dropEl.classList.remove('drag'); });
            }
            document.addEventListener('drop', e => uploadFiles(e.dataTransfer.files));

            refresh().catch(err => { filesEl.textContent = 'Could not load files.'; showError(err); });
          </script>
        </body>
        </html>
        """#

        sendResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8))
    }

    private func sendJSON(status: String, object: Any) {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            sendResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
        } catch {
            sendText(status: "500 Internal Server Error", text: error.localizedDescription)
        }
    }

    private func sendText(status: String, text: String) {
        sendResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    private func sendResponse(status: String, contentType: String, body: Data) {
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Length: \(body.count)",
            "Content-Type: \(contentType)",
            "Cache-Control: no-store",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.didFinish()
        })
    }

    private func pathOnly(_ target: String) -> String {
        target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
    }

    private func queryValue(named name: String, in target: String) -> String? {
        guard let components = URLComponents(string: "http://localhost\(target)") else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    private func sanitizedFilename(_ value: String) -> String? {
        let candidate = (value as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate != ".",
              candidate != "..",
              !candidate.hasPrefix(".") else {
            return nil
        }
        return candidate
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private func uniqueDestination(for filename: String) -> URL {
        let proposed = documentRoot.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }

        let ext = proposed.pathExtension
        let base = proposed.deletingPathExtension().lastPathComponent
        var index = 2

        while true {
            let newName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = documentRoot.appendingPathComponent(newName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private func mediaKind(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp":
            return "image"
        case "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac":
            return "audio"
        case "mp4", "m4v", "mov", "avi", "mpeg", "mpg":
            return "video"
        case "pdf", "txt", "rtf", "html", "htm", "json", "xml", "md", "csv":
            return "document"
        default:
            return "file"
        }
    }

    private func mimeType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aiff", "aif": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "flac": return "audio/flac"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mpeg", "mpg": return "video/mpeg"
        case "avi": return "video/x-msvideo"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        case "pdf": return "application/pdf"
        case "txt", "md": return "text/plain; charset=utf-8"
        case "html", "htm": return "text/html; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "xml": return "application/xml; charset=utf-8"
        case "csv": return "text/csv; charset=utf-8"
        case "rtf": return "application/rtf"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    private func finishWithError(_ error: Error) {
        print("LocalWebShare connection error: \(error)")
        didFinish()
    }
}
