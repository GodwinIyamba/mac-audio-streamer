import CryptoKit
import Foundation
import Network

// MARK: - Minimal RFC 6455 Framing

private enum WSCodec {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func acceptKey(for clientKey: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((clientKey + guid).utf8))
        return Data(digest).base64EncodedString()
    }

    static func encodeFrame(opcode: UInt8, payload: Data) -> Data {
        let len = payload.count
        var out = Data()
        out.reserveCapacity(len + 10)
        out.append(0x80 | (opcode & 0x0F))

        if len < 126 {
            out.append(UInt8(len))
        } else if len < 65_536 {
            out.append(126)
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
        } else {
            out.append(127)
            let len64 = UInt64(len)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((len64 >> shift) & 0xFF))
            }
        }

        out.append(payload)
        return out
    }
}

// MARK: - WebSocket Client Session

private final class WSClientConnection {
    let id = UUID()
    let connection: NWConnection
    let remoteDescription: String

    private var recvBuffer = Data()
    private var pendingBinaryWrites = 0
    private var isClosed = false

    var onTextMessage: ((String) -> Void)?
    var onClose: (() -> Void)?

    init(connection: NWConnection, remoteDescription: String, initialData: Data) {
        self.connection = connection
        self.remoteDescription = remoteDescription
        if !initialData.isEmpty {
            self.recvBuffer.append(initialData)
        }
    }

    func startReading() {
        processBuffer()
        readNextChunk()
    }

    func sendJSON(_ dict: [String: Any]) {
        guard !isClosed,
              let data = try? JSONSerialization.data(withJSONObject: dict) else {
            return
        }
        let frame = WSCodec.encodeFrame(opcode: 0x1, payload: data)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.close(code: nil)
            }
        })
    }

    func sendBinaryFrame(_ preEncodedFrame: Data) {
        guard !isClosed else { return }
        // Drop frame for slow Wi-Fi clients rather than building latency backlog
        if pendingBinaryWrites >= 4 { return }
        pendingBinaryWrites += 1
        connection.send(content: preEncodedFrame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingBinaryWrites = max(0, self.pendingBinaryWrites - 1)
            if error != nil {
                self.close(code: nil)
            }
        })
    }

    func close(code: UInt16? = 1000) {
        guard !isClosed else { return }
        isClosed = true

        if let code {
            var payload = Data(count: 2)
            payload[0] = UInt8((code >> 8) & 0xFF)
            payload[1] = UInt8(code & 0xFF)
            let frame = WSCodec.encodeFrame(opcode: 0x8, payload: payload)
            connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
        } else {
            connection.cancel()
        }

        onClose?()
    }

    private func readNextChunk() {
        guard !isClosed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                self.recvBuffer.append(data)
                self.processBuffer()
            }
            if error != nil || isComplete {
                self.close(code: nil)
                return
            }
            self.readNextChunk()
        }
    }

    private func processBuffer() {
        while recvBuffer.count >= 2 {
            let b0 = recvBuffer[recvBuffer.startIndex]
            let b1 = recvBuffer[recvBuffer.startIndex + 1]
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            var payloadLen = Int(b1 & 0x7F)
            var offset = 2

            if payloadLen == 126 {
                guard recvBuffer.count >= 4 else { return }
                let hi = Int(recvBuffer[recvBuffer.startIndex + 2])
                let lo = Int(recvBuffer[recvBuffer.startIndex + 3])
                payloadLen = (hi << 8) | lo
                offset = 4
            } else if payloadLen == 127 {
                guard recvBuffer.count >= 10 else { return }
                var len64: UInt64 = 0
                for i in 0..<8 {
                    len64 = (len64 << 8) | UInt64(recvBuffer[recvBuffer.startIndex + 2 + i])
                }
                guard len64 < 10_000_000 else {
                    close(code: 1009)
                    return
                }
                payloadLen = Int(len64)
                offset = 10
            }

            let maskLen = masked ? 4 : 0
            let totalNeeded = offset + maskLen + payloadLen
            guard recvBuffer.count >= totalNeeded else { return }

            var maskKey: [UInt8] = []
            if masked {
                let start = recvBuffer.startIndex + offset
                maskKey = Array(recvBuffer[start..<(start + 4)])
                offset += 4
            }

            let payloadStart = recvBuffer.startIndex + offset
            var payload = Data(recvBuffer[payloadStart..<(payloadStart + payloadLen)])
            recvBuffer.removeFirst(totalNeeded)

            if masked && maskKey.count == 4 {
                for i in 0..<payload.count {
                    payload[i] ^= maskKey[i & 3]
                }
            }

            switch opcode {
            case 0x8: // Close
                close(code: 1000)
                return
            case 0x9: // Ping
                let pong = WSCodec.encodeFrame(opcode: 0xA, payload: payload)
                connection.send(content: pong, completion: .contentProcessed { _ in })
            case 0x1: // Text
                if let text = String(data: payload, encoding: .utf8) {
                    onTextMessage?(text)
                }
            default:
                break
            }
        }
    }
}

// MARK: - HTTP + WebSocket LAN Server

final class LANAudioServer {
    private let queue = DispatchQueue(label: "com.audiostreamer.server", qos: .userInitiated)
    private let publicDir: URL

    private var listener: NWListener?
    private var clients: [UUID: WSClientConnection] = [:]
    private var stopCaptureWorkItem: DispatchWorkItem?

    private var port: UInt16 = 8765
    private var seq: UInt32 = 0
    private var formatConfig = AudioFormatConfig()
    private var muteMac: Bool = true
    private var capturing: Bool = false
    private var lastError: String?
    private var lastWarning: String?
    private var currentSource: AudioSourceInfo?

    var onListenerCountChanged: ((Int) -> Void)?
    var onNeedStartCapture: ((Bool) -> Void)?
    var onNeedStopCapture: (() -> Void)?
    var onClientSetMuteMac: ((Bool) -> Void)?
    var onServerStateChanged: ((Bool, String?) -> Void)?

    private static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png"
    ]

    init(publicDir: URL) {
        self.publicDir = publicDir.standardizedFileURL
    }

    func start(port: UInt16, muteMac: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()
            self.port = port
            self.muteMac = muteMac

            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                self.onServerStateChanged?(false, "Invalid port \(port).")
                return
            }

            do {
                let listener = try NWListener(using: params, on: nwPort)
                self.listener = listener

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.onServerStateChanged?(true, nil)
                    case .failed(let err):
                        self.onServerStateChanged?(false, "Server failed: \(err.localizedDescription)")
                    case .cancelled:
                        self.onServerStateChanged?(false, nil)
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] conn in
                    self?.handleNewConnection(conn)
                }

                listener.start(queue: self.queue)
            } catch {
                self.onServerStateChanged?(false, "Could not bind port \(port): \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    func stopSynchronously() {
        queue.sync {
            self.stopLocked()
        }
    }

    func updateCaptureReady(format: AudioFormatConfig, mutedMac: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.formatConfig = format
            self.muteMac = mutedMac
            self.capturing = true
            self.lastError = nil
            self.lastWarning = nil
            self.broadcastJSONLocked(self.configPayloadLocked())
        }
    }

    func updateMuteState(_ mutedMac: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.muteMac = mutedMac
            self.broadcastJSONLocked(["type": "muteState", "mutedMac": mutedMac])
        }
    }

    func updateWarning(_ message: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastWarning = message
            let value: Any = message ?? NSNull()
            self.broadcastJSONLocked(["type": "warning", "message": value])
        }
    }

    func updateError(_ message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastError = message
            self.capturing = false
            self.broadcastJSONLocked(["type": "error", "message": message])
        }
    }

    func updateSource(_ source: AudioSourceInfo?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.currentSource = source
            let value: Any = source?.dictionary ?? NSNull()
            self.broadcastJSONLocked(["type": "source", "source": value])
        }
    }

    func broadcastPCMChunk(_ pcmData: Data) {
        queue.async { [weak self] in
            guard let self, !self.clients.isEmpty else { return }

            var packet = Data(capacity: 4 + pcmData.count)
            var leSeq = self.seq.littleEndian
            withUnsafeBytes(of: &leSeq) { packet.append(contentsOf: $0) }
            packet.append(pcmData)
            self.seq &+= 1

            let wsFrame = WSCodec.encodeFrame(opcode: 0x2, payload: packet)
            for client in self.clients.values {
                client.sendBinaryFrame(wsFrame)
            }
        }
    }

    // MARK: - Internal Connection Handling (queue)

    private func stopLocked() {
        stopCaptureWorkItem?.cancel()
        stopCaptureWorkItem = nil

        for client in clients.values {
            client.onClose = nil
            client.close(code: 1001)
        }
        let hadClients = !clients.isEmpty
        clients.removeAll()

        listener?.cancel()
        listener = nil
        capturing = false

        if hadClients {
            onListenerCountChanged?(0)
        }
        onNeedStopCapture?()
    }

    private func handleNewConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        readHTTPRequest(on: conn, buffer: Data())
    }

    private func readHTTPRequest(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                conn.cancel()
                return
            }

            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }

            let delimiter = Data("\r\n\r\n".utf8)
            if let range = accumulated.range(of: delimiter) {
                let headerData = accumulated[accumulated.startIndex..<range.lowerBound]
                let remainder = Data(accumulated[range.upperBound..<accumulated.endIndex])
                self.dispatchHTTPRequest(conn: conn, headerData: headerData, remainder: remainder)
                return
            }

            if isComplete || accumulated.count > 32_768 {
                conn.cancel()
                return
            }

            self.readHTTPRequest(on: conn, buffer: accumulated)
        }
    }

    private func dispatchHTTPRequest(conn: NWConnection, headerData: Data, remainder: Data) {
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            conn.cancel()
            return
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            conn.cancel()
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendHTTP(conn: conn, status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: Data("Bad Request".utf8))
            return
        }

        let rawTarget = String(parts[1])
        let urlPath = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }

        // Handle WebSocket upgrade on /ws
        if urlPath == "/ws", headers["upgrade"]?.lowercased() == "websocket" {
            guard let key = headers["sec-websocket-key"], !key.isEmpty else {
                conn.cancel()
                return
            }
            let accept = WSCodec.acceptKey(for: key)
            let response = [
                "HTTP/1.1 101 Switching Protocols",
                "Upgrade: websocket",
                "Connection: Upgrade",
                "Sec-WebSocket-Accept: \(accept)",
                "",
                ""
            ].joined(separator: "\r\n")

            conn.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] err in
                guard let self else { return }
                if err != nil {
                    conn.cancel()
                    return
                }
                self.registerWebSocketClient(conn: conn, remainder: remainder)
            })
            return
        }

        // JSON status API
        if urlPath == "/api/info" {
            let ips = NetworkInfo.getLANAddresses().map(\.ip)
            var payload = configPayloadLocked()
            payload.removeValue(forKey: "type")
            payload["hostname"] = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            payload["ips"] = ips
            payload["port"] = Int(port)
            payload["clients"] = clients.count
            let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            sendHTTP(conn: conn, status: "200 OK", contentType: "application/json; charset=utf-8", body: json)
            return
        }

        // Static files from bundled public/
        let relative = (urlPath == "/" ? "index.html" : String(urlPath.dropFirst()))
        let targetURL = publicDir.appendingPathComponent(relative).standardizedFileURL
        guard targetURL.path.hasPrefix(publicDir.path) else {
            sendHTTP(conn: conn, status: "403 Forbidden", contentType: "text/plain; charset=utf-8", body: Data("Forbidden".utf8))
            return
        }

        guard let fileData = try? Data(contentsOf: targetURL) else {
            sendHTTP(conn: conn, status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("Not Found".utf8))
            return
        }

        let ext = targetURL.pathExtension.lowercased()
        let contentType = Self.mimeTypes[ext] ?? "application/octet-stream"
        sendHTTP(conn: conn, status: "200 OK", contentType: contentType, body: fileData)
    }

    private func sendHTTP(conn: NWConnection, status: String, contentType: String, body: Data) {
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var response = Data(header.utf8)
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func registerWebSocketClient(conn: NWConnection, remainder: Data) {
        let remote = "\(conn.endpoint)"
        let client = WSClientConnection(connection: conn, remoteDescription: remote, initialData: remainder)
        let clientID = client.id

        clients[clientID] = client
        stopCaptureWorkItem?.cancel()
        stopCaptureWorkItem = nil

        let count = clients.count
        onListenerCountChanged?(count)

        client.onTextMessage = { [weak self, weak client] text in
            guard let self, let client,
                  let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else {
                return
            }

            if type == "ping" {
                var pong: [String: Any] = ["type": "pong"]
                if let t = obj["t"] { pong["t"] = t }
                client.sendJSON(pong)
            } else if type == "setMuteMac", let desired = obj["muted"] as? Bool {
                if desired != self.muteMac {
                    self.muteMac = desired
                    self.onClientSetMuteMac?(desired)
                } else {
                    client.sendJSON(["type": "muteState", "mutedMac": self.muteMac])
                }
            }
        }

        client.onClose = { [weak self] in
            guard let self else { return }
            self.clients.removeValue(forKey: clientID)
            let remaining = self.clients.count
            self.onListenerCountChanged?(remaining)
            if remaining == 0 {
                self.scheduleStopCaptureLocked()
            }
        }

        if !capturing {
            onNeedStartCapture?(muteMac)
        }
        client.sendJSON(configPayloadLocked())
        client.startReading()
    }

    private func scheduleStopCaptureLocked() {
        stopCaptureWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.clients.isEmpty else { return }
            self.capturing = false
            self.lastWarning = nil
            self.onNeedStopCapture?()
        }
        stopCaptureWorkItem = work
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func configPayloadLocked() -> [String: Any] {
        let payload: [String: Any] = [
            "type": "config",
            "sampleRate": formatConfig.sampleRate,
            "channels": formatConfig.channels,
            "framesPerChunk": formatConfig.framesPerChunk,
            "mutedMac": muteMac,
            "capturing": capturing,
            "error": lastError ?? NSNull(),
            "warning": lastWarning ?? NSNull(),
            "source": currentSource?.dictionary ?? NSNull()
        ]
        return payload
    }

    private func broadcastJSONLocked(_ dict: [String: Any]) {
        for client in clients.values {
            client.sendJSON(dict)
        }
    }
}
