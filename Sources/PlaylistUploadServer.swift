import Darwin
import Foundation
import Network

final class PlaylistUploadServer {
    typealias Completion = (Result<String, Error>) -> Void

    private let queue = DispatchQueue(label: "vibetv.playlist-upload")
    private let code = String(Int.random(in: 100000...999999))
    private let listener: NWListener
    private var connections: [UUID: NWConnection] = [:]
    private var acceptingUpload = true
    private var invalidAttempts = 0
    private let upload: (Data, @escaping Completion) -> Void

    init(
        address: @escaping (String) -> Void,
        upload: @escaping (Data, @escaping Completion) -> Void
    ) throws {
        self.upload = upload
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port, let host = Self.localIPv4() else {
                    address("Apple TV needs a local IPv4 address to receive a file.")
                    return
                }
                address("http://\(host):\(port.rawValue)   Code \(self.code)")
            case .failed:
                address("Local upload could not start. Check Local Network access.")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.close(id) }
        readHeader(id, buffer: Data())
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }

    private func readHeader(_ id: UUID, buffer: Data) {
        connections[id]?.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] chunk, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var data = buffer
            if let chunk { data.append(chunk) }
            if let end = data.range(of: Data([13, 10, 13, 10])) {
                guard end.lowerBound <= 8192,
                      let header = String(data: data[..<end.lowerBound], encoding: .utf8) else {
                    self.respond(id, "400 Bad Request", "Invalid request.")
                    return
                }
                self.handleHeader(id, header: header, body: Data(data[end.upperBound...]))
            } else if data.count > 8192 || complete || error != nil {
                self.close(id)
            } else {
                self.readHeader(id, buffer: data)
            }
        }
    }

    private func handleHeader(_ id: UUID, header: String, body: Data) {
        let lines = header.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        guard request.count == 3 else {
            respond(id, "400 Bad Request", "Invalid request.")
            return
        }
        if request[0] == "GET", request[1] == "/" {
            respond(id, "200 OK", Self.form, type: "text/html; charset=utf-8")
            return
        }
        guard request[0] == "POST", request[1] == "/upload" else {
            respond(id, "404 Not Found", "Unknown path.")
            return
        }
        guard acceptingUpload, invalidAttempts < 10 else {
            respond(id, "403 Forbidden", "Reopen the import screen on Apple TV for a new code.")
            return
        }

        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                fields[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        guard fields["x-upload-code"] == code else {
            invalidAttempts += 1
            respond(id, "403 Forbidden", "Check the code shown on Apple TV.")
            return
        }
        guard fields["transfer-encoding"] == nil,
              let length = fields["content-length"].flatMap(Int.init),
              length > 0,
              length <= M3UParser.maximumBytes else {
            respond(id, "413 Content Too Large", "Choose a nonempty playlist up to 8 MB.")
            return
        }
        let filename = fields["x-playlist-name"]?.removingPercentEncoding ?? "Imported.m3u"
        let extensionName = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard ["m3u", "m3u8"].contains(extensionName) else {
            respond(id, "400 Bad Request", "Choose an .m3u or .m3u8 file.")
            return
        }
        readBody(id, buffer: body, expected: length)
    }

    private func readBody(_ id: UUID, buffer: Data, expected: Int) {
        if buffer.count >= expected {
            guard acceptingUpload else {
                respond(id, "409 Conflict", "This upload code has already been used.")
                return
            }
            upload(Data(buffer.prefix(expected))) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    switch result {
                    case .success(let message):
                        self.acceptingUpload = false
                        self.respond(id, "200 OK", message)
                    case .failure(let error):
                        self.respond(id, "422 Unprocessable Content", error.localizedDescription)
                    }
                }
            }
            return
        }
        connections[id]?.receive(
            minimumIncompleteLength: 1,
            maximumLength: min(65_536, expected - buffer.count)
        ) { [weak self] chunk, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var data = buffer
            if let chunk { data.append(chunk) }
            if data.count == expected || (!complete && error == nil && chunk?.isEmpty == false) {
                self.readBody(id, buffer: data, expected: expected)
            } else {
                self.close(id)
            }
        }
    }

    private func respond(
        _ id: UUID,
        _ status: String,
        _ body: String,
        type: String = "text/plain; charset=utf-8"
    ) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connections[id]?.send(content: Data((header + body).utf8), completion: .contentProcessed {
            [weak self] _ in self?.close(id)
        })
    }

    private static func localIPv4() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(first) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            guard let socket = item.ifa_addr,
                  socket.pointee.sa_family == UInt8(AF_INET),
                  item.ifa_flags & UInt32(IFF_UP) != 0,
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else {
                continue
            }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                socket,
                socklen_t(socket.pointee.sa_len),
                &name,
                socklen_t(name.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if status == 0 { return String(cString: name) }
        }
        return nil
    }

    private static let form = """
    <!doctype html><html lang="en"><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Vibe TV playlist upload</title>
    <style>body{font:18px system-ui;max-width:32rem;margin:3rem auto;padding:0 1rem}label{display:block;margin:1rem 0}input,button{font:inherit}</style>
    <h1>Send playlist to Vibe TV</h1><form id="form">
    <label>Playlist <input id="file" type="file" accept=".m3u,.m3u8" required></label>
    <label>Apple TV code <input id="code" inputmode="numeric" pattern="[0-9]{6}" required></label>
    <button>Send to Apple TV</button></form><p id="result" role="status"></p>
    <script>
    const form=document.querySelector('#form'),result=document.querySelector('#result'),button=form.querySelector('button');
    form.addEventListener('submit',async event=>{
      event.preventDefault();
      const file=document.querySelector('#file').files[0];
      if(!file||!file.size||file.size>8388608){result.textContent='Choose a nonempty playlist up to 8 MB.';return}
      button.disabled=true;result.textContent='Sending and saving…';
      try{
        const response=await fetch('/upload',{method:'POST',body:file,headers:{
          'X-Upload-Code':document.querySelector('#code').value,
          'X-Playlist-Name':encodeURIComponent(file.name)
        }});
        result.textContent=await response.text()
      }catch{result.textContent='Could not reach Apple TV.'}
      finally{button.disabled=false}
    });
    </script></html>
    """
}

