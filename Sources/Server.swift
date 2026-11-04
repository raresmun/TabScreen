import Foundation
import Network
import CryptoKit

/// Tiny HTTP + WebSocket server: serves the viewer page and streams the video to it.
final class StreamServer: EncodedFrameSink, @unchecked Sendable {
    private final class Client {
        let connection: NWConnection
        var buffer = Data()
        var isViewer = false
        var hasConfig = false
        var needsKeyFrame = true
        var pendingSends = 0
        var wantsH264 = false
        var wantsJPEG = false
        var missedJPEG = false
        var logLines = 0
        init(connection: NWConnection) { self.connection = connection }
    }

    var onKeyFrameNeeded: (@Sendable () -> Void)?
    var onViewerCountChange: (@Sendable (Int) -> Void)?
    var onJPEGDemandChange: (@Sendable (Bool) -> Void)?
    var onJPEGNeeded: (@Sendable () -> Void)?
    /// A viewer described its screen (in its "hello"): the extra display can be shaped to fit it.
    var onDeviceScreen: (@Sendable (DeviceScreen) -> Void)?

    private let port: UInt16
    private let html: Data
    private let accessKey: String
    private var allowNetwork: Bool
    private let queue = DispatchQueue(label: "tabscreen.server", qos: .userInteractive)
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var config: StreamConfig?
    private var lastKeyFrameRequest = Date.distantPast
    private var jpegDemand = false
    private var wrongKeys: [String: (count: Int, first: Date)] = [:]

    init(port: UInt16, html: Data, accessKey: String, allowNetwork: Bool) {
        self.port = port
        self.html = html
        self.accessKey = accessKey
        self.allowNetwork = allowNetwork
        UserDefaults.standard.removeObject(forKey: "trustedAddresses")   // from an older version
    }

    // MARK: - Listening

    func start() {
        queue.async { self.startListener() }
    }

    func restart(allowNetwork: Bool) {
        queue.async {
            self.allowNetwork = allowNetwork
            self.listener?.cancel()
            self.listener = nil
            for client in self.clients.values { client.connection.cancel() }
            self.clients.removeAll()
            self.updateJPEGDemand()
            self.onViewerCountChange?(0)
            self.queue.asyncAfter(deadline: .now() + 0.5) { self.startListener() }
        }
    }

    private func startListener() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let listener: NWListener
            if allowNetwork {
                listener = try NWListener(using: parameters, on: nwPort)
            } else {
                // USB only: listen on this Mac's internal address (127.0.0.1) only. Nothing on the network can reach it;
                // the tablet comes in through the USB cable, which adb delivers to this address.
                parameters.requiredInterfaceType = .loopback
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
                listener = try NWListener(using: parameters)
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { state in Log.write("Server state: \(state)") }
            listener.start(queue: queue)
            self.listener = listener
            Log.write("Listening on port \(port) (\(allowNetwork ? "USB and Wi-Fi" : "USB only"))")
        } catch {
            Log.write("Could not start the server: \(error)")
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection)
        let id = ObjectIdentifier(client)
        clients[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.removeClient(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: client)
    }

    private func removeClient(_ id: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: id) else { return }
        if client.isViewer {
            Log.write("Tablet disconnected")
            reportViewerCount()
        }
        if client.wantsJPEG { updateJPEGDemand() }
    }

    private func reportViewerCount() {
        let count = clients.values.filter { $0.isViewer }.count
        onViewerCountChange?(count)
    }

    private func receive(on client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak client] data, _, isComplete, error in
            guard let self = self, let client = client else { return }
            if let data = data, !data.isEmpty {
                client.buffer.append(data)
                if client.isViewer {
                    self.readWebSocketFrames(client)
                } else {
                    self.readHTTPRequest(client)
                }
            }
            if isComplete || error != nil {
                client.connection.cancel()
                return
            }
            self.receive(on: client)
        }
    }

    // MARK: - HTTP

    private func readHTTPRequest(_ client: Client) {
        guard let headerEnd = client.buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if client.buffer.count > 32_768 { client.connection.cancel() }
            return
        }
        let head = String(decoding: client.buffer[client.buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        client.buffer.removeSubrange(client.buffer.startIndex..<headerEnd.upperBound)
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else {
            client.connection.cancel()
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let (path, query) = parseTarget(String(requestLine[1]))

        let local = isLocal(client.connection)
        let address = remoteAddress(client.connection) ?? "unknown address"
        Log.write("Request \(path) from \(local ? "USB (localhost)" : address)")

        // The page itself contains no secrets; the picture (WebSocket) needs the access key unless it comes over USB.
        if path == "/" || path == "/index.html" {
            respond(client, status: "200 OK", contentType: "text/html; charset=utf-8", body: html)
            return
        }
        if path == "/favicon.ico" {
            respond(client, status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data())
            return
        }
        if !local {
            if isBlocked(address) {
                respond(client, status: "429 Too Many Requests", contentType: "text/plain; charset=utf-8",
                        body: Data("TabScreen: too many wrong keys, try again in 10 minutes.".utf8))
                return
            }
            guard let key = query["k"], key == accessKey else {
                if query["k"] != nil { noteWrongKey(from: address) }
                respond(client, status: "403 Forbidden", contentType: "text/plain; charset=utf-8",
                        body: Data("TabScreen: wrong or missing access key.".utf8))
                return
            }
        }
        if path == "/auth" {
            respond(client, status: "200 OK", contentType: "text/plain; charset=utf-8", body: Data("ok".utf8))
        } else if path == "/ws", headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
            upgradeToWebSocket(client, key: key)
        } else {
            respond(client, status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("Not found".utf8))
        }
    }

    private func noteWrongKey(from address: String) {
        let now = Date()
        var entry = wrongKeys[address] ?? (count: 0, first: now)
        if now.timeIntervalSince(entry.first) > 600 { entry = (count: 0, first: now) }
        entry.count += 1
        wrongKeys[address] = entry
        Log.write("Wrong access key from \(address) (\(entry.count) of 5)")
        if entry.count == 5 { Log.write("Blocked \(address) for 10 minutes after 5 wrong keys") }
    }

    private func isBlocked(_ address: String) -> Bool {
        guard let entry = wrongKeys[address] else { return false }
        if Date().timeIntervalSince(entry.first) > 600 {
            wrongKeys[address] = nil
            return false
        }
        return entry.count >= 5
    }

    private func parseTarget(_ target: String) -> (String, [String: String]) {
        guard let questionMark = target.firstIndex(of: "?") else { return (target, [:]) }
        var query: [String: String] = [:]
        for pair in target[target.index(after: questionMark)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { query[parts[0]] = parts[1].removingPercentEncoding ?? parts[1] }
        }
        return (String(target[..<questionMark]), query)
    }

    private func isLocal(_ connection: NWConnection) -> Bool {
        guard case let .hostPort(host, _) = connection.endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address.isLoopback
        case .ipv6(let address):
            return address.isLoopback || (address.asIPv4?.isLoopback ?? false)
        case .name(let name, _):
            return name == "localhost"
        @unknown default:
            return false
        }
    }

    private func respond(_ client: Client, status: String, contentType: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        let connection = client.connection
        connection.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - WebSocket

    private func upgradeToWebSocket(_ client: Client, key: String) {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        client.connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
        client.isViewer = true
        client.needsKeyFrame = true
        Log.write("Tablet connected")
        reportViewerCount()
        // The viewer says in its "hello" whether it wants video or pictures.
        if !client.buffer.isEmpty { readWebSocketFrames(client) }
    }

    private func readWebSocketFrames(_ client: Client) {
        while true {
            let buffer = client.buffer
            let start = buffer.startIndex
            guard buffer.count >= 2 else { return }
            let opcode = buffer[start] & 0x0F
            let masked = (buffer[start + 1] & 0x80) != 0
            var length = Int(buffer[start + 1] & 0x7F)
            var offset = 2
            if length == 126 {
                guard buffer.count >= 4 else { return }
                length = (Int(buffer[start + 2]) << 8) | Int(buffer[start + 3])
                offset = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { return }
                length = 0
                for i in 0..<8 { length = (length << 8) | Int(buffer[start + 2 + i]) }
                offset = 10
            }
            guard length >= 0, length <= 1_000_000 else {
                client.connection.cancel()
                return
            }
            var mask = [UInt8](repeating: 0, count: 4)
            if masked {
                guard buffer.count >= offset + 4 else { return }
                for i in 0..<4 { mask[i] = buffer[start + offset + i] }
                offset += 4
            }
            guard buffer.count >= offset + length else { return }
            var payload = [UInt8](buffer[(start + offset)..<(start + offset + length)])
            if masked {
                for i in 0..<payload.count { payload[i] ^= mask[i & 3] }
            }
            client.buffer.removeSubrange(start..<(start + offset + length))
            handleMessage(from: client, opcode: opcode, payload: Data(payload))
        }
    }

    private func handleMessage(from client: Client, opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x1:
            guard let message = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
                  let type = message["type"] as? String else { return }
            if type == "key" {
                client.needsKeyFrame = true
                requestKeyFrame(force: false)
            } else if type == "log" {
                // Notes from the tablet app (which decoder it uses, how fast it runs), kept short and limited.
                guard client.logLines < 100, let text = message["text"] as? String else { return }
                client.logLines += 1
                Log.write("Tablet app: " + String(text.prefix(300)).replacingOccurrences(of: "\n", with: " "))
            } else if type == "hello" {
                replaceOlderViewers(of: client)
                let pictureMode = (message["mode"] as? String) == "jpeg"
                if (message["client"] as? String) == "app" {
                    Log.write("Tablet app: \(message["ua"] ?? "?")")
                    Log.write("Tablet screen: \(message["w"] ?? "?") x \(message["h"] ?? "?") pixels at \(message["refresh"] ?? "?") Hz – video mode")
                } else {
                    Log.write("Tablet browser: \(message["ua"] ?? "?") – secure page: \(message["secure"] ?? "?")")
                    Log.write("Tablet screen: \(message["w"] ?? "?") x \(message["h"] ?? "?") pixels – \(pictureMode ? "picture mode (plain Wi-Fi page)" : "video mode")")
                }
                if let screen = DeviceScreen(hello: message) { onDeviceScreen?(screen) }
                if pictureMode {
                    client.wantsJPEG = true
                    updateJPEGDemand()
                    onJPEGNeeded?()
                } else {
                    client.wantsH264 = true
                    if let config = config { sendConfig(config, to: client) }
                    requestKeyFrame(force: true)
                }
                if let image = lastCursorImageMessage { sendFrame(to: client, opcode: 0x1, payload: image) }
                if let position = lastCursorMessage { sendFrame(to: client, opcode: 0x1, payload: position) }
            }
        case 0x8:
            client.connection.cancel()
        case 0x9:
            sendFrame(to: client, opcode: 0xA, payload: payload)
        default:
            break
        }
    }

    private func requestKeyFrame(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastKeyFrameRequest) > 0.5 else { return }
        lastKeyFrameRequest = now
        onKeyFrameNeeded?()
    }

    private func sendConfig(_ config: StreamConfig, to client: Client) {
        let message: [String: Any] = [
            "type": "config",
            "codec": config.codec,
            "width": config.width,
            "height": config.height,
            "description": config.description.base64EncodedString(),
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: message) else { return }
        sendFrame(to: client, opcode: 0x1, payload: json)
        client.hasConfig = true
        client.needsKeyFrame = true
    }

    private func makeFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data(capacity: payload.count + 10)
        frame.append(0x80 | opcode)
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(UInt8(126))
            frame.append(UInt8(count >> 8))
            frame.append(UInt8(count & 0xFF))
        } else {
            frame.append(UInt8(127))
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }

    private func sendFrame(to client: Client, opcode: UInt8, payload: Data) {
        let frame = makeFrame(opcode: opcode, payload: payload)
        client.pendingSends += 1
        client.connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
            client.pendingSends -= 1
            if client.missedJPEG && client.pendingSends == 0 {
                client.missedJPEG = false
                self?.onJPEGNeeded?()
            }
        })
    }

    // MARK: - EncodedFrameSink

    func encoderProduced(config: StreamConfig) {
        queue.async {
            self.config = config
            for client in self.clients.values where client.isViewer && client.wantsH264 {
                self.sendConfig(config, to: client)
            }
        }
    }

    func encoderProduced(frame: Data, isKeyFrame: Bool, timestampMicros: Double) {
        queue.async {
            var packet = Data(capacity: frame.count + 9)
            packet.append(UInt8(isKeyFrame ? 1 : 0))
            withUnsafeBytes(of: timestampMicros.bitPattern.bigEndian) { packet.append(contentsOf: $0) }
            packet.append(frame)
            var needKeyFrame = false
            for client in self.clients.values where client.isViewer && client.wantsH264 && client.hasConfig {
                if client.needsKeyFrame && !isKeyFrame {
                    needKeyFrame = true
                    continue
                }
                if client.pendingSends > 8 {
                    // The connection can't keep up: skip ahead and restart from a key frame.
                    client.needsKeyFrame = true
                    needKeyFrame = true
                    continue
                }
                if isKeyFrame { client.needsKeyFrame = false }
                self.sendFrame(to: client, opcode: 0x2, payload: packet)
            }
            if needKeyFrame { self.requestKeyFrame(force: false) }
        }
    }

    // MARK: - Picture mode (JPEG) for browsers without video decoding

    func broadcastJPEG(_ jpeg: Data, fullSize: Bool) {
        queue.async {
            var packet = Data(capacity: jpeg.count + 1)
            packet.append(UInt8(fullSize ? 0x10 : 0x11))
            packet.append(jpeg)
            for client in self.clients.values where client.isViewer && client.wantsJPEG {
                if client.pendingSends > 2 {
                    // Wi-Fi is busy: skip this picture; a fresh one is sent once the connection catches up.
                    client.missedJPEG = true
                    continue
                }
                self.sendFrame(to: client, opcode: 0x2, payload: packet)
            }
        }
    }

    // MARK: - Pointer (drawn by the tablet itself)

    private var lastCursorMessage: Data?
    private var lastCursorImageMessage: Data?

    func broadcastCursor(_ message: Data, isImage: Bool) {
        queue.async {
            if isImage { self.lastCursorImageMessage = message } else { self.lastCursorMessage = message }
            for client in self.clients.values where client.isViewer && (client.wantsH264 || client.wantsJPEG) {
                if !isImage && client.pendingSends > 6 { continue }   // busy link: skip a pointer update, the next one follows
                self.sendFrame(to: client, opcode: 0x1, payload: message)
            }
        }
    }

    /// One stream per tablet: when a page connects again (a second tab, a reload), the older page steps aside.
    private func replaceOlderViewers(of client: Client) {
        let address = isLocal(client.connection) ? "localhost" : remoteAddress(client.connection)
        var replacedAny = false
        for other in clients.values where other !== client && other.isViewer {
            let otherAddress = isLocal(other.connection) ? "localhost" : remoteAddress(other.connection)
            guard otherAddress == address else { continue }
            other.isViewer = false
            other.wantsH264 = false
            other.wantsJPEG = false
            let connection = other.connection
            connection.send(content: makeFrame(opcode: 0x1, payload: Data("{\"type\":\"replaced\"}".utf8)),
                            completion: .contentProcessed { _ in connection.cancel() })
            replacedAny = true
        }
        if replacedAny {
            Log.write("Closed an older TabScreen page on the same tablet")
            updateJPEGDemand()
            reportViewerCount()
        }
    }

    private func updateJPEGDemand() {
        let wanted = clients.values.contains { $0.isViewer && $0.wantsJPEG }
        guard wanted != jpegDemand else { return }
        jpegDemand = wanted
        Log.write(wanted ? "Picture mode on (tablet browser can't decode video)" : "Picture mode off")
        onJPEGDemandChange?(wanted)
    }

    private func remoteAddress(_ connection: NWConnection) -> String? {
        guard case let .hostPort(host, _) = connection.endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }
}
