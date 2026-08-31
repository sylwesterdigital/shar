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
        case ("GET", "/3d-viewer.js"):
            sendThreeDViewerJavaScript()
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

    private func sendThreeDViewerJavaScript() {
        sendResponse(status: "200 OK", contentType: "application/javascript; charset=utf-8", body: Data(Self.threeDViewerJavaScript.utf8))
    }

    private static let threeDViewerJavaScript = #"""
function threeDPreview(f){
  const box=document.createElement('div');box.className='three-viewer';
  const canvas=document.createElement('canvas');canvas.setAttribute('aria-label','Interactive 3D preview');
  const tools=document.createElement('div');tools.className='three-tools';
  const light=document.createElement('button'),floor=document.createElement('button'),bg=document.createElement('button'),fit=document.createElement('button');
  light.type=floor.type=bg.type=fit.type='button';light.textContent='☀ Studio';floor.textContent='▱ Floor';bg.textContent='◐ Dark';fit.textContent='⌖ Fit';
  for(const b of [light,floor,bg,fit])b.onclick=e=>e.stopPropagation();
  tools.append(light,floor,bg,fit);const status=document.createElement('div');status.className='three-status';status.textContent='Loading 3D model…';box.append(canvas,tools,status);
  queueMicrotask(()=>startThreeDViewer(canvas,status,f,{light,floor,bg,fit}).catch(e=>{status.textContent='3D preview unavailable: '+(e?.message||e)}));return box
}
function m4Identity(){return new Float32Array([1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1])}
function m4Mul(a,b){const o=new Float32Array(16);for(let c=0;c<4;c++)for(let r=0;r<4;r++){let v=0;for(let k=0;k<4;k++)v+=a[k*4+r]*b[c*4+k];o[c*4+r]=v}return o}
function m4TRS(n){if(Array.isArray(n.matrix)&&n.matrix.length===16)return new Float32Array(n.matrix);const t=n.translation||[0,0,0],s=n.scale||[1,1,1],q=n.rotation||[0,0,0,1],x=q[0],y=q[1],z=q[2],w=q[3],x2=x+x,y2=y+y,z2=z+z,xx=x*x2,xy=x*y2,xz=x*z2,yy=y*y2,yz=y*z2,zz=z*z2,wx=w*x2,wy=w*y2,wz=w*z2;return new Float32Array([(1-(yy+zz))*s[0],(xy+wz)*s[0],(xz-wy)*s[0],0,(xy-wz)*s[1],(1-(xx+zz))*s[1],(yz+wx)*s[1],0,(xz+wy)*s[2],(yz-wx)*s[2],(1-(xx+yy))*s[2],0,t[0],t[1],t[2],1])}
function v3Transform(m,x,y,z){return[m[0]*x+m[4]*y+m[8]*z+m[12],m[1]*x+m[5]*y+m[9]*z+m[13],m[2]*x+m[6]*y+m[10]*z+m[14]]}
function v3Norm(a){const l=Math.hypot(a[0],a[1],a[2])||1;return[a[0]/l,a[1]/l,a[2]/l]}
function m4Perspective(fovy,aspect,near,far){const f=1/Math.tan(fovy/2),nf=1/(near-far),o=new Float32Array(16);o[0]=f/aspect;o[5]=f;o[10]=(far+near)*nf;o[11]=-1;o[14]=2*far*near*nf;return o}
function m4LookAt(eye,target,up=[0,1,0]){const z=v3Norm([eye[0]-target[0],eye[1]-target[1],eye[2]-target[2]]),x=v3Norm([up[1]*z[2]-up[2]*z[1],up[2]*z[0]-up[0]*z[2],up[0]*z[1]-up[1]*z[0]]),y=[z[1]*x[2]-z[2]*x[1],z[2]*x[0]-z[0]*x[2],z[0]*x[1]-z[1]*x[0]],o=m4Identity();o[0]=x[0];o[1]=y[0];o[2]=z[0];o[4]=x[1];o[5]=y[1];o[6]=z[1];o[8]=x[2];o[9]=y[2];o[10]=z[2];o[12]=-(x[0]*eye[0]+x[1]*eye[1]+x[2]*eye[2]);o[13]=-(y[0]*eye[0]+y[1]*eye[1]+y[2]*eye[2]);o[14]=-(z[0]*eye[0]+z[1]*eye[1]+z[2]*eye[2]);return o}
function dataURIBytes(uri){const comma=uri.indexOf(',');if(comma<0)throw Error('Malformed data URI');const head=uri.slice(0,comma),body=uri.slice(comma+1);if(head.includes(';base64')){const raw=atob(body),out=new Uint8Array(raw.length);for(let i=0;i<raw.length;i++)out[i]=raw.charCodeAt(i);return out}return new TextEncoder().encode(decodeURIComponent(body))}
async function loadGltfSource(f){const ext=f.name.split('.').pop().toLowerCase(),url=mediaURL(f);if(ext==='glb'){const ab=await fetch(url,{cache:'no-store'}).then(r=>{if(!r.ok)throw Error('Could not load model');return r.arrayBuffer()}),dv=new DataView(ab);if(dv.byteLength<20||dv.getUint32(0,true)!==0x46546c67)throw Error('Invalid GLB');let off=12,doc=null,bin=null;while(off+8<=dv.byteLength){const len=dv.getUint32(off,true),type=dv.getUint32(off+4,true);off+=8;if(off+len>dv.byteLength)throw Error('Truncated GLB');const bytes=new Uint8Array(ab,off,len);if(type===0x4e4f534a){let text=new TextDecoder().decode(bytes).split(String.fromCharCode(0)).join('').trim();doc=JSON.parse(text)}else if(type===0x004e4942)bin=bytes.slice();off+=len}if(!doc)throw Error('GLB JSON is missing');return{doc,buffers:[bin||new Uint8Array(0)]}}
  const doc=await fetch(url,{cache:'no-store'}).then(r=>{if(!r.ok)throw Error('Could not load glTF');return r.json()}),buffers=[];for(const b of doc.buffers||[]){if(!b.uri){buffers.push(new Uint8Array(0));continue}if(b.uri.startsWith('data:'))buffers.push(dataURIBytes(b.uri));else{const r=await fetch('/media/'+encodeURIComponent(b.uri),{cache:'no-store'});if(!r.ok)throw Error('Missing glTF buffer '+b.uri);buffers.push(new Uint8Array(await r.arrayBuffer()))}}return{doc,buffers}}
function computeNormals(pos,idx){const n=new Float32Array(pos.length),count=idx?idx.length:pos.length/3;for(let k=0;k+2<count;k+=3){const ia=(idx?idx[k]:k)*3,ib=(idx?idx[k+1]:k+1)*3,ic=(idx?idx[k+2]:k+2)*3,ax=pos[ib]-pos[ia],ay=pos[ib+1]-pos[ia+1],az=pos[ib+2]-pos[ia+2],bx=pos[ic]-pos[ia],by=pos[ic+1]-pos[ia+1],bz=pos[ic+2]-pos[ia+2],nx=ay*bz-az*by,ny=az*bx-ax*bz,nz=ax*by-ay*bx;for(const i of [ia,ib,ic]){n[i]+=nx;n[i+1]+=ny;n[i+2]+=nz}}for(let i=0;i<n.length;i+=3){const v=v3Norm([n[i],n[i+1],n[i+2]]);n[i]=v[0];n[i+1]=v[1];n[i+2]=v[2]}return n}
async function startThreeDViewer(canvas,status,f,ui){
  const gl=canvas.getContext('webgl2',{antialias:true,alpha:false});if(!gl)throw Error('WebGL 2 is not available in this browser');const source=await loadGltfSource(f),doc=source.doc,buffers=source.buffers,views=doc.bufferViews||[],accessors=doc.accessors||[];
  function accessor(index,wantFloat=false){const a=accessors[index];if(!a)throw Error('Missing accessor '+index);const v=views[a.bufferView];if(!v)throw Error('Sparse/accessor-only data is not supported yet');const source=buffers[v.buffer||0];if(!source)throw Error('Missing buffer '+(v.buffer||0));const comps={SCALAR:1,VEC2:2,VEC3:3,VEC4:4}[a.type]||1,bytes={5120:1,5121:1,5122:2,5123:2,5125:4,5126:4}[a.componentType];if(!bytes)throw Error('Unsupported accessor component type');const stride=v.byteStride||comps*bytes,base=(v.byteOffset||0)+(a.byteOffset||0),out=wantFloat?new Float32Array(a.count*comps):a.componentType===5125?new Uint32Array(a.count*comps):a.componentType===5123?new Uint16Array(a.count*comps):a.componentType===5121?new Uint8Array(a.count*comps):new Float32Array(a.count*comps),dv=new DataView(source.buffer,source.byteOffset,source.byteLength);for(let i=0;i<a.count;i++)for(let c=0;c<comps;c++){const o=base+i*stride+c*bytes;let val;if(a.componentType===5126)val=dv.getFloat32(o,true);else if(a.componentType===5125)val=dv.getUint32(o,true);else if(a.componentType===5123)val=dv.getUint16(o,true);else if(a.componentType===5122)val=dv.getInt16(o,true);else if(a.componentType===5121)val=dv.getUint8(o);else val=dv.getInt8(o);out[i*comps+c]=val}return out}
  const vs=`#version 300 es\nprecision highp float;in vec3 aPosition;in vec3 aNormal;in vec2 aUV;uniform mat4 uModel;uniform mat4 uVP;out vec3 vPos;out vec3 vNormal;out vec2 vUV;void main(){vec4 w=uModel*vec4(aPosition,1.0);vPos=w.xyz;vNormal=normalize(mat3(uModel)*aNormal);vUV=aUV;gl_Position=uVP*w;}`;
  const fs=`#version 300 es\nprecision highp float;in vec3 vPos;in vec3 vNormal;in vec2 vUV;uniform vec4 uColor;uniform sampler2D uTex;uniform bool uHasTex;uniform vec3 uLight;uniform vec3 uCamera;uniform float uAmbient;uniform float uKey;uniform bool uFloor;uniform float uGrid;out vec4 outColor;void main(){if(uFloor){vec2 g=abs(fract(vPos.xz/uGrid-0.5)-0.5)/fwidth(vPos.xz/uGrid);float line=1.0-min(min(g.x,g.y),1.0);vec3 c=mix(uColor.rgb,uColor.rgb*1.75,line*0.28);outColor=vec4(c,1.0);return;}vec4 base=uColor*(uHasTex?texture(uTex,vUV):vec4(1.0));if(base.a<0.03)discard;vec3 N=normalize(vNormal),L=normalize(uLight),V=normalize(uCamera-vPos);float d=max(dot(N,L),0.0),hemi=0.5+0.5*N.y,rim=pow(1.0-max(dot(N,V),0.0),2.0);vec3 lit=base.rgb*(uAmbient+uKey*d+0.16*hemi)+vec3(0.16)*rim;outColor=vec4(lit,base.a);}`;
  function shader(type,src){const s=gl.createShader(type);gl.shaderSource(s,src);gl.compileShader(s);if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw Error(gl.getShaderInfoLog(s)||'3D shader failed');return s}const prog=gl.createProgram();gl.attachShader(prog,shader(gl.VERTEX_SHADER,vs));gl.attachShader(prog,shader(gl.FRAGMENT_SHADER,fs));gl.linkProgram(prog);if(!gl.getProgramParameter(prog,gl.LINK_STATUS))throw Error(gl.getProgramInfoLog(prog)||'3D shader link failed');gl.useProgram(prog);
  const loc={p:gl.getAttribLocation(prog,'aPosition'),n:gl.getAttribLocation(prog,'aNormal'),uv:gl.getAttribLocation(prog,'aUV'),model:gl.getUniformLocation(prog,'uModel'),vp:gl.getUniformLocation(prog,'uVP'),color:gl.getUniformLocation(prog,'uColor'),tex:gl.getUniformLocation(prog,'uTex'),hasTex:gl.getUniformLocation(prog,'uHasTex'),light:gl.getUniformLocation(prog,'uLight'),camera:gl.getUniformLocation(prog,'uCamera'),ambient:gl.getUniformLocation(prog,'uAmbient'),key:gl.getUniformLocation(prog,'uKey'),floor:gl.getUniformLocation(prog,'uFloor'),grid:gl.getUniformLocation(prog,'uGrid')};
  const white=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,white);gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,1,1,0,gl.RGBA,gl.UNSIGNED_BYTE,new Uint8Array([255,255,255,255]));
  const textureCache=new Map();async function textureFor(material){const ti=material?.pbrMetallicRoughness?.baseColorTexture?.index;if(ti==null)return white;const t=doc.textures?.[ti],im=t&&doc.images?.[t.source];if(!im)return white;if(textureCache.has(t.source))return textureCache.get(t.source);let blob;if(im.bufferView!=null){const v=views[im.bufferView],b=buffers[v.buffer||0];blob=new Blob([b.slice(v.byteOffset||0,(v.byteOffset||0)+v.byteLength)],{type:im.mimeType||'image/png'})}else if(im.uri?.startsWith('data:')){blob=new Blob([dataURIBytes(im.uri)],{type:im.uri.slice(5,im.uri.indexOf(';'))||'image/png'})}else if(im.uri){const r=await fetch('/media/'+encodeURIComponent(im.uri),{cache:'no-store'});if(!r.ok)return white;blob=await r.blob()}else return white;const bitmap=await createImageBitmap(blob),tex=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,tex);gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL,false);gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,bitmap);gl.generateMipmap(gl.TEXTURE_2D);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR_MIPMAP_LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);textureCache.set(t.source,tex);return tex}
  const draws=[],mins=[Infinity,Infinity,Infinity],maxs=[-Infinity,-Infinity,-Infinity];async function addPrimitive(pr,world){if(pr.attributes?.POSITION==null)return;const pos=accessor(pr.attributes.POSITION,true),idx=pr.indices!=null?accessor(pr.indices,false):null,norm=pr.attributes.NORMAL!=null?accessor(pr.attributes.NORMAL,true):computeNormals(pos,idx),uv=pr.attributes.TEXCOORD_0!=null?accessor(pr.attributes.TEXCOORD_0,true):new Float32Array((pos.length/3)*2),mat=doc.materials?.[pr.material]||{},factor=mat.pbrMetallicRoughness?.baseColorFactor||[1,1,1,1],vao=gl.createVertexArray();gl.bindVertexArray(vao);function attr(location,data,size){const b=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,b);gl.bufferData(gl.ARRAY_BUFFER,data,gl.STATIC_DRAW);gl.enableVertexAttribArray(location);gl.vertexAttribPointer(location,size,gl.FLOAT,false,0,0)}attr(loc.p,pos,3);attr(loc.n,norm,3);attr(loc.uv,uv,2);let ib=null,type=gl.UNSIGNED_INT;if(idx){ib=gl.createBuffer();gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER,ib);gl.bufferData(gl.ELEMENT_ARRAY_BUFFER,idx,gl.STATIC_DRAW);type=idx instanceof Uint16Array?gl.UNSIGNED_SHORT:idx instanceof Uint8Array?gl.UNSIGNED_BYTE:gl.UNSIGNED_INT}for(let i=0;i<pos.length;i+=3){const q=v3Transform(world,pos[i],pos[i+1],pos[i+2]);for(let a=0;a<3;a++){mins[a]=Math.min(mins[a],q[a]);maxs[a]=Math.max(maxs[a],q[a])}}draws.push({vao,count:idx?idx.length:pos.length/3,indexed:!!idx,type,model:world,color:factor,tex:await textureFor(mat),mode:pr.mode===1?gl.LINES:pr.mode===0?gl.POINTS:gl.TRIANGLES})}
  const nodes=doc.nodes||[],meshList=doc.meshes||[],roots=doc.scenes?.[doc.scene||0]?.nodes||nodes.map((_,i)=>i);const childSet=new Set(nodes.flatMap(n=>n.children||[])),actualRoots=doc.scenes?.length?roots:roots.filter(i=>!childSet.has(i));async function walk(i,parent){const n=nodes[i]||{},world=m4Mul(parent,m4TRS(n));if(n.mesh!=null)for(const pr of meshList[n.mesh]?.primitives||[])await addPrimitive(pr,world);for(const c of n.children||[])await walk(c,world)}for(const r of actualRoots)await walk(r,m4Identity());if(!draws.length)throw Error('This model has no WebGL-compatible mesh primitives');
  const center=[(mins[0]+maxs[0])/2,(mins[1]+maxs[1])/2,(mins[2]+maxs[2])/2],radius=Math.max(0.1,Math.hypot(maxs[0]-mins[0],maxs[1]-mins[1],maxs[2]-mins[2])/2),floorY=mins[1]-radius*0.025;let yaw=.65,pitch=.28,dist=radius*2.7,target=center.slice(),lightMode=1,floorOn=true,bgMode=0;
  const bgColors=[[.025,.03,.045,1],[.22,.23,.25,1],[.035,.075,.14,1],[.16,.09,.055,1]],bgNames=['Dark','Studio','Blue','Warm'],lightNames=['Soft','Studio','Bright'];
  const floorVAO=gl.createVertexArray();gl.bindVertexArray(floorVAO);const floorPos=new Float32Array([-1,0,-1,1,0,-1,1,0,1,-1,0,-1,1,0,1,-1,0,1]),floorNorm=new Float32Array(18);for(let i=1;i<18;i+=3)floorNorm[i]=1;const floorUV=new Float32Array(12);function floorAttr(location,data,size){const b=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,b);gl.bufferData(gl.ARRAY_BUFFER,data,gl.STATIC_DRAW);gl.enableVertexAttribArray(location);gl.vertexAttribPointer(location,size,gl.FLOAT,false,0,0)}floorAttr(loc.p,floorPos,3);floorAttr(loc.n,floorNorm,3);floorAttr(loc.uv,floorUV,2);
  function fit(){yaw=.65;pitch=.28;dist=radius*2.7;target.splice(0,3,...center);draw()}
  function resize(){const dpr=Math.min(2,devicePixelRatio||1),w=Math.max(2,Math.floor(canvas.clientWidth*dpr)),h=Math.max(2,Math.floor(canvas.clientHeight*dpr));if(canvas.width!==w||canvas.height!==h){canvas.width=w;canvas.height=h}gl.viewport(0,0,w,h)}
  function draw(){resize();const cp=Math.cos(pitch),eye=[target[0]+Math.sin(yaw)*cp*dist,target[1]+Math.sin(pitch)*dist,target[2]+Math.cos(yaw)*cp*dist],view=m4LookAt(eye,target),proj=m4Perspective(Math.PI/4,canvas.width/canvas.height,Math.max(.001,radius/1000),radius*1000+dist),vp=m4Mul(proj,view),bg=bgColors[bgMode];gl.clearColor(...bg);gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);gl.enable(gl.DEPTH_TEST);gl.enable(gl.CULL_FACE);gl.enable(gl.BLEND);gl.blendFunc(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA);gl.useProgram(prog);gl.uniformMatrix4fv(loc.vp,false,vp);gl.uniform3fv(loc.camera,eye);gl.uniform3fv(loc.light,v3Norm([.55,.85,.7]));gl.uniform1f(loc.ambient,[.42,.58,.78][lightMode]);gl.uniform1f(loc.key,[.72,1.05,1.45][lightMode]);gl.activeTexture(gl.TEXTURE0);gl.uniform1i(loc.tex,0);for(const d of draws){gl.bindVertexArray(d.vao);gl.uniformMatrix4fv(loc.model,false,d.model);gl.uniform4fv(loc.color,d.color);gl.bindTexture(gl.TEXTURE_2D,d.tex||white);gl.uniform1i(loc.hasTex,d.tex!==white);gl.uniform1i(loc.floor,0);if(d.indexed)gl.drawElements(d.mode,d.count,d.type,0);else gl.drawArrays(d.mode,0,d.count)}if(floorOn){const scale=radius*4,model=new Float32Array([scale,0,0,0,0,1,0,0,0,0,scale,0,center[0],floorY,center[2],1]);gl.bindVertexArray(floorVAO);gl.uniformMatrix4fv(loc.model,false,model);gl.uniform4fv(loc.color,bgMode===1?[.38,.38,.4,1]:[.09,.1,.12,1]);gl.bindTexture(gl.TEXTURE_2D,white);gl.uniform1i(loc.hasTex,0);gl.uniform1i(loc.floor,1);gl.uniform1f(loc.grid,Math.max(radius/10,.01));gl.disable(gl.CULL_FACE);gl.drawArrays(gl.TRIANGLES,0,6);gl.enable(gl.CULL_FACE)}}
  let dragging=false,lastX=0,lastY=0;canvas.onpointerdown=e=>{dragging=true;lastX=e.clientX;lastY=e.clientY;canvas.setPointerCapture(e.pointerId)};canvas.onpointerup=canvas.onpointercancel=()=>dragging=false;canvas.onpointermove=e=>{if(!dragging)return;const dx=e.clientX-lastX,dy=e.clientY-lastY;lastX=e.clientX;lastY=e.clientY;yaw-=dx*.008;pitch=Math.max(-1.35,Math.min(1.35,pitch+dy*.008));draw()};canvas.onwheel=e=>{e.preventDefault();dist=Math.max(radius*.35,Math.min(radius*12,dist*Math.exp(e.deltaY*.001)));draw()};canvas.ondblclick=fit;
  ui.light.onclick=e=>{e.stopPropagation();lightMode=(lightMode+1)%3;ui.light.textContent='☀ '+lightNames[lightMode];draw()};ui.floor.onclick=e=>{e.stopPropagation();floorOn=!floorOn;ui.floor.textContent=floorOn?'▱ Floor':'▱ No floor';draw()};ui.bg.onclick=e=>{e.stopPropagation();bgMode=(bgMode+1)%bgColors.length;ui.bg.textContent='◐ '+bgNames[bgMode];draw()};ui.fit.onclick=e=>{e.stopPropagation();fit()};new ResizeObserver(draw).observe(canvas);status.textContent='Drag to orbit · wheel/pinch to zoom · double-click to fit';draw();setTimeout(()=>{if(status.textContent.startsWith('Drag to orbit'))status.textContent=''},3200)
}
"""#

    private func sendHTML() {
        let html = #"""
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <title>Shar</title>
          <style>
            :root { color-scheme: light dark; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; --accent:#0a84ff; --accent-soft:color-mix(in srgb,var(--accent) 15%,Canvas); --card-min:150px; --text-scale:.90; --grid-gap:8px; }
            * { box-sizing:border-box; }
            html { font-size:calc(16px * var(--text-scale)); }
            body { margin:0; background:Canvas; color:CanvasText; }
            body[data-theme="forest"] { --accent:#26935b; }
            body[data-theme="sunset"] { --accent:#ef6334; }
            body[data-theme="violet"] { --accent:#8650ed; }
            body[data-theme="system"] { --accent:Highlight; }
            .shell { max-width:1320px; margin:0 auto; padding:8px 10px 42px; }
            .card { border:1px solid color-mix(in srgb,CanvasText 14%,transparent); border-radius:13px; padding:8px; margin:0 0 7px; background:color-mix(in srgb,Canvas 96%,CanvasText 4%); }
            .drop { border:1.5px dashed color-mix(in srgb,CanvasText 24%,transparent); border-radius:11px; min-height:64px; padding:9px 12px; display:grid; place-items:center; text-align:center; transition:.15s ease; cursor:pointer; }
            .drop.drag { border-color:var(--accent); background:var(--accent-soft); transform:scale(1.002); }
            .drop strong { display:block; font-size:.95rem; margin-bottom:2px; } .drop small { opacity:.6; font-size:.78rem; }
            #picker { display:none; } #status { white-space:pre-wrap; font-size:.72rem; margin:5px 0 2px; min-height:10px; } progress { width:100%; height:5px; accent-color:var(--accent); }
            .files-head { display:flex; gap:7px; align-items:center; margin:2px 0 7px; }
            .filters { display:flex; gap:5px; overflow:auto; scrollbar-width:none; flex:1; padding:2px 0; } .filters::-webkit-scrollbar{display:none}
            .filter { white-space:nowrap; border-radius:999px; min-height:28px; padding:4px 9px; font-size:.74rem; font-weight:650; }
            .filter.active { border-color:color-mix(in srgb,var(--accent) 65%,transparent); background:var(--accent-soft); }
            .count { opacity:.58; font-size:.72rem; white-space:nowrap; }
            button,.btn,select,input { font:inherit; }
            button,.btn,select { appearance:none; border:1px solid color-mix(in srgb,CanvasText 18%,transparent); border-radius:8px; background:color-mix(in srgb,CanvasText 6%,Canvas); color:inherit; padding:5px 8px; text-decoration:none; cursor:pointer; display:inline-flex; align-items:center; justify-content:center; gap:5px; min-height:30px; }
            button:hover,.btn:hover { background:color-mix(in srgb,CanvasText 11%,Canvas); }
            .head-tools { display:flex; gap:5px; margin-left:auto; } .settings-button,.info-button { color:var(--accent); min-width:34px; }
            .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(min(var(--card-min),calc(50% - var(--grid-gap))),1fr)); gap:var(--grid-gap); align-items:start; }
            .file { border:1px solid color-mix(in srgb,CanvasText 13%,transparent); border-radius:11px; overflow:hidden; background:Canvas; min-width:0; }
            .preview { width:100%; aspect-ratio:16/10; height:auto; border:0; border-radius:0; padding:0; margin:0; display:grid; place-items:center; background:color-mix(in srgb,CanvasText 7%,Canvas); cursor:pointer; overflow:hidden; }
            .preview img,.preview video { width:100%; height:100%; object-fit:cover; display:block; } .preview video { pointer-events:none; }
            .icon { font-size:2.5rem; opacity:.72; } .body { padding:7px; } .name { font-weight:650; overflow-wrap:anywhere; line-height:1.2; cursor:pointer; }
            .meta,.audio-meta { font-size:.68rem; opacity:.6; margin-top:3px; line-height:1.2; } .audio-meta { opacity:.78; }
            .audio-mini { display:grid; grid-template-columns:auto minmax(40px,1fr) auto; gap:5px; align-items:center; margin-top:6px; }
            .audio-mini button { min-width:30px; padding-inline:5px; }
            .audio-mini input[type=range] { width:100%; min-width:0; accent-color:var(--accent); } .time { font-size:.64rem; opacity:.6; font-variant-numeric:tabular-nums; }
            .actions { display:flex; gap:4px; margin-top:6px; align-items:center; } .danger { margin-left:auto; }
            .actions .action-button,.actions .btn { min-width:31px; padding-inline:6px; }
            .ui-icon { width:17px; height:17px; object-fit:contain; display:none; } .fallback-icon { display:none; font-size:1rem; line-height:1; }
            body[data-button-mode="icons"] .short-label,body[data-button-mode="icons"] .full-label { display:none; }
            body[data-button-mode="icons"] .ui-icon { display:inline-block; }
            body[data-button-mode="icons"] .fallback-icon.missing { display:inline-block; }
            body[data-button-mode="compact"] .ui-icon { display:inline-block; }
            body[data-button-mode="compact"] .fallback-icon.missing { display:inline-block; }
            body[data-button-mode="compact"] .full-label { display:none; }
            body[data-button-mode="text"] .short-label,body[data-button-mode="text"] .ui-icon,body[data-button-mode="text"] .fallback-icon { display:none; }
            body[data-view="list"] .grid { display:block; }
            body[data-view="list"] .file { display:grid; grid-template-columns:clamp(92px,var(--card-min),180px) minmax(0,1fr); margin-bottom:7px; }
            body[data-view="list"] .preview { height:100%; min-height:92px; aspect-ratio:auto; }
            .empty { padding:30px 10px; text-align:center; opacity:.65; }
            dialog { width:min(980px,calc(100vw - 18px)); max-height:calc(100vh - 18px); border:0; border-radius:15px; padding:0; background:Canvas; color:CanvasText; box-shadow:0 25px 80px #0008; overflow:hidden; }
            dialog::backdrop { background:#0009; backdrop-filter:blur(5px); }
            .modal-head { display:flex; gap:5px; align-items:center; border-bottom:1px solid color-mix(in srgb,CanvasText 14%,transparent); padding:7px 8px; }
            .modal-title { font-weight:700; overflow-wrap:anywhere; flex:1; min-width:0; }
            .modal-content-wrap { position:relative; background:#000; }
            .modal-content { min-height:300px; height:min(76vh,760px); overflow:auto; display:grid; place-items:center; background:#000; touch-action:pan-y; }
            .modal-content img,.modal-content video { width:100%; height:100%; max-width:100%; max-height:100%; object-fit:contain; display:block; } .modal-content audio { width:min(680px,calc(100% - 40px)); }
            .nav-arrow { position:absolute; z-index:3; top:50%; transform:translateY(-50%); width:40px; height:52px; border-radius:11px; background:#0008; color:white; border-color:#fff4; }
            .nav-arrow.prev { left:7px; } .nav-arrow.next { right:7px; } .nav-arrow:disabled { opacity:.2; cursor:default; }
            .viewer-position { font-size:.68rem; opacity:.65; white-space:nowrap; }
            .three-viewer { position:relative; width:100%; height:100%; min-height:300px; overflow:hidden; background:#0d0f13; }
            .three-viewer canvas { width:100%; height:100%; display:block; touch-action:none; cursor:grab; }
            .three-viewer canvas:active { cursor:grabbing; }
            .three-tools { position:absolute; z-index:5; right:10px; top:10px; display:flex; gap:6px; padding:6px; border:1px solid #ffffff26; border-radius:11px; background:#111b; backdrop-filter:blur(10px); }
            .three-tools button { min-height:32px; min-width:34px; color:#fff; background:#ffffff12; border-color:#ffffff28; font-size:.72rem; }
            .three-tools button:hover { background:#ffffff22; }
            .three-status { position:absolute; left:12px; bottom:10px; z-index:5; max-width:calc(100% - 24px); padding:6px 9px; border-radius:8px; background:#0009; color:#fff; font-size:.68rem; line-height:1.3; pointer-events:none; }
            .three-status:empty { display:none; }
            .settings-backdrop { position:fixed; inset:0; background:#0005; opacity:0; pointer-events:none; transition:.18s ease; z-index:20; }
            .settings { position:fixed; z-index:21; right:0; top:0; bottom:0; width:min(360px,90vw); padding:16px; background:color-mix(in srgb,Canvas 94%,CanvasText 6%); box-shadow:-18px 0 50px #0005; transform:translateX(105%); transition:.22s ease; overflow:auto; }
            body.settings-open .settings { transform:translateX(0); } body.settings-open .settings-backdrop { opacity:1; pointer-events:auto; }
            .settings-head { display:flex; align-items:center; gap:8px; margin-bottom:18px; }.settings-head h2{font-size:1.15rem;margin:0;flex:1}.settings-group{margin:0 0 19px}.settings-group h3{font-size:.68rem;letter-spacing:.08em;text-transform:uppercase;opacity:.55;margin:0 0 8px}.settings label{display:block;font-size:.8rem;margin:8px 0 4px}.settings select{width:100%}.settings input[type=range]{width:100%;accent-color:var(--accent)}
            .range-label { display:flex!important; align-items:center; gap:8px; }.range-label span{flex:1}.range-label output{font-variant-numeric:tabular-nums;opacity:.65;font-size:.74rem}.settings-actions{display:flex;gap:6px;margin-top:9px}.settings-actions button{flex:1;font-size:.76rem}.settings-note{font-size:.72rem;opacity:.62;margin:7px 0 0;line-height:1.35}.toggle-label{display:flex!important;gap:8px;align-items:center}.toggle-label input{width:auto}.updates{padding:8px 12px 16px;max-height:min(70vh,620px);overflow:auto}.update{padding:10px 2px;border-bottom:1px solid color-mix(in srgb,CanvasText 12%,transparent)}.update:last-child{border-bottom:0}.update-head{display:flex;gap:8px;align-items:baseline}.update-version{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-weight:750;font-size:.78rem}.update-title{font-weight:700;font-size:.82rem}.update-date{margin-left:auto;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.66rem;opacity:.55;white-space:nowrap}.update p{margin:4px 0 0;font-size:.74rem;opacity:.68;line-height:1.35}
            .theme-row{display:grid;grid-template-columns:repeat(5,1fr);gap:6px}.theme-swatch{height:32px;padding:0;border-radius:9px}.theme-swatch[data-theme-choice="ocean"]{background:#0a84ff}.theme-swatch[data-theme-choice="forest"]{background:#26935b}.theme-swatch[data-theme-choice="sunset"]{background:#ef6334}.theme-swatch[data-theme-choice="violet"]{background:#8650ed}.theme-swatch[data-theme-choice="system"]{background:linear-gradient(135deg,#111,#eee)}.theme-swatch.selected{outline:2px solid var(--accent);outline-offset:2px}
            .remote-body{padding:13px;display:grid;gap:11px}.remote-summary{font-size:.78rem;opacity:.7}.remote-link{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:6px}.remote-link input{min-width:0;border:1px solid color-mix(in srgb,CanvasText 18%,transparent);border-radius:8px;padding:7px;background:Canvas;color:CanvasText}.remote-qr{width:min(230px,72vw);height:auto;justify-self:center;background:white;border-radius:12px;padding:8px}.remote-actions{display:flex;flex-wrap:wrap;gap:6px}.remote-actions button{flex:1;min-width:110px}.remote-progress{width:100%;height:8px}.remote-note{font-size:.7rem;opacity:.62;line-height:1.35}.remote-status{font-size:.78rem;font-weight:650}.remote-status[data-state="live"]{color:#2fbf75}.remote-status[data-state="bad"]{color:#e05260}.remote-picker{display:none}.remote-security,.remote-approval{border:1px solid color-mix(in srgb,CanvasText 15%,transparent);border-radius:10px;padding:10px;display:grid;gap:7px}.remote-security[hidden],.remote-approval[hidden]{display:none}.remote-pin{display:flex;align-items:center;gap:8px}.remote-pin strong{font:700 1.15rem ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.12em}.remote-pin button{margin-left:auto}.remote-security small{opacity:.68}.remote-approval .remote-actions{margin-top:2px}
            @media (max-width:560px) { .shell{padding:6px 6px 32px}.card{padding:6px}.drop{min-height:56px}.files-head{gap:5px}.body{padding:6px}.actions{gap:3px}.action-button,.btn{padding-inline:5px}.nav-arrow{width:34px}.modal-head{gap:3px} body[data-view="list"] .file{grid-template-columns:96px minmax(0,1fr)} }
          </style>
        </head>
        <body data-button-mode="icons" data-view="grid" data-theme="ocean">
          <main class="shell">
            <section class="card">
              <div id="drop" class="drop" tabindex="0"><div><strong>Drop files here</strong><small>or click to choose — upload starts automatically</small></div></div>
              <input id="picker" type="file" multiple><div id="status"></div><progress id="progress" value="0" max="1" hidden></progress>
            </section>
            <div class="files-head">
              <div id="filters" class="filters"></div>
              <span id="count" class="count"></span>
              <div class="head-tools"><button id="remoteLocalButton" class="info-button" type="button" aria-label="Remote share files or folder" title="Remote share">↗</button><button id="infoButton" class="info-button" type="button" aria-label="Developer updates" hidden>ⓘ</button><button id="settingsButton" class="settings-button" type="button" aria-label="Settings">⚙</button></div>
            </div>
            <div id="files" class="grid">Loading…</div>
          </main>
          <div id="settingsBackdrop" class="settings-backdrop"></div>
          <aside id="settings" class="settings" aria-label="Settings">
            <div class="settings-head"><h2>Settings</h2><button id="settingsClose" type="button" aria-label="Close settings"></button></div>
            <div class="settings-group"><h3>Layout preset</h3><label for="presetSelect">Preset</label><select id="presetSelect"><option value="minimal">Minimal</option><option value="balanced">Balanced</option><option value="large">Large</option><option value="saved">My saved preset</option><option value="custom">Custom</option></select><div class="settings-actions"><button id="savePreset" type="button">Save current</button><button id="resetMinimal" type="button">Use minimal</button></div><p class="settings-note">Minimal is the default. Saving stores the current buttons, layout, theme, thumbnail size and text size in this browser.</p></div>
            <div class="settings-group"><h3>Buttons</h3><label for="buttonMode">Labels</label><select id="buttonMode"><option value="text">Text</option><option value="icons">Icons</option><option value="compact">Icon + short</option></select></div>
            <div class="settings-group"><h3>Files</h3><label for="viewMode">Layout</label><select id="viewMode"><option value="grid">Grid</option><option value="list">List</option></select><label class="range-label" for="thumbSize"><span>Thumbnail / card size</span><output id="thumbValue"></output></label><input id="thumbSize" type="range" min="120" max="320" step="10"><label class="range-label" for="textScale"><span>Text size</span><output id="textValue"></output></label><input id="textScale" type="range" min="75" max="125" step="5"><p class="settings-note">Smaller thumbnails automatically fit more grid columns. On narrow screens the grid keeps at least two columns.</p></div>
            <div class="settings-group"><h3>Colour theme</h3><div class="theme-row"><button class="theme-swatch" data-theme-choice="system" title="System"></button><button class="theme-swatch" data-theme-choice="ocean" title="Ocean"></button><button class="theme-swatch" data-theme-choice="forest" title="Forest"></button><button class="theme-swatch" data-theme-choice="sunset" title="Sunset"></button><button class="theme-swatch" data-theme-choice="violet" title="Violet"></button></div></div>
            <div class="settings-group"><h3>Developer</h3><label class="toggle-label"><input id="showDeveloperInfo" type="checkbox"> <span>Show ⓘ updates button</span></label><p class="settings-note">Hidden by default. Enable it to show a compact list of recent Shar development changes beside Settings.</p></div>
            <div class="settings-group"><h3>Remote sharing</h3><p class="settings-note">The ↗ button creates a temporary Internet share using encrypted WebRTC. Direct peer-to-peer is preferred; Shar TURN is used only when NAT/firewalls require a relay.</p></div>
            <div class="settings-group"><h3>Playback</h3><p class="settings-note">Only one audio or video player can play at a time.</p></div>
          </aside>
          <dialog id="developerInfo">
            <div class="modal-head"><div class="modal-title">Developer updates</div><button id="developerInfoClose" class="action-button" type="button"></button></div>
            <div class="updates">
              <div class="update"><div class="update-head"><span class="update-version">v2.2.32</span><span class="update-title">macOS 3D thumbnail build hotfix</span><span class="update-date">2026-08-31</span></div><p>Fixed the macOS async 3D thumbnail fallback compile regression and added a release guard that catches invalid async nil-coalescing before packaging.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.2.3</span><span class="update-title">3D thumbnails + compact workflow</span><span class="update-date">2026-08-31</span></div><p>Added native 3D thumbnail capture/recapture, visual file confirmation in Secure Remote Share, compact iOS settings and Grid/List switching, clearer Files access, first-run add affordance, dated updates, and highlighted current actions.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.2.2</span><span class="update-title">iOS grid controls + release resilience</span><span class="update-date">2026-08-31</span></div><p>Restored fixed-size iOS grid action controls and made attached-device storage exhaustion non-blocking for distribution publishing after successful build/sign validation.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.2.1</span><span class="update-title">macOS presentation polish</span><span class="update-date">2026-08-30</span></div><p>Fixed the About window size, image fit-on-open behavior, and compacted Secure Remote Share with larger always-visible actions.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.2.0</span><span class="update-title">Polished 3D preview</span><span class="update-date">2026-08-30</span></div><p>Added native and browser 3D lighting/floor/background controls, local WebGL model rendering, and bundled Previous/Next icons.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.1.3</span><span class="update-title">Unified native library UI</span><span class="update-date">2026-08-30</span></div><p>macOS now mirrors the iOS Grid/List and media-filter library, with cog-based Config plus About and Support across native clients.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.1.2</span><span class="update-title">Native macOS Secure Remote Share</span><span class="update-date">2026-08-30</span></div><p>Remote sharing on macOS now stays inside the native app with PIN, QR/link, approval, encrypted-transfer progress and verified completion UI.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.1.1</span><span class="update-title">Android build fix</span><span class="update-date">2026-08-30</span></div><p>Fixed Android secure-share browser embedding and added a Java text-block compile guard to release verification.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.1.0</span><span class="update-title">Secure Remote Share</span><span class="update-date">2026-08-30</span></div><p>Added AES-256-GCM encryption, separate PIN verification, sender approval, SHA-256 integrity checks, private metadata mode, and hardened TURN/API privacy.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.0.8</span><span class="update-title">Remote sender startup fix</span><span class="update-date">2026-08-30</span></div><p>Fixed native iOS Remote Share startup and removed Google STUN from runtime ICE; Shar now uses its own STUN/TURN service.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.0.7</span><span class="update-title">Remote completion handshake</span><span class="update-date">2026-08-30</span></div><p>Successful remote downloads now remain complete, acknowledge receipt back to the sender, and ignore expected post-transfer cleanup errors.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.0.6</span><span class="update-title">Native link sharing</span><span class="update-date">2026-08-30</span></div><p>Fixed iPhone Remote Share so Share link opens the native iOS share sheet for Messages, Mail, AirDrop and installed messaging apps.</p></div>
              
              <div class="update"><div class="update-head"><span class="update-version">v2.0.5</span><span class="update-title">Remote service readiness</span><span class="update-date">2026-08-30</span></div><p>Fixed the signaling-service startup race and added readiness diagnostics before nginx/public-route validation.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.0.4</span><span class="update-title">Native iPhone Remote Share</span><span class="update-date">2026-08-30</span></div><p>Remote sharing now starts directly from the native iOS file card and shows a native QR/link transfer sheet without opening the local browser UI.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.0.3</span><span class="update-title">Public route verification</span><span class="update-date">2026-08-30</span></div><p>Made the real public HTTPS API authoritative and hardened nginx repair for duplicate/address-bound apex vhosts.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.0.2</span><span class="update-title">Remote routing repair</span><span class="update-date">2026-08-30</span></div><p>Fixed exact mojoworks.xyz API routing and automatic repair when the public share endpoint returns 404.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.0.1</span><span class="update-title">Android release fix</span><span class="update-date">2026-08-30</span></div><p>Restored Android release compilation and made the visible version read from package metadata.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.0.0</span><span class="update-title">Remote WebRTC sharing</span><span class="update-date">2026-08-29</span></div><p>Added temporary QR/link shares, encrypted peer-to-peer data channels, TURN fallback, and automated remote infrastructure deployment.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v1.7.6</span><span class="update-title">Optional developer info</span><span class="update-date">2026-08-29</span></div><p>Added the hidden-by-default ⓘ updates panel and Settings toggle.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v1.7.5</span><span class="update-title">Cross-platform audio fix</span><span class="update-date">2026-08-29</span></div><p>Kept iOS background audio while restoring the macOS release build.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v1.7.4</span><span class="update-title">Background audio</span><span class="update-date">2026-08-29</span></div><p>Audio can continue with Shar minimized or the iPhone screen locked.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v1.7.3</span><span class="update-title">Better preview</span><span class="update-date">2026-08-29</span></div><p>Images fit the viewer and previews gained a persistent X close control.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v1.7.2</span><span class="update-title">More ways to add</span><span class="update-date">2026-08-29</span></div><p>Added Photos & Videos, camera recording, and Files from the + menu.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v1.7.1</span><span class="update-title">Shar identity</span><span class="update-date">2026-08-29</span></div><p>Renamed the visible product to Shar and added the persistent iOS + importer.</p></div>
            </div>
          </dialog>
          <dialog id="remoteShare">
            <div class="modal-head"><div class="modal-title">Remote share</div><button id="remoteClose" class="action-button" type="button"></button></div>
            <div class="remote-body">
              <div id="remoteSummary" class="remote-summary">Choose a Shar file, local files, or a folder.</div>
              <div id="remoteStatus" class="remote-status">Ready.</div>
              <img id="remoteQR" class="remote-qr" alt="Shar remote share QR code" hidden>
              <div id="remoteLinkRow" class="remote-link" hidden><input id="remoteLink" readonly aria-label="Remote share link"><button id="remoteCopy" type="button">Copy</button></div>
              <div id="remoteSecurity" class="remote-security" hidden><div class="remote-pin"><span>Receiver PIN</span><strong id="remotePIN"></strong><button id="remoteCopyPIN" type="button">Copy PIN</button></div><small>AES-256-GCM key stays in the URL fragment and is never sent to Shar servers. Send the PIN separately when practical.</small></div>
              <div id="remoteApproval" class="remote-approval" hidden><strong>Receiver requests access</strong><span class="remote-summary">Correct PIN entered. Approve this device before connection credentials are released.</span><div class="remote-actions"><button id="remoteReject" type="button">Reject</button><button id="remoteApprove" type="button">Approve</button></div></div>
              <progress id="remoteProgress" class="remote-progress" value="0" max="1" hidden></progress>
              <div class="remote-actions"><button id="remoteChooseFiles" type="button">Choose files</button><button id="remoteChooseFolder" type="button">Choose folder</button><button id="remoteSystemShare" type="button" hidden>Share link</button><button id="remoteCancel" type="button" hidden>Cancel share</button></div>
              <input id="remoteFilePicker" class="remote-picker" type="file" multiple><input id="remoteFolderPicker" class="remote-picker" type="file" webkitdirectory multiple>
              <div class="remote-note">Secure links expire after 30 minutes and accept one receiver. A separate PIN and sender approval are required. File contents and metadata are AES-256-GCM encrypted before WebRTC, and each file is SHA-256 verified. Keep this Shar page/app open until transfer completes.</div>
            </div>
          </dialog>
          <dialog id="viewer">
            <div class="modal-head">
              <button id="viewerPrev" class="action-button" type="button"></button><button id="viewerNext" class="action-button" type="button"></button>
              <div id="viewerTitle" class="modal-title"></div><span id="viewerPosition" class="viewer-position"></span>
              <a id="viewerDownload" class="btn action-button" download></a><button id="viewerDelete" class="action-button" type="button"></button><button id="viewerClose" class="action-button" type="button"></button>
            </div>
            <div class="modal-content-wrap"><button id="overlayPrev" class="nav-arrow prev" aria-label="Previous">‹</button><div id="viewerContent" class="modal-content"></div><button id="overlayNext" class="nav-arrow next" aria-label="Next">›</button></div>
          </dialog>
          <script src="/3d-viewer.js"></script>
          <script>
            const q=s=>document.querySelector(s), filesEl=q('#files'),countEl=q('#count'),statusEl=q('#status'),progressEl=q('#progress'),dropEl=q('#drop'),pickerEl=q('#picker'),viewer=q('#viewer'),viewerTitle=q('#viewerTitle'),viewerContent=q('#viewerContent'),viewerDownload=q('#viewerDownload'),viewerPosition=q('#viewerPosition'),buttonMode=q('#buttonMode'),viewMode=q('#viewMode'),filtersEl=q('#filters'),presetSelect=q('#presetSelect'),thumbSize=q('#thumbSize'),thumbValue=q('#thumbValue'),textScale=q('#textScale'),textValue=q('#textValue'),infoButton=q('#infoButton'),showDeveloperInfo=q('#showDeveloperInfo'),developerInfo=q('#developerInfo'),remoteShare=q('#remoteShare'),remoteStatus=q('#remoteStatus'),remoteSummary=q('#remoteSummary'),remoteQR=q('#remoteQR'),remoteLink=q('#remoteLink'),remoteLinkRow=q('#remoteLinkRow'),remoteProgress=q('#remoteProgress'),remoteFilePicker=q('#remoteFilePicker'),remoteFolderPicker=q('#remoteFolderPicker');
            let currentFiles=[],viewerFiles=[],viewerIndex=-1,touchStartX=null,currentFilter='all';
            const REMOTE_API='https://mojoworks.xyz/api/shar/remote/v1';let remoteSession=null,remotePC=null,remoteDC=null,remoteSignalSeq=0,remotePollTimer=null,remotePendingCandidates=[],remoteSources=[],remoteSent=0,remoteCompleted=false,remoteAckResolve=null,remoteAESKey=null,remoteApprovalRequestId='',remoteHashes=[];const REMOTE_PIN_ITERATIONS=150000;
            const glyph={preview:'👁',download:'↓',delete:'⌫',close:'×',play:'▶',pause:'Ⅱ',share:'↗',previous:'‹',next:'›',config:'⚙',info:'ⓘ'};
            const filterDefs=[['all','All'],['image','Images'],['audio','Audio'],['video','Video'],['threeD','3D'],['document','Docs'],['file','Other']];
            const presets={minimal:{thumb:150,text:90,mode:'icons',view:'grid',theme:'ocean'},balanced:{thumb:210,text:100,mode:'compact',view:'grid',theme:'ocean'},large:{thumb:280,text:110,mode:'text',view:'grid',theme:'system'}};
            function bytes(n){const u=['B','KB','MB','GB','TB'];let i=0,v=Number(n);while(v>=1024&&i<u.length-1){v/=1024;i++}return `${v.toFixed(i?1:0)} ${u[i]}`}
            function time(v){if(!Number.isFinite(v)||v<0)return '0:00';v=Math.floor(v);return `${Math.floor(v/60)}:${String(v%60).padStart(2,'0')}`}
            function clamp(v,min,max){return Math.max(min,Math.min(max,Number(v)||min))}
            function mediaURL(f){return '/media/'+encodeURIComponent(f.name)} function downloadURL(f){return '/files/'+encodeURIComponent(f.name)} function artworkURL(f){return '/artwork/'+encodeURIComponent(f.name)}
            function iconName(kind){return kind==='image'?'photo':kind==='audio'?'sound-on':kind==='video'?'video':'file'}
            const inlineIcons={previous:'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 18 9 12l6-6"/></svg>',next:'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="m9 18 6-6-6-6"/></svg>'};
            function uiIcon(name){const img=document.createElement('img');img.className='ui-icon';img.alt='';if(inlineIcons[name]){img.src='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(inlineIcons[name]);return img}img.src='/ui-icon/'+name+'.svg';img.onerror=()=>{img.style.display='none';const fb=img.nextElementSibling;if(fb)fb.classList.add('missing')};return img}
            function setAction(el,icon,full,short=full){el.classList.add('action-button');el.replaceChildren();el.append(uiIcon(icon));const fb=document.createElement('span');fb.className='fallback-icon';fb.textContent=glyph[icon]||'•';const f=document.createElement('span');f.className='full-label';f.textContent=full;const s=document.createElement('span');s.className='short-label';s.textContent=short;el.append(fb,f,s);el.title=full;el.setAttribute('aria-label',full)}
            function applyMode(mode,persist=true){if(!['text','icons','compact'].includes(mode))mode='icons';document.body.dataset.buttonMode=mode;buttonMode.value=mode;if(persist)localStorage.setItem('lws-button-mode',mode)}
            function applyView(mode,persist=true){if(!['grid','list'].includes(mode))mode='grid';document.body.dataset.view=mode;viewMode.value=mode;if(persist)localStorage.setItem('lws-view-mode',mode)}
            function applyTheme(theme,persist=true){if(!['system','ocean','forest','sunset','violet'].includes(theme))theme='ocean';document.body.dataset.theme=theme;if(persist)localStorage.setItem('lws-theme',theme);document.querySelectorAll('.theme-swatch').forEach(x=>x.classList.toggle('selected',x.dataset.themeChoice===theme))}
            function applyDensity(thumb,text,persist=true){thumb=clamp(thumb,120,320);text=clamp(text,75,125);document.documentElement.style.setProperty('--card-min',thumb+'px');document.documentElement.style.setProperty('--text-scale',(text/100).toFixed(2));thumbSize.value=thumb;textScale.value=text;thumbValue.textContent=thumb+' px';textValue.textContent=text+'%';if(persist){localStorage.setItem('lws-thumb-size',String(thumb));localStorage.setItem('lws-text-scale',String(text))}}
            function savedPreset(){try{return JSON.parse(localStorage.getItem('lws-saved-preset')||'null')}catch{return null}}
            function currentSettings(){return{thumb:Number(thumbSize.value),text:Number(textScale.value),mode:buttonMode.value,view:viewMode.value,theme:document.body.dataset.theme||'ocean'}}
            function setPresetChoice(name){presetSelect.value=name;localStorage.setItem('lws-preset-v2',name)}
            function markCustom(){setPresetChoice('custom')}
            function applyPreset(name,persist=true){let p=presets[name];if(name==='saved')p=savedPreset();if(!p){name='minimal';p=presets.minimal}applyMode(p.mode,false);applyView(p.view,false);applyTheme(p.theme,false);applyDensity(p.thumb,p.text,false);localStorage.setItem('lws-button-mode',p.mode);localStorage.setItem('lws-view-mode',p.view);localStorage.setItem('lws-theme',p.theme);localStorage.setItem('lws-thumb-size',String(p.thumb));localStorage.setItem('lws-text-scale',String(p.text));if(persist)setPresetChoice(name);else presetSelect.value=name}
            function restoreUI(){const chosen=localStorage.getItem('lws-preset-v2');if(chosen==='saved'&&savedPreset()){applyPreset('saved',false);presetSelect.value='saved'}else if(chosen&&presets[chosen]){applyPreset(chosen,false);presetSelect.value=chosen}else if(chosen==='custom'){applyMode(localStorage.getItem('lws-button-mode')||'icons',false);applyView(localStorage.getItem('lws-view-mode')||'grid',false);applyTheme(localStorage.getItem('lws-theme')||'ocean',false);applyDensity(localStorage.getItem('lws-thumb-size')||150,localStorage.getItem('lws-text-scale')||90,false);presetSelect.value='custom'}else applyPreset('minimal',true);applyDeveloperInfo(localStorage.getItem('lws-show-developer-info')==='1',false)}
            function applyDeveloperInfo(show,persist=true){show=!!show;showDeveloperInfo.checked=show;infoButton.hidden=!show;if(persist)localStorage.setItem('lws-show-developer-info',show?'1':'0')}
            infoButton.textContent='ⓘ';infoButton.title='Developer updates';infoButton.setAttribute('aria-label','Developer updates');setAction(q('#settingsButton'),'config','Settings','Settings');setAction(q('#settingsClose'),'close','Close','Close');setAction(q('#developerInfoClose'),'close','Close','Close');restoreUI();
            presetSelect.onchange=()=>applyPreset(presetSelect.value,true);buttonMode.onchange=()=>{applyMode(buttonMode.value);markCustom()};viewMode.onchange=()=>{applyView(viewMode.value);markCustom()};thumbSize.oninput=()=>{applyDensity(thumbSize.value,textScale.value);markCustom()};textScale.oninput=()=>{applyDensity(thumbSize.value,textScale.value);markCustom()};document.querySelectorAll('.theme-swatch').forEach(x=>x.onclick=()=>{applyTheme(x.dataset.themeChoice);markCustom()});
            q('#savePreset').onclick=()=>{localStorage.setItem('lws-saved-preset',JSON.stringify(currentSettings()));setPresetChoice('saved');presetSelect.value='saved';q('#savePreset').textContent='Saved ✓';setTimeout(()=>q('#savePreset').textContent='Save current',1000)};q('#resetMinimal').onclick=()=>applyPreset('minimal',true);
            showDeveloperInfo.onchange=()=>applyDeveloperInfo(showDeveloperInfo.checked,true);infoButton.onclick=()=>developerInfo.showModal();q('#developerInfoClose').onclick=()=>developerInfo.close();developerInfo.addEventListener('click',e=>{if(e.target===developerInfo)developerInfo.close()});q('#settingsButton').onclick=()=>document.body.classList.add('settings-open');q('#settingsClose').onclick=q('#settingsBackdrop').onclick=()=>document.body.classList.remove('settings-open');
            function visibleFiles(){return currentFilter==='all'?currentFiles:currentFiles.filter(f=>f.kind===currentFilter)}
            function pauseOtherMedia(except){document.querySelectorAll('audio,video').forEach(m=>{if(m!==except&&!m.paused)m.pause()})}
            function bindExclusive(media){media.addEventListener('play',()=>pauseOtherMedia(media));return media}
            function genericPreview(f){const d=document.createElement('div');d.className='icon';const i=uiIcon(iconName(f.kind));i.style.width='54px';i.style.height='54px';i.style.display='block';i.onerror=()=>{i.remove();d.textContent=f.kind==='audio'?'🎵':f.kind==='video'?'🎬':f.kind==='image'?'🖼️':f.kind==='threeD'?'◈':'📄'};d.append(i);return d}
            function previewElement(f,large=false){const url=mediaURL(f);if(f.kind==='threeD'&&large)return threeDPreview(f);if(f.kind==='image'){const x=new Image;x.src=url;x.alt=f.name;x.loading=large?'eager':'lazy';return x}if(f.kind==='video'){const v=bindExclusive(document.createElement('video'));v.src=url;v.preload='metadata';v.playsInline=true;if(large){v.controls=true;v.autoplay=true}else{v.muted=true;v.tabIndex=-1}return v}if(f.kind==='audio'){if(!large&&f.hasArtwork){const x=new Image;x.src=artworkURL(f);x.alt=f.title||f.name;x.loading='lazy';return x}if(large){const box=document.createElement('div');box.style.width='min(700px,90%)';box.style.color='white';box.style.textAlign='center';if(f.hasArtwork){const x=new Image;x.src=artworkURL(f);x.style.maxWidth='280px';x.style.maxHeight='280px';x.style.borderRadius='14px';box.append(x)}const t=document.createElement('h3');t.textContent=f.title||f.name;box.append(t);if(f.artist){const a=document.createElement('p');a.textContent=f.artist;a.style.opacity='.7';box.append(a)}const audio=bindExclusive(document.createElement('audio'));audio.src=url;audio.controls=true;audio.autoplay=true;audio.preload='metadata';box.append(audio);return box}}return genericPreview(f)}
            function showViewer(i){viewerFiles=visibleFiles();if(!viewerFiles.length)return;viewerIndex=Math.max(0,Math.min(i,viewerFiles.length-1));const f=viewerFiles[viewerIndex];pauseOtherMedia(null);viewerTitle.textContent=f.title||f.name;viewerPosition.textContent=`${viewerIndex+1} / ${viewerFiles.length}`;viewerDownload.href=downloadURL(f);viewerDownload.download=f.name;viewerContent.replaceChildren(previewElement(f,true));for(const id of ['viewerPrev','overlayPrev'])q('#'+id).disabled=viewerIndex<=0;for(const id of ['viewerNext','overlayNext'])q('#'+id).disabled=viewerIndex>=viewerFiles.length-1;if(!viewer.open)viewer.showModal()}
            function openPreview(f){viewerFiles=visibleFiles();const i=viewerFiles.findIndex(x=>x.name===f.name);showViewer(i<0?0:i)} function closePreview(){pauseOtherMedia(null);viewer.close();viewerContent.replaceChildren()}
            function prev(){if(viewerIndex>0)showViewer(viewerIndex-1)} function next(){if(viewerIndex+1<viewerFiles.length)showViewer(viewerIndex+1)}
            setAction(q('#viewerPrev'),'previous','Previous','Prev');setAction(q('#viewerNext'),'next','Next','Next');setAction(viewerDownload,'download','Download','Down');setAction(q('#viewerDelete'),'delete','Delete','Del');setAction(q('#viewerClose'),'close','Close','Close');q('#viewerPrev').onclick=q('#overlayPrev').onclick=prev;q('#viewerNext').onclick=q('#overlayNext').onclick=next;q('#viewerClose').onclick=closePreview;q('#viewerDelete').onclick=()=>{const f=viewerFiles[viewerIndex];if(f)removeFile(f,true).catch(showError)};
            viewer.addEventListener('click',e=>{if(e.target===viewer)closePreview()});viewerContent.addEventListener('touchstart',e=>{touchStartX=e.changedTouches[0].clientX},{passive:true});viewerContent.addEventListener('touchend',e=>{if(touchStartX==null)return;const dx=e.changedTouches[0].clientX-touchStartX;touchStartX=null;if(dx>60)prev();else if(dx<-60)next()},{passive:true});document.addEventListener('keydown',e=>{if(!viewer.open)return;if(e.key==='ArrowLeft')prev();else if(e.key==='ArrowRight')next();else if(e.key==='Escape')closePreview()});
            function audioMini(f){const wrap=document.createElement('div');wrap.className='audio-mini';const audio=bindExclusive(document.createElement('audio'));audio.src=mediaURL(f);audio.preload='metadata';const play=document.createElement('button');setAction(play,'play','Play','Play');const seek=document.createElement('input');seek.type='range';seek.min=0;seek.max=1;seek.step=.01;seek.value=0;const tm=document.createElement('span');tm.className='time';tm.textContent='0:00';play.onclick=e=>{e.stopPropagation();audio.paused?audio.play():audio.pause()};audio.onplay=()=>setAction(play,'pause','Pause','Pause');audio.onpause=()=>setAction(play,'play','Play','Play');audio.onloadedmetadata=()=>{seek.max=Number.isFinite(audio.duration)?audio.duration:1};audio.ontimeupdate=()=>{seek.value=audio.currentTime;tm.textContent=time(audio.currentTime)};seek.oninput=e=>{e.stopPropagation();audio.currentTime=Number(seek.value)};seek.onclick=e=>e.stopPropagation();wrap.append(play,seek,tm,audio);audio.hidden=true;return wrap}
            const remotePIN=q('#remotePIN'),remoteSecurity=q('#remoteSecurity'),remoteApproval=q('#remoteApproval');
            function remoteB64url(u){let s='';for(const b of u)s+=String.fromCharCode(b);return btoa(s).split('+').join('-').split('/').join('_').replace(/=+$/,'')}
            function remoteRandomPin(){const x=new Uint32Array(1);do{crypto.getRandomValues(x)}while(x[0]>=4294000000);return String(x[0]%1000000).padStart(6,'0')}
            async function remotePinVerifier(pin,salt){const material=await crypto.subtle.importKey('raw',new TextEncoder().encode(pin),'PBKDF2',false,['deriveBits']);const bits=await crypto.subtle.deriveBits({name:'PBKDF2',hash:'SHA-256',salt,iterations:REMOTE_PIN_ITERATIONS},material,256);return remoteB64url(new Uint8Array(bits))}
            class RemoteSha256{constructor(){this.h=new Uint32Array([0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]);this.buf=new Uint8Array(64);this.bufLen=0;this.bytes=0;this.w=new Uint32Array(64)}static rotr(x,n){return(x>>>n)|(x<<(32-n))}_block(b,o=0){const w=this.w;for(let i=0;i<16;i++){const j=o+i*4;w[i]=((b[j]<<24)|(b[j+1]<<16)|(b[j+2]<<8)|b[j+3])>>>0}for(let i=16;i<64;i++){const x=w[i-15],y=w[i-2],s0=(RemoteSha256.rotr(x,7)^RemoteSha256.rotr(x,18)^(x>>>3))>>>0,s1=(RemoteSha256.rotr(y,17)^RemoteSha256.rotr(y,19)^(y>>>10))>>>0;w[i]=(w[i-16]+s0+w[i-7]+s1)>>>0}let[a,b1,c,d,e,f,g,h]=this.h;for(let i=0;i<64;i++){const S1=(RemoteSha256.rotr(e,6)^RemoteSha256.rotr(e,11)^RemoteSha256.rotr(e,25))>>>0,ch=((e&f)^((~e)&g))>>>0,t1=(h+S1+ch+RemoteSha256.K[i]+w[i])>>>0,S0=(RemoteSha256.rotr(a,2)^RemoteSha256.rotr(a,13)^RemoteSha256.rotr(a,22))>>>0,maj=((a&b1)^(a&c)^(b1&c))>>>0,t2=(S0+maj)>>>0;h=g;g=f;f=e;e=(d+t1)>>>0;d=c;c=b1;b1=a;a=(t1+t2)>>>0}const v=[a,b1,c,d,e,f,g,h];for(let i=0;i<8;i++)this.h[i]=(this.h[i]+v[i])>>>0}update(data){const u=data instanceof Uint8Array?data:new Uint8Array(data);this.bytes+=u.length;let o=0;if(this.bufLen){const n=Math.min(64-this.bufLen,u.length);this.buf.set(u.subarray(0,n),this.bufLen);this.bufLen+=n;o+=n;if(this.bufLen===64){this._block(this.buf);this.bufLen=0}}while(o+64<=u.length){this._block(u,o);o+=64}if(o<u.length){this.buf.set(u.subarray(o),0);this.bufLen=u.length-o}return this}hex(){const bytes=this.bytes,len=this.bufLen,padLen=len<56?56-len:120-len,pad=new Uint8Array(padLen+8);pad[0]=0x80;const bits=bytes*8,hi=Math.floor(bits/0x100000000),lo=bits>>>0,n=pad.length;pad[n-8]=(hi>>>24)&255;pad[n-7]=(hi>>>16)&255;pad[n-6]=(hi>>>8)&255;pad[n-5]=hi&255;pad[n-4]=(lo>>>24)&255;pad[n-3]=(lo>>>16)&255;pad[n-2]=(lo>>>8)&255;pad[n-1]=lo&255;this.update(pad);return Array.from(this.h,x=>x.toString(16).padStart(8,'0')).join('')}}
            RemoteSha256.K=new Uint32Array([0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]);
            async function remoteSeal(type,payload){const body=payload instanceof Uint8Array?payload:new Uint8Array(payload),plain=new Uint8Array(1+body.byteLength);plain[0]=type;plain.set(body,1);const iv=crypto.getRandomValues(new Uint8Array(12)),cipher=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv},remoteAESKey,plain)),out=new Uint8Array(12+cipher.byteLength);out.set(iv);out.set(cipher,12);return out.buffer}
            async function remoteOpen(data){const u=data instanceof ArrayBuffer?new Uint8Array(data):new Uint8Array(await data.arrayBuffer());if(u.byteLength<29)throw Error('Invalid encrypted acknowledgement');const plain=new Uint8Array(await crypto.subtle.decrypt({name:'AES-GCM',iv:u.subarray(0,12)},remoteAESKey,u.subarray(12)));return{type:plain[0],payload:plain.subarray(1)}}
            async function remoteAPI(path,opt={}){const r=await fetch(REMOTE_API+path,{cache:'no-store',...opt,headers:{'Content-Type':'application/json','X-Shar-Client':'browser-sender-2.2.32',...(opt.headers||{})}});let j={};try{j=await r.json()}catch{}if(!r.ok)throw Error(j.error||`HTTP ${r.status}`);return j}
            function remoteSetStatus(text,state=''){remoteStatus.textContent=text;remoteStatus.dataset.state=state}
            function serverSource(f){return {path:f.name,name:f.name,size:Number(f.size),mime:f.mime||'application/octet-stream',stream:async()=>{const r=await fetch(mediaURL(f),{cache:'no-store'});if(!r.ok||!r.body)throw Error(`Could not read ${f.name}`);return r.body.getReader()}}}
            function fileSources(list){return [...list].map(f=>({path:f.webkitRelativePath||f.name,name:f.name,size:f.size,mime:f.type||'application/octet-stream',stream:async()=>f.stream().getReader()}))}
            function remoteCleanupConnection(){if(remotePollTimer)clearTimeout(remotePollTimer);remotePollTimer=null;try{remoteDC?.close()}catch{}try{remotePC?.close()}catch{}remoteDC=null;remotePC=null;remotePendingCandidates=[];remoteApproval.hidden=true;remoteApprovalRequestId=''}
            async function remoteCancel(){const s=remoteSession;remoteCleanupConnection();remoteSession=null;remoteCompleted=false;remoteAESKey=null;remoteHashes=[];if(s?.id&&s.hostSecret)await remoteAPI('/session/'+encodeURIComponent(s.id),{method:'DELETE',headers:{Authorization:'Bearer '+s.hostSecret}}).catch(()=>{});remoteSetStatus('Share cancelled.');q('#remoteCancel').hidden=true;remoteQR.hidden=true;remoteLinkRow.hidden=true;remoteSecurity.hidden=true;remoteProgress.hidden=true}
            async function remoteSignal(type,payload){if(!remoteSession)throw Error('No remote session');return remoteAPI('/session/'+encodeURIComponent(remoteSession.id)+'/signal',{method:'POST',headers:{Authorization:'Bearer '+remoteSession.hostSecret},body:JSON.stringify({type,payload})})}
            async function remoteApprove(approved){if(!remoteSession||!remoteApprovalRequestId)return;try{await remoteAPI('/session/'+encodeURIComponent(remoteSession.id)+'/approve',{method:'POST',headers:{Authorization:'Bearer '+remoteSession.hostSecret},body:JSON.stringify({requestId:remoteApprovalRequestId,approved:!!approved})});remoteApproval.hidden=true;remoteSetStatus(approved?'Receiver approved — establishing secure connection…':'Receiver rejected',approved?'live':'')}catch(e){remoteSetStatus('Approval failed: '+e.message,'bad')}}
            async function remotePoll(){if(!remoteSession||remoteCompleted)return;try{const j=await remoteAPI('/session/'+encodeURIComponent(remoteSession.id)+'/signal?since='+remoteSignalSeq,{headers:{Authorization:'Bearer '+remoteSession.hostSecret}});for(const m of j.messages){remoteSignalSeq=Math.max(remoteSignalSeq,m.seq);if(m.type==='answer'){await remotePC.setRemoteDescription(m.payload);for(const c of remotePendingCandidates.splice(0))await remotePC.addIceCandidate(c)}else if(m.type==='candidate'&&m.payload){if(remotePC.remoteDescription)await remotePC.addIceCandidate(m.payload);else remotePendingCandidates.push(m.payload)}else if(m.type==='join-request'){remoteApprovalRequestId=m.payload?.requestId||'';remoteApproval.hidden=false;remoteSetStatus('Receiver entered the correct PIN — approve this device')}else if(m.type==='ready'){remoteSetStatus('Approved receiver is connecting…')}}}catch(e){remoteSetStatus('Remote connection error: '+e.message,'bad');return}remotePollTimer=setTimeout(remotePoll,650)}
            async function remoteConnectionLabel(){try{const stats=await remotePC.getStats();let pair=null;stats.forEach(x=>{if(x.type==='transport'&&x.selectedCandidatePairId)pair=stats.get(x.selectedCandidatePairId);if(x.type==='candidate-pair'&&x.selected)pair=x});if(pair){const local=stats.get(pair.localCandidateId),remote=stats.get(pair.remoteCandidateId);if(local?.candidateType==='relay'||remote?.candidateType==='relay')return 'Secure connection via Shar TURN relay';return 'Secure peer-to-peer connection'}}catch{}return 'Secure connection established'}
            async function waitRemoteBuffer(){if(!remoteDC||remoteDC.readyState!=='open')throw Error('Remote data channel closed');if(remoteDC.bufferedAmount<4*1024*1024)return;await new Promise((resolve,reject)=>{remoteDC.bufferedAmountLowThreshold=1024*1024;const done=()=>{remoteDC.removeEventListener('bufferedamountlow',done);resolve()};remoteDC.addEventListener('bufferedamountlow',done,{once:true});setTimeout(()=>{if(remoteDC?.bufferedAmount>=4*1024*1024)reject(Error('Receiver is not consuming data'))},30000)})}
            async function remoteSendControl(obj){await waitRemoteBuffer();remoteDC.send(await remoteSeal(1,new TextEncoder().encode(JSON.stringify(obj))))}
            async function remoteSendBinary(chunk,hasher){const u=chunk instanceof Uint8Array?chunk:new Uint8Array(chunk);for(let o=0;o<u.byteLength;o+=49152){const part=u.subarray(o,Math.min(o+49152,u.byteLength));hasher.update(part);await waitRemoteBuffer();remoteDC.send(await remoteSeal(2,part));remoteSent+=part.byteLength;remoteProgress.value=remoteSent}}
            function remoteReceiverAck(timeout=15000){return new Promise(resolve=>{let done=false;const finish=value=>{if(done)return;done=true;remoteAckResolve=null;resolve(value)};remoteAckResolve=ok=>finish(ok===true);setTimeout(()=>finish(false),timeout)})}
            async function remoteServerCompletion(){for(let i=0;i<8&&remoteSession;i++){try{const s=await remoteAPI('/session/'+encodeURIComponent(remoteSession.id));if(s.completed)return true}catch{}await new Promise(r=>setTimeout(r,500))}return false}
            async function remoteSendFiles(){remoteSent=0;remoteHashes=[];remoteProgress.hidden=false;remoteProgress.max=remoteSources.reduce((n,x)=>n+x.size,0)||1;remoteProgress.value=0;await remoteSendControl({t:'manifest',files:remoteSources.map(x=>({path:x.path,name:x.name,size:x.size,mime:x.mime}))});for(let i=0;i<remoteSources.length;i++){const s=remoteSources[i],hasher=new RemoteSha256;remoteSetStatus(`Encrypting ${i+1}/${remoteSources.length}: ${s.path}`,'live');await remoteSendControl({t:'file-start',i,path:s.path,name:s.name,size:s.size,mime:s.mime});const reader=await s.stream();while(true){const {done,value}=await reader.read();if(done)break;if(value)await remoteSendBinary(value,hasher)}const hash=hasher.hex();remoteHashes.push(hash);await remoteSendControl({t:'file-end',i,sha256:hash})}const ack=remoteReceiverAck();await remoteSendControl({t:'complete'});remoteSetStatus('Finalizing encrypted transfer…','live');const verified=await ack,serverDone=verified?true:await remoteServerCompletion();remoteCompleted=true;remoteSetStatus(verified?'Transfer complete ✓':serverDone?'Receiver reported completion — secure ACK unavailable':'Transfer sent — receiver confirmation unavailable',verified?'live':'');remoteProgress.value=remoteProgress.max;q('#remoteCancel').textContent='Close'}
            async function remoteStart(sources){if(!window.RTCPeerConnection||!crypto?.subtle){remoteShare.showModal();remoteSetStatus('Secure WebRTC/Web Crypto is unavailable in this browser.','bad');return}if(!sources.length)return;await remoteCancel().catch(()=>{});remoteSources=sources;remoteCompleted=false;remoteSignalSeq=0;remoteSummary.textContent=`${sources.length} item${sources.length===1?'':'s'} · ${bytes(sources.reduce((n,x)=>n+x.size,0))}`;remoteSetStatus('Creating end-to-end encrypted share…');remoteShare.showModal();try{const pin=remoteRandomPin(),salt=crypto.getRandomValues(new Uint8Array(16)),verifier=await remotePinVerifier(pin,salt),rawKey=crypto.getRandomValues(new Uint8Array(32));remoteAESKey=await crypto.subtle.importKey('raw',rawKey,{name:'AES-GCM'},false,['encrypt','decrypt']);remoteSession=await remoteAPI('/session',{method:'POST',body:JSON.stringify({files:sources.map((x,i)=>({path:`Encrypted item ${i+1}`,size:x.size,mime:'application/octet-stream'})),ttlSeconds:1800,oneTime:true,pinVerifier:verifier,pinSalt:remoteB64url(salt),pinIterations:REMOTE_PIN_ITERATIONS,approvalRequired:true,e2ee:true,privateMetadata:true})});remoteLink.value=remoteSession.receiverBase+'#share='+encodeURIComponent(remoteSession.id)+'&key='+encodeURIComponent(remoteB64url(rawKey));remotePIN.textContent=pin.slice(0,3)+' '+pin.slice(3);remoteSecurity.hidden=false;remoteLinkRow.hidden=false;remoteQR.hidden=true;q('#remoteCancel').hidden=false;q('#remoteCancel').textContent='Cancel share';q('#remoteSystemShare').hidden=!navigator.share;remotePC=new RTCPeerConnection({iceServers:remoteSession.iceServers});remoteDC=remotePC.createDataChannel('shar-file',{ordered:true});remoteDC.binaryType='arraybuffer';remoteDC.onopen=async()=>{remoteSetStatus(await remoteConnectionLabel(),'live');remoteSendFiles().catch(e=>{if(!remoteCompleted)remoteSetStatus('Transfer failed: '+e.message,'bad')})};remoteDC.onmessage=e=>{if(remoteCompleted||typeof e.data==='string')return;(async()=>{try{const p=await remoteOpen(e.data);if(p.type!==1)return;const m=JSON.parse(new TextDecoder().decode(p.payload));if(m.t==='receiver-complete'){const ok=m.verified===true&&Array.isArray(m.hashes)&&JSON.stringify(m.hashes)===JSON.stringify(remoteHashes);remoteSetStatus(ok?'Receiver decrypted and SHA-256 verified the transfer ✓':'Receiver completion could not be cryptographically verified',ok?'live':'');remoteAckResolve?.(ok)}}catch{remoteSetStatus('Secure receiver acknowledgement failed.','bad')}})()};remoteDC.onerror=()=>{if(!remoteCompleted)remoteSetStatus('Encrypted WebRTC data channel error.','bad')};remotePC.onicecandidate=e=>{if(e.candidate)remoteSignal('candidate',e.candidate.toJSON()).catch(()=>{})};remotePC.onconnectionstatechange=async()=>{if(remoteCompleted)return;if(remotePC.connectionState==='connected')remoteSetStatus(await remoteConnectionLabel(),'live');else if(remotePC.connectionState==='failed')remoteSetStatus('Connection failed','bad');else if(remotePC.connectionState==='disconnected')remoteSetStatus('Connection interrupted')};const offer=await remotePC.createOffer();await remotePC.setLocalDescription(offer);await remoteSignal('offer',remotePC.localDescription);remoteSetStatus('Waiting for receiver PIN…');remotePoll()}catch(e){remoteSetStatus('Could not create secure share: '+e.message,'bad');remoteCleanupConnection()}}
            setAction(q('#remoteClose'),'close','Close','Close');q('#remoteClose').onclick=()=>{if(remoteCompleted){remoteCleanupConnection();remoteShare.close()}else if(confirm('Cancel this remote share?'))remoteCancel().finally(()=>remoteShare.close())};q('#remoteCancel').onclick=()=>{if(remoteCompleted){remoteCleanupConnection();remoteShare.close()}else remoteCancel()};q('#remoteCopy').onclick=async()=>{try{await navigator.clipboard.writeText(remoteLink.value);q('#remoteCopy').textContent='Copied ✓';setTimeout(()=>q('#remoteCopy').textContent='Copy',900)}catch{remoteLink.select();document.execCommand('copy')}};q('#remoteCopyPIN').onclick=async()=>{const value=remotePIN.textContent.replace(/\s/g,'');try{await navigator.clipboard.writeText(value);q('#remoteCopyPIN').textContent='Copied ✓';setTimeout(()=>q('#remoteCopyPIN').textContent='Copy PIN',900)}catch{}};q('#remoteApprove').onclick=()=>remoteApprove(true);q('#remoteReject').onclick=()=>remoteApprove(false);q('#remoteSystemShare').onclick=()=>navigator.share?.({title:'Shar secure remote share',url:remoteLink.value});q('#remoteChooseFiles').onclick=()=>remoteFilePicker.click();q('#remoteChooseFolder').onclick=()=>remoteFolderPicker.click();remoteFilePicker.onchange=()=>{const x=fileSources(remoteFilePicker.files);remoteFilePicker.value='';remoteStart(x)};remoteFolderPicker.onchange=()=>{const x=fileSources(remoteFolderPicker.files);remoteFolderPicker.value='';remoteStart(x)};q('#remoteLocalButton').onclick=()=>{remoteSummary.textContent='Choose files or a folder from this device, or use Remote on a Shar file card.';remoteSetStatus('Ready.');remoteQR.hidden=true;remoteLinkRow.hidden=true;remoteSecurity.hidden=true;remoteApproval.hidden=true;remoteProgress.hidden=true;q('#remoteCancel').hidden=true;remoteShare.showModal()};remoteShare.addEventListener('cancel',e=>{e.preventDefault();q('#remoteClose').click()});
            const remoteParam=new URLSearchParams(location.search).get('remote');
            function renderFilters(){filtersEl.replaceChildren();for(const [kind,label] of filterDefs){const b=document.createElement('button');b.className='filter'+(currentFilter===kind?' active':'');b.textContent=label;b.onclick=()=>{currentFilter=kind;localStorage.setItem('lws-filter',kind);renderFilters();renderFiles()};filtersEl.append(b)}}
            function renderFiles(){const visible=visibleFiles();filesEl.innerHTML='';countEl.textContent=currentFilter==='all'?`${visible.length} files`:`${visible.length} / ${currentFiles.length}`;if(!visible.length){const e=document.createElement('div');e.className='empty';e.textContent='No files in this category.';filesEl.append(e);return}for(const f of visible){const card=document.createElement('article');card.className='file';const p=document.createElement('button');p.className='preview';p.type='button';p.append(previewElement(f));p.onclick=()=>openPreview(f);const body=document.createElement('div');body.className='body';const n=document.createElement('div');n.className='name';n.textContent=f.title||f.name;n.onclick=()=>openPreview(f);body.append(n);if(f.kind==='audio'&&f.artist){const am=document.createElement('div');am.className='audio-meta';am.textContent=f.artist;body.append(am)}const m=document.createElement('div');m.className='meta';m.textContent=`${f.kind.toUpperCase()} • ${f.mime} • ${bytes(f.size)}`;body.append(m);if(f.kind==='audio')body.append(audioMini(f));const ac=document.createElement('div');ac.className='actions';const view=document.createElement('button');setAction(view,'preview','Preview','View');view.onclick=()=>openPreview(f);const d=document.createElement('a');d.className='btn';setAction(d,'download','Download','Down');d.href=downloadURL(f);d.download=f.name;const remote=document.createElement('button');setAction(remote,'share','Remote','Remote');remote.title='Share over the Internet with WebRTC';remote.onclick=()=>remoteStart([serverSource(f)]);const del=document.createElement('button');del.className='danger';setAction(del,'delete','Delete','Del');del.onclick=()=>removeFile(f).catch(showError);ac.append(view,d,remote,del);body.append(ac);card.append(p,body);filesEl.append(card)}}
            async function removeFile(f,fromViewer=false){if(!confirm(`Delete ${f.name}?`))return;const r=await fetch('/files/'+encodeURIComponent(f.name),{method:'DELETE'});if(!r.ok)throw Error(await r.text());const old=viewerIndex;await refresh();if(fromViewer){viewerFiles=visibleFiles();if(!viewerFiles.length)closePreview();else showViewer(Math.min(old,viewerFiles.length-1))}}
            async function refresh(){const r=await fetch('/api/files',{cache:'no-store'});if(!r.ok)throw Error(await r.text());currentFiles=await r.json();renderFilters();renderFiles()}
            async function uploadFile(file,index,total){statusEl.textContent=`Uploading ${index+1}/${total}: ${file.name}`;progressEl.hidden=false;progressEl.value=index/total;const r=await fetch('/upload?filename='+encodeURIComponent(file.name),{method:'POST',headers:{'Content-Type':file.type||'application/octet-stream'},body:file});if(!r.ok)throw Error(await r.text());progressEl.value=(index+1)/total}
            async function uploadFiles(list){const a=[...list].filter(Boolean);if(!a.length)return;try{for(let i=0;i<a.length;i++)await uploadFile(a[i],i,a.length);statusEl.textContent=`Uploaded ${a.length} file${a.length===1?'':'s'}.`;pickerEl.value='';await refresh()}catch(e){showError(e)}finally{setTimeout(()=>progressEl.hidden=true,900)}} function showError(e){statusEl.textContent='Error: '+(e?.message||e)}
            currentFilter=localStorage.getItem('lws-filter')||'all';if(!filterDefs.some(x=>x[0]===currentFilter))currentFilter='all';dropEl.onclick=()=>pickerEl.click();dropEl.onkeydown=e=>{if(e.key==='Enter'||e.key===' ')pickerEl.click()};pickerEl.onchange=()=>uploadFiles(pickerEl.files);for(const e of ['dragenter','dragover'])document.addEventListener(e,x=>{x.preventDefault();dropEl.classList.add('drag')});for(const e of ['dragleave','drop'])document.addEventListener(e,x=>{x.preventDefault();dropEl.classList.remove('drag')});document.addEventListener('drop',e=>uploadFiles(e.dataTransfer.files));refresh().then(()=>{if(remoteParam){const f=currentFiles.find(x=>x.name===remoteParam);if(f)remoteStart([serverSource(f)]);else showError(Error('Remote-share file was not found: '+remoteParam))}}).catch(e=>{filesEl.textContent='Could not load files.';showError(e)});
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
        case "glb", "gltf", "usd", "usda", "usdc", "usdz", "obj", "stl", "ply", "abc", "dae", "fbx", "3ds", "3mf", "blend", "step", "stp", "iges", "igs":
            return "threeD"
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
        case "glb": return "model/gltf-binary"
        case "gltf": return "model/gltf+json"
        case "usd", "usda", "usdc": return "model/vnd.usd"
        case "usdz": return "model/vnd.usdz+zip"
        case "obj": return "model/obj"
        case "stl": return "model/stl"
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
