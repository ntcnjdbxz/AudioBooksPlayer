import Foundation
import Network
import Darwin

final class WiFiTransferServer: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var address = ""
    @Published private(set) var status = "Сервер не запущен"
    @Published private(set) var uploadedCount = 0
    @Published private(set) var lastUploadedPath = ""
    @Published private(set) var errorMessage: String?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "AudioBooks.WiFiTransfer")
    private let fm = FileManager.default
    private let maxHeaderSize = 64 * 1024
    private let receiveChunkSize = 1024 * 1024

    deinit { stop() }

    func start() {
        if isRunning { return }
        errorMessage = nil
        uploadedCount = 0
        lastUploadedPath = ""
        status = "Запуск сервера…"

        do {
            let listener = try NWListener(using: .tcp)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        guard let port = listener.port else {
                            self.status = "Не удалось определить порт"
                            return
                        }
                        let host = Self.localIPv4Address() ?? "IP-адрес iPhone"
                        self.address = "http://\(host):\(port.rawValue)"
                        self.status = "Откройте адрес на компьютере"
                        self.isRunning = true
                    case .failed(let error):
                        self.isRunning = false
                        self.status = "Ошибка сервера"
                        self.errorMessage = error.localizedDescription
                        listener.cancel()
                        self.listener = nil
                    case .cancelled:
                        self.isRunning = false
                        self.status = "Сервер остановлен"
                        self.listener = nil
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        } catch {
            isRunning = false
            status = "Ошибка сервера"
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
            self.address = ""
            self.status = "Сервер остановлен"
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.receiveHeaders(on: connection, buffer: Data())
            case .failed(let error):
                print("Wi-Fi connection failed: \(error)")
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveHeaders(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxHeaderSize) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if let error {
                print("Wi-Fi header receive error: \(error)")
                connection.cancel()
                return
            }

            var combined = buffer
            if let data { combined.append(data) }

            if let range = combined.range(of: Data([13, 10, 13, 10])) {
                let headerData = combined.subdata(in: 0..<range.lowerBound)
                let bodyStart = range.upperBound
                guard let header = String(data: headerData, encoding: .utf8),
                      let request = self.parseRequest(header) else {
                    self.sendResponse(connection, status: 400, body: "Bad Request")
                    return
                }

                if request.method == "GET" {
                    self.sendHTML(connection)
                    return
                }

                guard request.method == "POST", request.path == "/upload" else {
                    self.sendResponse(connection, status: 404, body: "Not Found")
                    return
                }

                guard let lengthString = request.headers["content-length"],
                      let length = Int64(lengthString), length >= 0 else {
                    // Browser uploads of File/Blob should have Content-Length.
                    // Return a clear error instead of leaving the connection hanging.
                    self.sendResponse(connection, status: 411, body: "Content-Length required")
                    return
                }

                guard let relativePath = self.sanitizePath(request.queryItems["path"] ?? "") else {
                    self.sendResponse(connection, status: 400, body: "Invalid path")
                    return
                }

                let initial = combined.subdata(in: bodyStart..<combined.count)
                self.receiveUpload(
                    connection: connection,
                    relativePath: relativePath,
                    totalBytes: length,
                    initialBody: initial
                )
                return
            }

            if combined.count > self.maxHeaderSize || isComplete {
                self.sendResponse(connection, status: 400, body: "Invalid request")
                return
            }

            self.receiveHeaders(on: connection, buffer: combined)
        }
    }

    private func receiveUpload(connection: NWConnection, relativePath: String, totalBytes: Int64, initialBody: Data) {
        let root = booksDirectory()
        let destination = root.appendingPathComponent(relativePath, isDirectory: false)

        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            fm.createFile(atPath: destination.path, contents: nil)
        } catch {
            sendResponse(connection, status: 500, body: "Cannot create file")
            return
        }

        guard let handle = try? FileHandle(forWritingTo: destination) else {
            sendResponse(connection, status: 500, body: "Cannot open file")
            return
        }

        let initialCount = Int(min(Int64(initialBody.count), totalBytes))
        do {
            if initialCount > 0 {
                try handle.write(contentsOf: initialBody.prefix(initialCount))
            }
        } catch {
            try? handle.close()
            connection.cancel()
            return
        }

        if initialCount > 0 {
            publishProgress(path: relativePath, received: Int64(initialCount), total: totalBytes)
        }

        let received = Int64(initialCount)
        if received >= totalBytes {
            finishUpload(handle: handle, connection: connection, relativePath: relativePath)
            return
        }

        receiveUploadChunks(
            connection: connection,
            handle: handle,
            relativePath: relativePath,
            totalBytes: totalBytes,
            received: received
        )
    }

    private func receiveUploadChunks(connection: NWConnection, handle: FileHandle, relativePath: String, totalBytes: Int64, received: Int64) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: receiveChunkSize) { [weak self] data, _, isComplete, error in
            guard let self else {
                try? handle.close()
                connection.cancel()
                return
            }

            if let error {
                try? handle.close()
                connection.cancel()
                print("Wi-Fi upload error: \(error)")
                return
            }

            guard let data, !data.isEmpty else {
                if isComplete {
                    try? handle.close()
                    self.sendResponse(connection, status: 400, body: "Incomplete upload")
                } else {
                    self.receiveUploadChunks(connection: connection, handle: handle, relativePath: relativePath, totalBytes: totalBytes, received: received)
                }
                return
            }

            let remaining = totalBytes - received
            let count = Int(min(Int64(data.count), remaining))
            let chunk = data.prefix(count)

            do {
                if count > 0 {
                    try handle.write(contentsOf: chunk)
                }
            } catch {
                try? handle.close()
                self.sendResponse(connection, status: 500, body: "Write error")
                return
            }

            let newReceived = received + Int64(count)
            self.publishProgress(path: relativePath, received: newReceived, total: totalBytes)

            if newReceived >= totalBytes {
                self.finishUpload(handle: handle, connection: connection, relativePath: relativePath)
            } else if isComplete {
                try? handle.close()
                self.sendResponse(connection, status: 400, body: "Incomplete upload")
            } else {
                self.receiveUploadChunks(connection: connection, handle: handle, relativePath: relativePath, totalBytes: totalBytes, received: newReceived)
            }
        }
    }

    private func finishUpload(handle: FileHandle, connection: NWConnection, relativePath: String) {
        try? handle.close()
        uploadFinished(relativePath: relativePath)
        sendResponse(connection, status: 200, body: "OK")
    }

    private func publishProgress(path: String, received: Int64, total: Int64) {
        DispatchQueue.main.async {
            let mb = Double(received) / 1_048_576.0
            let totalMB = Double(total) / 1_048_576.0
            self.status = String(format: "Передача: %.1f / %.1f MB — %@", mb, totalMB, path)
        }
    }

    private func uploadFinished(relativePath: String) {
        DispatchQueue.main.async {
            self.uploadedCount += 1
            self.lastUploadedPath = relativePath
            self.status = "Загружено файлов: \(self.uploadedCount)"
        }
    }

    private struct Request {
        let method: String
        let path: String
        let queryItems: [String: String]
        let headers: [String: String]
    }

    private func parseRequest(_ header: String) -> Request? {
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }

        let target = parts[1]
        guard let components = URLComponents(string: "http://localhost\(target)") else { return nil }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { query[item.name] = value }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        return Request(method: parts[0].uppercased(), path: components.path, queryItems: query, headers: headers)
    }

    private func sendHTML(_ connection: NWConnection) {
        let html = """
        <!doctype html>
        <html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta charset=\"utf-8\"><title>AudioBooks</title>
        <style>
        body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;max-width:760px;margin:40px auto;padding:0 20px}
        button{font-size:18px;padding:12px 18px;border:0;border-radius:10px;background:#007aff;color:white}
        button:disabled{opacity:.5}#status{margin-top:20px;white-space:pre-wrap}.hint{color:#666}
        progress{width:100%;height:24px;margin-top:12px}
        </style></head>
        <body><h1>📚 AudioBooks</h1>
        <p class=\"hint\">Выберите папку аудиокниги. Все файлы и вложенные папки будут сохранены в Books.</p>
        <input id=\"picker\" type=\"file\" webkitdirectory directory multiple>
        <p><button id=\"uploadButton\" onclick=\"upload()\">Загрузить папку</button></p>
        <progress id=\"progress\" value=\"0\" max=\"100\" hidden></progress>
        <div id=\"status\">Готово к загрузке.</div>
        <script>
        function fmt(bytes){
          if(bytes<1024*1024) return (bytes/1024).toFixed(0)+' KB';
          return (bytes/1024/1024).toFixed(1)+' MB';
        }
        function uploadOne(file, rel, index, total){
          return new Promise((resolve,reject)=>{
            const xhr=new XMLHttpRequest();
            xhr.open('POST','/upload?path='+encodeURIComponent(rel),true);
            xhr.setRequestHeader('Content-Type','application/octet-stream');
            xhr.upload.onprogress=(e)=>{
              if(e.lengthComputable){
                const overall=((index + e.loaded/e.total)/total)*100;
                document.getElementById('progress').value=overall;
                document.getElementById('status').textContent='Загрузка '+(index+1)+' / '+total+'\\n'+rel+'\\n'+fmt(e.loaded)+' / '+fmt(e.total)+' ('+overall.toFixed(1)+'%)';
              }
            };
            xhr.onload=()=>{
              if(xhr.status>=200 && xhr.status<300) resolve();
              else reject(new Error('HTTP '+xhr.status));
            };
            xhr.onerror=()=>reject(new Error('Сетевое соединение прервано'));
            xhr.ontimeout=()=>reject(new Error('Тайм-аут'));
            xhr.timeout=0;
            xhr.send(file);
          });
        }
        async function upload(){
          const files=[...document.getElementById('picker').files];
          const status=document.getElementById('status');
          const button=document.getElementById('uploadButton');
          const progress=document.getElementById('progress');
          if(!files.length){status.textContent='Сначала выберите папку.';return;}
          button.disabled=true; progress.hidden=false; progress.value=0;
          try{
            for(let i=0;i<files.length;i++){
              const file=files[i];
              const rel=file.webkitRelativePath || file.name;
              await uploadOne(file,rel,i,files.length);
            }
            progress.value=100;
            status.textContent='Готово! Загружено файлов: '+files.length+'. Можно закрыть страницу.';
          }catch(e){
            status.textContent='Ошибка передачи: '+e.message;
          }finally{
            button.disabled=false;
          }
        }
        </script></body></html>
        """
        sendHTTP(connection, status: 200, contentType: "text/html; charset=utf-8", body: Data(html.utf8))
    }

    private func sendResponse(_ connection: NWConnection, status: Int, body: String) {
        sendHTTP(connection, status: status, contentType: "text/plain; charset=utf-8", body: Data(body.utf8))
    }

    private func sendHTTP(_ connection: NWConnection, status: Int, contentType: String, body: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 411: reason = "Length Required"
        case 500: reason = "Internal Server Error"
        default: reason = "Error"
        }
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sanitizePath(_ raw: String) -> String? {
        var path = raw.replacingOccurrences(of: "\\\\", with: "/")
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return nil }
        guard parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains(":") }) else { return nil }
        return parts.joined(separator: "/")
    }

    private func booksDirectory() -> URL {
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let books = documents.appendingPathComponent("Books", isDirectory: true)
        try? fm.createDirectory(at: books, withIntermediateDirectories: true)
        return books
    }

    private static func localIPv4Address() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name == "en1" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var addrCopy = addr.pointee
            if getnameinfo(&addrCopy, socklen_t(addrCopy.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: host)
                if value != "127.0.0.1" {
                    address = value
                    break
                }
            }
        }
        return address
    }
}
