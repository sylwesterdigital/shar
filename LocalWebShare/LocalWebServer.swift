import Foundation
import AVFoundation
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
        case ("GET", let path) where path.hasPrefix("/artwork/"):
            sendArtwork(fromPath: path)
        case ("GET", let path) where path.hasPrefix("/ui-icon/"):
            sendUIIcon(fromPath: path)
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
            let kind = mediaKind(for: url.pathExtension)
            let metadata = kind == "audio" ? MediaMetadataReader.read(url) : .empty
            var item: [String: Any] = [
                "name": url.lastPathComponent,
                "size": values.fileSize ?? 0,
                "kind": kind,
                "mime": mimeType(for: url.pathExtension),
                "modified": values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                "hasArtwork": metadata.artworkData != nil
            ]
            if let title = metadata.title, !title.isEmpty { item["title"] = title }
            if let artist = metadata.artist, !artist.isEmpty { item["artist"] = artist }
            return item
        }.sorted {
            (($0["name"] as? String) ?? "").localizedCaseInsensitiveCompare(($1["name"] as? String) ?? "") == .orderedAscending
        }

        sendJSON(status: "200 OK", object: items)
    }

    private func sendArtwork(fromPath path: String) {
        let encodedName = String(path.dropFirst("/artwork/".count))
        guard let decodedName = encodedName.removingPercentEncoding,
              let safeName = sanitizedFilename(decodedName) else {
            sendText(status: "400 Bad Request", text: "Invalid filename.")
            return
        }
        let url = documentRoot.appendingPathComponent(safeName)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = MediaMetadataReader.read(url).artworkData else {
            sendText(status: "404 Not Found", text: "Artwork not found.")
            return
        }
        let mime = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
        sendResponse(status: "200 OK", contentType: mime, body: data)
    }

    private func sendUIIcon(fromPath path: String) {
        let filename = String(path.dropFirst("/ui-icon/".count))
        let name = filename.replacingOccurrences(of: ".svg", with: "")
        guard let encoded = GeneratedUIIcons.base64[name], let data = Data(base64Encoded: encoded) else {
            sendText(status: "404 Not Found", text: "Icon not found.")
            return
        }
        sendResponse(status: "200 OK", contentType: "image/svg+xml; charset=utf-8", body: data)
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
            .shell { max-width: 1120px; margin: 0 auto; padding: 28px 18px 70px; }
            h1 { margin: 0; font-size: clamp(28px,5vw,42px); }
            h2 { margin: 0; font-size: 18px; }
            .sub { opacity: .68; margin: 7px 0 22px; }
            .card { border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); border-radius: 18px; padding: 18px; margin: 18px 0; background: color-mix(in srgb, Canvas 94%, CanvasText 6%); }
            .drop { border: 2px dashed color-mix(in srgb, CanvasText 28%, transparent); border-radius: 16px; min-height: 150px; padding: 24px; display: grid; place-items: center; text-align: center; transition: .15s ease; cursor: pointer; }
            .drop.drag { border-color: #0a84ff; background: color-mix(in srgb,#0a84ff 12%,Canvas); transform: scale(1.005); }
            .drop strong { display:block; font-size:18px; margin-bottom:5px; } .drop small { opacity:.65; }
            #picker { display:none; } #status { white-space:pre-wrap; font-size:13px; margin:12px 0 7px; min-height:18px; } progress { width:100%; height:8px; }
            .toolbar { display:flex; align-items:center; gap:12px; justify-content:space-between; margin-bottom:14px; flex-wrap:wrap; }
            .toolbar-left,.toolbar-right { display:flex; align-items:center; gap:9px; } .count { opacity:.6; font-size:13px; }
            select { border:1px solid color-mix(in srgb,CanvasText 18%,transparent); border-radius:9px; background:Canvas; color:inherit; padding:7px 9px; }
            .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(230px,1fr)); gap:14px; }
            .file { border:1px solid color-mix(in srgb,CanvasText 14%,transparent); border-radius:15px; overflow:hidden; background:Canvas; min-width:0; }
            .preview { width:100%; height:160px; border:0; padding:0; margin:0; display:grid; place-items:center; background:color-mix(in srgb,CanvasText 7%,Canvas); cursor:pointer; overflow:hidden; }
            .preview img,.preview video { width:100%; height:100%; object-fit:cover; display:block; } .preview video { pointer-events:none; }
            .icon { font-size:46px; opacity:.72; } .body { padding:12px; } .name { font-weight:650; overflow-wrap:anywhere; line-height:1.25; cursor:pointer; }
            .meta,.audio-meta { font-size:12px; opacity:.62; margin-top:5px; } .audio-meta { opacity:.82; }
            .audio-mini { display:grid; grid-template-columns:auto 1fr auto; gap:8px; align-items:center; margin-top:10px; }
            .audio-mini input[type=range] { width:100%; min-width:0; } .time { font-size:11px; opacity:.6; font-variant-numeric:tabular-nums; }
            .actions { display:flex; gap:8px; margin-top:12px; align-items:center; }
            button,.btn { appearance:none; border:1px solid color-mix(in srgb,CanvasText 18%,transparent); border-radius:9px; background:color-mix(in srgb,CanvasText 6%,Canvas); color:inherit; padding:7px 10px; font:inherit; text-decoration:none; cursor:pointer; display:inline-flex; align-items:center; justify-content:center; gap:6px; min-height:34px; }
            button:hover,.btn:hover { background:color-mix(in srgb,CanvasText 11%,Canvas); } .danger { margin-left:auto; }
            .ui-icon { width:18px; height:18px; object-fit:contain; display:none; } .fallback-icon { display:none; font-size:16px; line-height:1; }
            body[data-button-mode="icons"] .action-label, body[data-button-mode="icons"] .short-label, body[data-button-mode="icons"] .full-label { display:none; }
            body[data-button-mode="icons"] .ui-icon, body[data-button-mode="icons"] .fallback-icon { display:inline-block; }
            body[data-button-mode="compact"] .ui-icon, body[data-button-mode="compact"] .fallback-icon { display:inline-block; }
            body[data-button-mode="compact"] .full-label { display:none; }
            body[data-button-mode="text"] .short-label, body[data-button-mode="text"] .ui-icon, body[data-button-mode="text"] .fallback-icon { display:none; }
            dialog { width:min(980px,calc(100vw - 24px)); max-height:calc(100vh - 24px); border:0; border-radius:18px; padding:0; background:Canvas; color:CanvasText; box-shadow:0 25px 80px #0008; overflow:hidden; }
            dialog::backdrop { background:#0009; backdrop-filter:blur(5px); }
            .modal-head { display:flex; gap:8px; align-items:center; border-bottom:1px solid color-mix(in srgb,CanvasText 14%,transparent); padding:12px 14px; }
            .modal-title { font-weight:700; overflow-wrap:anywhere; flex:1; min-width:0; }
            .modal-content-wrap { position:relative; background:#000; }
            .modal-content { min-height:300px; height:min(72vh,720px); overflow:auto; display:grid; place-items:center; background:#000; touch-action:pan-y; }
            .modal-content img,.modal-content video { max-width:100%; max-height:100%; } .modal-content audio { width:min(680px,calc(100% - 40px)); }
            .modal-file { color:white; padding:70px 30px; text-align:center; }
            .nav-arrow { position:absolute; z-index:3; top:50%; transform:translateY(-50%); width:44px; height:56px; border-radius:14px; background:#0008; color:white; border-color:#fff4; }
            .nav-arrow.prev { left:10px; } .nav-arrow.next { right:10px; } .nav-arrow:disabled { opacity:.2; cursor:default; }
            .viewer-position { font-size:12px; opacity:.65; white-space:nowrap; }
            @media (max-width:520px) { .grid{grid-template-columns:1fr}.shell{padding-inline:12px}.modal-head{gap:5px}.nav-arrow{width:38px}.action-button{padding-inline:8px} }
          </style>
        </head>
        <body data-button-mode="compact">
          <main class="shell">
            <h1>Local Web Share</h1>
            <p class="sub">Drop files to upload. Preview and browse media without closing the viewer.</p>
            <section class="card">
              <div id="drop" class="drop" tabindex="0"><div><strong>Drop files here</strong><small>or click to choose files — upload starts automatically</small></div></div>
              <input id="picker" type="file" multiple><div id="status"></div><progress id="progress" value="0" max="1" hidden></progress>
            </section>
            <section class="card">
              <div class="toolbar">
                <div class="toolbar-left"><h2>Files</h2><span id="count" class="count"></span></div>
                <div class="toolbar-right"><label for="buttonMode">Buttons</label><select id="buttonMode"><option value="text">Text</option><option value="icons">Icons</option><option value="compact">Icon + short</option></select></div>
              </div>
              <div id="files" class="grid">Loading…</div>
            </section>
          </main>
          <dialog id="viewer">
            <div class="modal-head">
              <button id="viewerPrev" class="action-button" type="button"></button>
              <button id="viewerNext" class="action-button" type="button"></button>
              <div id="viewerTitle" class="modal-title"></div><span id="viewerPosition" class="viewer-position"></span>
              <a id="viewerDownload" class="btn action-button" download></a>
              <button id="viewerDelete" class="action-button" type="button"></button>
              <button id="viewerClose" class="action-button" type="button"></button>
            </div>
            <div class="modal-content-wrap"><button id="overlayPrev" class="nav-arrow prev" aria-label="Previous">‹</button><div id="viewerContent" class="modal-content"></div><button id="overlayNext" class="nav-arrow next" aria-label="Next">›</button></div>
          </dialog>
          <script>
            const q=s=>document.querySelector(s), filesEl=q('#files'),countEl=q('#count'),statusEl=q('#status'),progressEl=q('#progress'),dropEl=q('#drop'),pickerEl=q('#picker'),viewer=q('#viewer'),viewerTitle=q('#viewerTitle'),viewerContent=q('#viewerContent'),viewerDownload=q('#viewerDownload'),viewerPosition=q('#viewerPosition'),buttonMode=q('#buttonMode');
            let currentFiles=[],viewerIndex=-1,touchStartX=null;
            const glyph={preview:'👁',download:'↓',delete:'⌫',close:'×',play:'▶',pause:'Ⅱ',share:'↗',previous:'‹',next:'›'};
            function bytes(n){const u=['B','KB','MB','GB','TB'];let i=0,v=Number(n);while(v>=1024&&i<u.length-1){v/=1024;i++}return `${v.toFixed(i?1:0)} ${u[i]}`}
            function time(v){if(!Number.isFinite(v)||v<0)return '0:00';v=Math.floor(v);return `${Math.floor(v/60)}:${String(v%60).padStart(2,'0')}`}
            function mediaURL(f){return '/media/'+encodeURIComponent(f.name)} function downloadURL(f){return '/files/'+encodeURIComponent(f.name)} function artworkURL(f){return '/artwork/'+encodeURIComponent(f.name)}
            function iconName(kind){return kind==='image'?'photo':kind==='audio'?'sound-on':kind==='video'?'video':'file'}
            function uiIcon(name){const img=document.createElement('img');img.className='ui-icon';img.src='/ui-icon/'+name+'.svg';img.alt='';img.onerror=()=>{img.style.display='none';const fb=img.nextElementSibling;if(fb)fb.style.display='inline-block'};return img}
            function setAction(el,icon,full,short=full){el.classList.add('action-button');el.replaceChildren();el.append(uiIcon(icon));const fb=document.createElement('span');fb.className='fallback-icon';fb.textContent=glyph[icon]||'•';const f=document.createElement('span');f.className='full-label';f.textContent=full;const s=document.createElement('span');s.className='short-label';s.textContent=short;el.append(fb,f,s);el.title=full;el.setAttribute('aria-label',full)}
            function applyMode(mode){if(!['text','icons','compact'].includes(mode))mode='compact';document.body.dataset.buttonMode=mode;buttonMode.value=mode;localStorage.setItem('lws-button-mode',mode)}
            applyMode(localStorage.getItem('lws-button-mode')||'compact');buttonMode.onchange=()=>applyMode(buttonMode.value);
            function genericPreview(f){const d=document.createElement('div');d.className='icon';const i=uiIcon(iconName(f.kind));i.style.width='54px';i.style.height='54px';i.style.display='block';i.onerror=()=>{i.remove();d.textContent=f.kind==='audio'?'🎵':f.kind==='video'?'🎬':f.kind==='image'?'🖼️':'📄'};d.append(i);return d}
            function previewElement(f,large=false){const url=mediaURL(f);if(f.kind==='image'){const x=new Image;x.src=url;x.alt=f.name;x.loading=large?'eager':'lazy';return x}if(f.kind==='video'){const v=document.createElement('video');v.src=url;v.preload='metadata';v.playsInline=true;if(large){v.controls=true;v.autoplay=true}else{v.muted=true;v.tabIndex=-1}return v}if(f.kind==='audio'){if(!large&&f.hasArtwork){const x=new Image;x.src=artworkURL(f);x.alt=f.title||f.name;x.loading='lazy';return x}if(large){const box=document.createElement('div');box.style.width='min(700px,90%)';box.style.color='white';box.style.textAlign='center';if(f.hasArtwork){const x=new Image;x.src=artworkURL(f);x.style.maxWidth='280px';x.style.maxHeight='280px';x.style.borderRadius='14px';box.append(x)}const t=document.createElement('h3');t.textContent=f.title||f.name;box.append(t);if(f.artist){const a=document.createElement('p');a.textContent=f.artist;a.style.opacity='.7';box.append(a)}const audio=document.createElement('audio');audio.src=url;audio.controls=true;audio.autoplay=true;audio.preload='metadata';box.append(audio);return box}}return genericPreview(f)}
            function showViewer(i){if(!currentFiles.length)return;viewerIndex=Math.max(0,Math.min(i,currentFiles.length-1));const f=currentFiles[viewerIndex];viewerTitle.textContent=f.title||f.name;viewerPosition.textContent=`${viewerIndex+1} / ${currentFiles.length}`;viewerDownload.href=downloadURL(f);viewerDownload.download=f.name;viewerContent.replaceChildren(previewElement(f,true));for(const id of ['viewerPrev','overlayPrev'])q('#'+id).disabled=viewerIndex<=0;for(const id of ['viewerNext','overlayNext'])q('#'+id).disabled=viewerIndex>=currentFiles.length-1;if(!viewer.open)viewer.showModal()}
            function openPreview(f){const i=currentFiles.findIndex(x=>x.name===f.name);showViewer(i<0?0:i)} function closePreview(){viewer.close();viewerContent.replaceChildren()}
            function prev(){if(viewerIndex>0)showViewer(viewerIndex-1)} function next(){if(viewerIndex+1<currentFiles.length)showViewer(viewerIndex+1)}
            setAction(q('#viewerPrev'),'previous','Previous','Prev');setAction(q('#viewerNext'),'next','Next','Next');setAction(viewerDownload,'download','Download','Down');setAction(q('#viewerDelete'),'delete','Delete','Del');setAction(q('#viewerClose'),'close','Close','Close');q('#viewerPrev').onclick=q('#overlayPrev').onclick=prev;q('#viewerNext').onclick=q('#overlayNext').onclick=next;q('#viewerClose').onclick=closePreview;q('#viewerDelete').onclick=()=>{const f=currentFiles[viewerIndex];if(f)removeFile(f,true).catch(showError)};
            viewer.addEventListener('click',e=>{if(e.target===viewer)closePreview()});viewerContent.addEventListener('touchstart',e=>{touchStartX=e.changedTouches[0].clientX},{passive:true});viewerContent.addEventListener('touchend',e=>{if(touchStartX==null)return;const dx=e.changedTouches[0].clientX-touchStartX;touchStartX=null;if(dx>60)prev();else if(dx<-60)next()},{passive:true});document.addEventListener('keydown',e=>{if(!viewer.open)return;if(e.key==='ArrowLeft')prev();else if(e.key==='ArrowRight')next();else if(e.key==='Escape')closePreview()});
            function audioMini(f){const wrap=document.createElement('div');wrap.className='audio-mini';const audio=document.createElement('audio');audio.src=mediaURL(f);audio.preload='metadata';const play=document.createElement('button');setAction(play,'play','Play','Play');const seek=document.createElement('input');seek.type='range';seek.min=0;seek.max=1;seek.step=.01;seek.value=0;const tm=document.createElement('span');tm.className='time';tm.textContent='0:00';play.onclick=e=>{e.stopPropagation();if(audio.paused){document.querySelectorAll('audio[data-inline="1"]').forEach(a=>{if(a!==audio)a.pause()});audio.play()}else audio.pause()};audio.dataset.inline='1';audio.onplay=()=>setAction(play,'pause','Pause','Pause');audio.onpause=()=>setAction(play,'play','Play','Play');audio.onloadedmetadata=()=>{seek.max=Number.isFinite(audio.duration)?audio.duration:1};audio.ontimeupdate=()=>{seek.value=audio.currentTime;tm.textContent=time(audio.currentTime)};seek.oninput=e=>{e.stopPropagation();audio.currentTime=Number(seek.value)};seek.onclick=e=>e.stopPropagation();wrap.append(play,seek,tm,audio);audio.hidden=true;return wrap}
            async function removeFile(f,fromViewer=false){if(!confirm(`Delete ${f.name}?`))return;const r=await fetch('/files/'+encodeURIComponent(f.name),{method:'DELETE'});if(!r.ok)throw Error(await r.text());const old=viewerIndex;await refresh();if(fromViewer){if(!currentFiles.length)closePreview();else showViewer(Math.min(old,currentFiles.length-1))}}
            async function refresh(){const r=await fetch('/api/files',{cache:'no-store'});if(!r.ok)throw Error(await r.text());currentFiles=await r.json();filesEl.innerHTML='';countEl.textContent=`${currentFiles.length} file${currentFiles.length===1?'':'s'}`;if(!currentFiles.length){filesEl.textContent='No files yet. Drop something above.';return}for(const f of currentFiles){const card=document.createElement('article');card.className='file';const p=document.createElement('button');p.className='preview';p.type='button';p.append(previewElement(f));p.onclick=()=>openPreview(f);const body=document.createElement('div');body.className='body';const n=document.createElement('div');n.className='name';n.textContent=f.title||f.name;n.onclick=()=>openPreview(f);body.append(n);if(f.kind==='audio'&&f.artist){const am=document.createElement('div');am.className='audio-meta';am.textContent=f.artist;body.append(am)}const m=document.createElement('div');m.className='meta';m.textContent=`${f.kind.toUpperCase()} • ${bytes(f.size)}`;body.append(m);if(f.kind==='audio')body.append(audioMini(f));const ac=document.createElement('div');ac.className='actions';const view=document.createElement('button');setAction(view,'preview','Preview','View');view.onclick=()=>openPreview(f);const d=document.createElement('a');d.className='btn';setAction(d,'download','Download','Down');d.href=downloadURL(f);d.download=f.name;const del=document.createElement('button');del.className='danger';setAction(del,'delete','Delete','Del');del.onclick=()=>removeFile(f).catch(showError);ac.append(view,d,del);body.append(ac);card.append(p,body);filesEl.append(card)}}
            async function uploadFile(file,index,total){statusEl.textContent=`Uploading ${index+1}/${total}: ${file.name}`;progressEl.hidden=false;progressEl.value=index/total;const r=await fetch('/upload?filename='+encodeURIComponent(file.name),{method:'POST',headers:{'Content-Type':file.type||'application/octet-stream'},body:file});if(!r.ok)throw Error(await r.text());progressEl.value=(index+1)/total}
            async function uploadFiles(list){const a=[...list].filter(Boolean);if(!a.length)return;try{for(let i=0;i<a.length;i++)await uploadFile(a[i],i,a.length);statusEl.textContent=`Uploaded ${a.length} file${a.length===1?'':'s'}.`;pickerEl.value='';await refresh()}catch(e){showError(e)}finally{setTimeout(()=>progressEl.hidden=true,900)}} function showError(e){statusEl.textContent='Error: '+(e?.message||e)}
            dropEl.onclick=()=>pickerEl.click();dropEl.onkeydown=e=>{if(e.key==='Enter'||e.key===' ')pickerEl.click()};pickerEl.onchange=()=>uploadFiles(pickerEl.files);for(const e of ['dragenter','dragover'])document.addEventListener(e,x=>{x.preventDefault();dropEl.classList.add('drag')});for(const e of ['dragleave','drop'])document.addEventListener(e,x=>{x.preventDefault();dropEl.classList.remove('drag')});document.addEventListener('drop',e=>uploadFiles(e.dataTransfer.files));refresh().catch(e=>{filesEl.textContent='Could not load files.';showError(e)});
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
