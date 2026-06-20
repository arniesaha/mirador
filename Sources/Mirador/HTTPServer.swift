import Foundation
import Network

public enum HTTPResponses {
    public static func metricsJSON(_ snapshot: MetricsSnapshot) -> String {
        let safeSnapshot = MetricsSnapshot(
            rssBytes: snapshot.rssBytes,
            activeStreams: snapshot.activeStreams,
            fps: snapshot.fps.isFinite ? snapshot.fps : 0,
            droppedFrames: snapshot.droppedFrames,
            latestFrameSequence: snapshot.latestFrameSequence,
            latestFrameBytes: snapshot.latestFrameBytes,
            latestFrameAgeMillis: snapshot.latestFrameAgeMillis.isFinite ? snapshot.latestFrameAgeMillis : 0,
            inputSockets: snapshot.inputSockets,
            inputEvents: snapshot.inputEvents,
            bitrateBitsPerSec: snapshot.bitrateBitsPerSec.isFinite ? snapshot.bitrateBitsPerSec : 0,
            incompleteFrames: snapshot.incompleteFrames,
            inputDispatchMillis: snapshot.inputDispatchMillis.isFinite ? snapshot.inputDispatchMillis : 0,
            encodeFps: snapshot.encodeFps.isFinite ? snapshot.encodeFps : 0,
            encodeBitrateBitsPerSec: snapshot.encodeBitrateBitsPerSec.isFinite ? snapshot.encodeBitrateBitsPerSec : 0,
            encodeMillis: snapshot.encodeMillis.isFinite ? snapshot.encodeMillis : 0,
            keyframeIntervalFrames: snapshot.keyframeIntervalFrames.isFinite ? snapshot.keyframeIntervalFrames : 0,
            videoStreams: snapshot.videoStreams
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(safeSnapshot),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

public final class HTTPServer: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let frameQueue: MJPEGFrameQueue
    private let h264Queue: H264FrameQueue
    private let captureControl: CaptureControlling?
    private let consumers: CaptureConsumers
    private let inputDispatcher: InputEventDispatching
    private let authToken: String
    private let viewerAssets: ViewerAssets
    private let listener: NWListener
    private let maxConnections: Int
    private let maxStreams: Int
    private let maxInputSockets: Int
    private let queue = DispatchQueue(label: "mirador.http-server", qos: .userInitiated)
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var streamCount = 0
    private var streamConnections: Set<ObjectIdentifier> = []
    private var streamContexts: [ObjectIdentifier: StreamContext] = [:]
    // H.264/WebSocket video streams, tracked in parallel with MJPEG streams.
    private var videoStreamCount = 0
    private var videoStreamConnections: Set<ObjectIdentifier> = []
    private var videoStreamContexts: [ObjectIdentifier: VideoStreamContext] = [:]
    private let maxVideoStreams: Int
    // Combined viewer-media stream count drives the demand-driven capture lifecycle.
    private var mediaStreamCount = 0

    /// Frame send cadence. A ~30 fps tick delivers each newly captured frame (capture is
    /// ~15 fps) within ~33 ms. Driven by a DispatchSourceTimer rather than chained
    /// asyncAfter, which on a background daemon fired pathologically late (~210 ms).
    static let frameTickMillis = 33
    /// When the screen is static (no new frames), resend the last frame at most this often
    /// so an idle stream costs almost no bandwidth.
    static let keepaliveMillis: UInt64 = 1000
    /// Video send cadence. Polled faster than the ~33 ms capture period so a newly encoded
    /// H.264 access unit reaches the viewer with minimal added latency.
    static let videoTickMillis = 12

    /// Per-stream send state. All fields are touched only on `queue`, so no extra locking.
    private final class StreamContext: @unchecked Sendable {
        var timer: DispatchSourceTimer?
        var inFlight = false
        var hasSentAny = false
        var lastSentSequence: UInt64?
        var lastCaptureMillis: Int64?
        var previousFrame: Data?
        var lastSendNanos: UInt64 = 0
    }

    /// Per-video-stream send state. Touched only on `queue`.
    private final class VideoStreamContext: @unchecked Sendable {
        var timer: DispatchSourceTimer?
        var inFlight = false
        var sentKeyframe = false
        var lastSentSequence: UInt64?
    }
    private var inputSocketConnections: Set<ObjectIdentifier> = []
    private var inputSocketCount = 0
    private var inputEventCount: UInt64 = 0
    private var inputDispatchMillisValue: Double = 0

    public init(host: String, port: Int, frameQueue: MJPEGFrameQueue, h264Queue: H264FrameQueue = H264FrameQueue(capacity: 2), captureControl: CaptureControlling? = nil, consumers: CaptureConsumers = CaptureConsumers(), inputDispatcher: InputEventDispatching = CGEventInputDispatcher(), authToken: String = "", viewerAssets: ViewerAssets = .default, maxConnections: Int = 16, maxStreams: Int = 2, maxVideoStreams: Int = 2, maxInputSockets: Int = 4) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw HTTPServerError.invalidPort(port)
        }

        self.host = host
        self.port = port
        self.frameQueue = frameQueue
        self.h264Queue = h264Queue
        self.captureControl = captureControl
        self.consumers = consumers
        self.inputDispatcher = inputDispatcher
        self.authToken = authToken
        self.viewerAssets = viewerAssets
        self.maxConnections = max(1, maxConnections)
        self.maxStreams = max(1, maxStreams)
        self.maxVideoStreams = max(1, maxVideoStreams)
        self.maxInputSockets = max(1, maxInputSockets)

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        self.listener = try NWListener(using: parameters)
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
        lock.lock()
        let activeConnections = Array(connections.values)
        let timers = streamContexts.values.compactMap { $0.timer } + videoStreamContexts.values.compactMap { $0.timer }
        connections.removeAll()
        streamCount = 0
        streamConnections.removeAll()
        streamContexts.removeAll()
        videoStreamCount = 0
        videoStreamConnections.removeAll()
        videoStreamContexts.removeAll()
        mediaStreamCount = 0
        inputSocketCount = 0
        inputSocketConnections.removeAll()
        lock.unlock()
        timers.forEach { $0.cancel() }
        activeConnections.forEach { $0.cancel() }
    }

    public var activeStreams: Int {
        lock.lock()
        defer { lock.unlock() }
        return streamCount
    }

    private func accept(_ connection: NWConnection) {
        guard retain(connection) else {
            connection.start(queue: queue)
            sendResponse(status: "503 Service Unavailable", contentType: "text/plain; charset=utf-8", body: "Service Unavailable", headOnly: false, on: connection)
            return
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                self.release(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        readRequest(from: connection, accumulator: HTTPHeaderAccumulator())
    }

    private func readRequest(from connection: NWConnection, accumulator: HTTPHeaderAccumulator) {
        let maxLength = max(1, HTTPHeaderAccumulator.maxHeaderBytes - accumulator.byteCount + 1)
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            guard error == nil, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            var nextAccumulator = accumulator
            switch nextAccumulator.append(data) {
            case .complete(let headerData, let remainingData):
                guard let request = HTTPRequest(headerData: headerData) else {
                    self.sendResponse(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: "Bad Request", headOnly: false, on: connection)
                    return
                }
                self.readBodyIfNeeded(for: request, initialBody: remainingData, from: connection)
            case .needMore:
                self.readRequest(from: connection, accumulator: nextAccumulator)
            case .tooLarge:
                self.sendResponse(status: "431 Request Header Fields Too Large", contentType: "text/plain; charset=utf-8", body: "Request Header Fields Too Large", headOnly: false, on: connection)
            }
        }
    }

    private func readBodyIfNeeded(for request: HTTPRequest, initialBody: Data, from connection: NWConnection) {
        guard request.hasValidContentLength else {
            sendResponse(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: "Bad Request", headOnly: false, on: connection)
            return
        }
        let contentLength = request.contentLength ?? 0
        guard contentLength <= 4 * 1024 else {
            sendResponse(status: "413 Payload Too Large", contentType: "text/plain; charset=utf-8", body: "Payload Too Large", headOnly: false, on: connection)
            return
        }
        guard initialBody.count < contentLength else {
            route(request, body: Data(initialBody.prefix(contentLength)), on: connection)
            return
        }

        connection.receive(minimumIncompleteLength: contentLength - initialBody.count, maximumLength: contentLength - initialBody.count) { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            guard error == nil, let data else {
                connection.cancel()
                return
            }
            var body = initialBody
            body.append(data)
            self.route(request, body: Data(body.prefix(contentLength)), on: connection)
        }
    }

    private func route(_ request: HTTPRequest, body: Data, on connection: NWConnection) {
        let method = request.method.uppercased()
        guard Self.isAuthorized(request, token: authToken) else {
            sendResponse(status: "401 Unauthorized", contentType: "text/plain; charset=utf-8", body: "Unauthorized", headOnly: method == "HEAD", on: connection)
            return
        }
        if request.path == "/ws/input", WebSocketHandshake.isUpgradeRequest(request) {
            startWebSocketInput(request, on: connection)
            return
        }
        if request.path == "/ws/video", WebSocketHandshake.isUpgradeRequest(request) {
            startWebSocketVideo(request, on: connection)
            return
        }
        if request.path == "/input" {
            handleInput(request, body: body, on: connection)
            return
        }

        guard method == "GET" || method == "HEAD" else {
            sendResponse(status: "405 Method Not Allowed", contentType: "text/plain; charset=utf-8", body: "Method Not Allowed", headOnly: method == "HEAD", on: connection)
            return
        }

        switch request.path {
        case "/":
            let requestHost = request.headers["host"]?.split(separator: ":").first.map(String.init) ?? host
            let html = viewerAssets.renderHTML(authToken: authToken) ?? ViewerHTML.render(host: requestHost, port: port, authToken: authToken)
            sendResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: html, headOnly: method == "HEAD", on: connection)
        case "/assets/viewer.css", "/assets/viewer.js":
            guard let asset = viewerAssets.staticAsset(for: request.path) else {
                sendResponse(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: "Not Found", headOnly: method == "HEAD", on: connection)
                return
            }
            sendDataResponse(status: "200 OK", contentType: asset.contentType, body: asset.data, headOnly: method == "HEAD", on: connection)
        case "/metrics":
            let snapshot = ProcessMetrics.snapshot(activeStreams: activeStreams, frameStore: frameQueue.snapshot(), videoStore: h264Queue.snapshot(), videoStreams: activeVideoStreams, inputSockets: activeInputSockets, inputEvents: totalInputEvents, inputDispatchMillis: lastInputDispatchMillis)
            sendResponse(status: "200 OK", contentType: "application/json; charset=utf-8", body: HTTPResponses.metricsJSON(snapshot), headOnly: method == "HEAD", on: connection)
        case "/stream.mjpg":
            if method == "HEAD" {
                sendHeaders(status: "200 OK", headers: [
                    "Content-Type": "multipart/x-mixed-replace; boundary=frame",
                    "Cache-Control": "no-store",
                    "Connection": "close"
                ], on: connection, closeWhenDone: true)
            } else {
                startMJPEGStream(on: connection)
            }
        default:
            sendResponse(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: "Not Found", headOnly: method == "HEAD", on: connection)
        }
    }

    private func handleInput(_ request: HTTPRequest, body: Data, on connection: NWConnection) {
        guard request.method.uppercased() == "POST" else {
            sendResponse(status: "405 Method Not Allowed", contentType: "text/plain; charset=utf-8", body: "Method Not Allowed", headOnly: false, on: connection)
            return
        }
        guard request.headers["content-type"]?.lowercased().split(separator: ";").first == "application/json" else {
            sendResponse(status: "415 Unsupported Media Type", contentType: "text/plain; charset=utf-8", body: "Unsupported Media Type", headOnly: false, on: connection)
            return
        }

        do {
            let event = try InputEvent(jsonData: body)
            try dispatchTimed(event)
            sendResponse(status: "204 No Content", contentType: "text/plain; charset=utf-8", body: "", headOnly: false, on: connection)
        } catch InputEventError.accessibilityPermissionDenied {
            sendResponse(status: "403 Forbidden", contentType: "text/plain; charset=utf-8", body: "Accessibility permission is not granted", headOnly: false, on: connection)
        } catch {
            sendResponse(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: "Bad Request", headOnly: false, on: connection)
        }
    }

    // MARK: - WebSocket input channel

    private func startWebSocketInput(_ request: HTTPRequest, on connection: NWConnection) {
        guard let key = request.headers["sec-websocket-key"] else {
            sendResponse(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: "Bad Request", headOnly: false, on: connection)
            return
        }
        guard incrementInputSockets(for: connection) else {
            sendResponse(status: "503 Service Unavailable", contentType: "text/plain; charset=utf-8", body: "Service Unavailable", headOnly: false, on: connection)
            return
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                self.decrementInputSockets(for: connection)
                self.release(connection)
            default:
                break
            }
        }

        sendHeaders(status: "101 Switching Protocols", headers: [
            "Connection": "Upgrade",
            "Sec-WebSocket-Accept": WebSocketHandshake.acceptKey(for: key),
            "Upgrade": "websocket"
        ], on: connection, closeWhenDone: false)

        receiveWebSocketFrames(on: connection, decoder: WebSocketFrameDecoder())
    }

    private func receiveWebSocketFrames(on connection: NWConnection, decoder: WebSocketFrameDecoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            guard error == nil else { connection.cancel(); return }

            var nextDecoder = decoder
            if let data, !data.isEmpty {
                nextDecoder.append(data)
                drain: while true {
                    switch nextDecoder.next() {
                    case .needMore:
                        break drain
                    case .protocolError:
                        self.closeWebSocket(connection, code: 1002)
                        return
                    case .frame(let frame):
                        if !self.handleWebSocketFrame(frame, on: connection) {
                            return
                        }
                    }
                }
            }

            if isComplete {
                connection.cancel()
                return
            }
            self.receiveWebSocketFrames(on: connection, decoder: nextDecoder)
        }
    }

    /// Returns false when the socket has been closed and the receive loop should stop.
    private func handleWebSocketFrame(_ frame: WebSocketFrame, on connection: NWConnection) -> Bool {
        switch frame.opcode {
        case .text:
            handleWebSocketInput(frame.payload, on: connection)
            return true
        case .binary:
            return true // not used by the viewer; keep the channel open
        case .ping:
            connection.send(content: WebSocketEncoder.pong(frame.payload), completion: .idempotent)
            return true
        case .pong:
            return true
        case .close:
            closeWebSocket(connection, code: 1000)
            return false
        case .continuation:
            // The viewer only sends small, single-frame text events.
            closeWebSocket(connection, code: 1002)
            return false
        }
    }

    private func handleWebSocketInput(_ payload: Data, on connection: NWConnection) {
        let decoded: (event: InputEvent, seq: UInt64?)
        do {
            decoded = try InputEvent.decode(jsonData: payload)
        } catch {
            // Malformed event: ignore without tearing down the persistent channel.
            return
        }

        var dispatched = true
        do {
            try dispatchTimed(decoded.event)
            recordInputEvent()
        } catch {
            dispatched = false
        }

        if let seq = decoded.seq {
            let ack = "{\"type\":\"ack\",\"seq\":\(seq),\"ok\":\(dispatched)}"
            connection.send(content: WebSocketEncoder.text(ack), completion: .idempotent)
        }
    }

    private func closeWebSocket(_ connection: NWConnection, code: UInt16) {
        connection.send(content: WebSocketEncoder.close(code: code), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendResponse(status: String, contentType: String, body: String, headOnly: Bool, on connection: NWConnection) {
        sendDataResponse(status: status, contentType: contentType, body: Data(body.utf8), headOnly: headOnly, on: connection)
    }

    private func sendDataResponse(status: String, contentType: String, body: Data, headOnly: Bool, on connection: NWConnection) {
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        // The viewer HTML/JS/CSS are token-bearing and change during development;
        // never let the browser serve a stale cached copy.
        response += "Cache-Control: no-store\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        var payload = Data(response.utf8)
        if !headOnly {
            payload.append(body)
        }
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendHeaders(status: String, headers: [String: String], on connection: NWConnection, closeWhenDone: Bool) {
        var response = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            response += "\(name): \(value)\r\n"
        }
        response += "\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            if closeWhenDone {
                connection.cancel()
            }
        })
    }

    private func startMJPEGStream(on connection: NWConnection) {
        guard incrementStreams(for: connection) else {
            sendResponse(status: "503 Service Unavailable", contentType: "text/plain; charset=utf-8", body: "Service Unavailable", headOnly: false, on: connection)
            return
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                self.stopStreamTimer(for: connection)
                self.decrementStreams(for: connection)
                self.release(connection)
            default:
                break
            }
        }

        sendHeaders(status: "200 OK", headers: [
            "Content-Type": "multipart/x-mixed-replace; boundary=frame",
            "Cache-Control": "no-store",
            "Connection": "close"
        ], on: connection, closeWhenDone: false)

        startStreamTimer(on: connection)
    }

    private func startStreamTimer(on connection: NWConnection) {
        let context = StreamContext()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        context.timer = timer
        lock.lock()
        streamContexts[ObjectIdentifier(connection)] = context
        lock.unlock()
        timer.schedule(deadline: .now(), repeating: .milliseconds(Self.frameTickMillis), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.streamTick(on: connection, context: context)
        }
        timer.resume()
    }

    private func stopStreamTimer(for connection: NWConnection) {
        lock.lock()
        let context = streamContexts.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
        context?.timer?.cancel()
        context?.timer = nil
    }

    /// Sends the latest captured frame to one stream. Runs on `queue` each timer tick.
    private func streamTick(on connection: NWConnection, context: StreamContext) {
        guard isActiveStream(connection) else { return }
        if context.inFlight { return }   // previous send still pending; catch it next tick

        let latest = frameQueue.latestFrame(after: context.lastSentSequence)
        if latest == nil, context.hasSentAny {
            // Static screen: resend only as an occasional keepalive to save bandwidth.
            let elapsed = DispatchTime.now().uptimeNanoseconds &- context.lastSendNanos
            if elapsed < Self.keepaliveMillis * 1_000_000 { return }
        }

        let selected = Self.jpegForStream(nextFrame: latest?.jpeg, previousFrame: context.previousFrame)
        let jpeg = selected.jpeg
        let nextSequence = latest?.sequence ?? context.lastSentSequence
        let captureMillis = latest.map { Int64($0.capturedAt.timeIntervalSince1970 * 1000) } ?? context.lastCaptureMillis

        var chunk = Data("--frame\r\nContent-Type: image/jpeg\r\nX-Mirador-Sequence: \(nextSequence ?? 0)\r\nX-Mirador-Capture-Millis: \(captureMillis ?? 0)\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
        chunk.append(jpeg)
        chunk.append(Data("\r\n".utf8))

        context.inFlight = true
        context.previousFrame = selected.previousFrame
        context.lastSentSequence = nextSequence
        context.lastCaptureMillis = captureMillis
        context.lastSendNanos = DispatchTime.now().uptimeNanoseconds
        context.hasSentAny = true

        connection.send(content: chunk, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection else { return }
            context.inFlight = false
            if error != nil || !self.isActiveStream(connection) {
                connection.cancel()
            }
        })
    }

    // MARK: - WebSocket video channel (H.264 → WebCodecs)

    private func startWebSocketVideo(_ request: HTTPRequest, on connection: NWConnection) {
        guard let key = request.headers["sec-websocket-key"] else {
            sendResponse(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: "Bad Request", headOnly: false, on: connection)
            return
        }
        guard incrementVideoStreams(for: connection) else {
            sendResponse(status: "503 Service Unavailable", contentType: "text/plain; charset=utf-8", body: "Service Unavailable", headOnly: false, on: connection)
            return
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                self.stopVideoTimer(for: connection)
                self.decrementVideoStreams(for: connection)
                self.release(connection)
            default:
                break
            }
        }

        sendHeaders(status: "101 Switching Protocols", headers: [
            "Connection": "Upgrade",
            "Sec-WebSocket-Accept": WebSocketHandshake.acceptKey(for: key),
            "Upgrade": "websocket"
        ], on: connection, closeWhenDone: false)

        // A viewer joining a capture that is already running needs an IDR promptly;
        // for the first viewer the encoder's first frame is already a keyframe.
        captureControl?.requestKeyframe()
        startVideoTimer(on: connection)
        receiveVideoControlFrames(on: connection, decoder: WebSocketFrameDecoder())
    }

    /// Reads client control frames on the video socket (ping/close). The video channel is
    /// server→client only, so client text/binary frames are ignored.
    private func receiveVideoControlFrames(on connection: NWConnection, decoder: WebSocketFrameDecoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            guard error == nil else { connection.cancel(); return }

            var nextDecoder = decoder
            if let data, !data.isEmpty {
                nextDecoder.append(data)
                drain: while true {
                    switch nextDecoder.next() {
                    case .needMore:
                        break drain
                    case .protocolError:
                        self.closeWebSocket(connection, code: 1002)
                        return
                    case .frame(let frame):
                        switch frame.opcode {
                        case .ping:
                            connection.send(content: WebSocketEncoder.pong(frame.payload), completion: .idempotent)
                        case .text:
                            // Viewer-side decode diagnostics (prefixed "diag:") logged for debugging.
                            let msg = String(decoding: frame.payload.prefix(512), as: UTF8.self)
                            FileHandle.standardError.write(Data("mirador: video-diag: \(msg)\n".utf8))
                        case .close:
                            self.closeWebSocket(connection, code: 1000)
                            return
                        default:
                            break
                        }
                    }
                }
            }

            if isComplete {
                connection.cancel()
                return
            }
            self.receiveVideoControlFrames(on: connection, decoder: nextDecoder)
        }
    }

    private func startVideoTimer(on connection: NWConnection) {
        let context = VideoStreamContext()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        context.timer = timer
        lock.lock()
        videoStreamContexts[ObjectIdentifier(connection)] = context
        lock.unlock()
        timer.schedule(deadline: .now(), repeating: .milliseconds(Self.videoTickMillis), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.videoTick(on: connection, context: context)
        }
        timer.resume()
    }

    private func stopVideoTimer(for connection: NWConnection) {
        lock.lock()
        let context = videoStreamContexts.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
        context?.timer?.cancel()
        context?.timer = nil
    }

    /// Sends the latest encoded H.264 access unit to one video stream. Runs on `queue`.
    /// Each binary WebSocket frame is `seq(8) | captureMillis(8) | flags(1) | Annex-B`.
    private func videoTick(on connection: NWConnection, context: VideoStreamContext) {
        guard isActiveVideoStream(connection) else { return }
        if context.inFlight { return }

        guard let frame = h264Queue.latestFrame(after: context.lastSentSequence) else { return }
        // Don't start a decoder mid-GOP: wait for the first keyframe.
        if !context.sentKeyframe && !frame.isKeyframe { return }

        var payload = Data()
        var seqBE = frame.sequence.bigEndian
        withUnsafeBytes(of: &seqBE) { payload.append(contentsOf: $0) }
        var captureBE = UInt64(max(0, frame.capturedAt.timeIntervalSince1970 * 1000)).bigEndian
        withUnsafeBytes(of: &captureBE) { payload.append(contentsOf: $0) }
        payload.append(frame.isKeyframe ? 0x01 : 0x00)
        payload.append(frame.data)

        context.inFlight = true
        context.lastSentSequence = frame.sequence
        if frame.isKeyframe { context.sentKeyframe = true }

        connection.send(content: WebSocketEncoder.encode(opcode: .binary, payload: payload), completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection else { return }
            context.inFlight = false
            if error != nil || !self.isActiveVideoStream(connection) {
                connection.cancel()
            }
        })
    }

    private func retain(_ connection: NWConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard connections.count < maxConnections else { return false }
        connections[ObjectIdentifier(connection)] = connection
        return true
    }

    private func release(_ connection: NWConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    private func incrementStreams(for connection: NWConnection) -> Bool {
        lock.lock()
        let id = ObjectIdentifier(connection)
        guard streamConnections.contains(id) || streamCount < maxStreams else {
            lock.unlock()
            return false
        }
        let inserted = streamConnections.insert(id).inserted
        if inserted { streamCount += 1 }
        let count = streamCount
        lock.unlock()
        consumers.setMJPEG(count)
        if inserted { mediaStreamStarted() }
        return true
    }

    private func decrementStreams(for connection: NWConnection) {
        lock.lock()
        let id = ObjectIdentifier(connection)
        let removed = streamConnections.remove(id) != nil
        if removed { streamCount = max(0, streamCount - 1) }
        let count = streamCount
        lock.unlock()
        consumers.setMJPEG(count)
        if removed { mediaStreamStopped() }
    }

    private func isActiveStream(_ connection: NWConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let id = ObjectIdentifier(connection)
        return connections[id] != nil && streamConnections.contains(id)
    }

    public var activeVideoStreams: Int {
        lock.lock()
        defer { lock.unlock() }
        return videoStreamCount
    }

    private func incrementVideoStreams(for connection: NWConnection) -> Bool {
        lock.lock()
        let id = ObjectIdentifier(connection)
        guard videoStreamConnections.contains(id) || videoStreamCount < maxVideoStreams else {
            lock.unlock()
            return false
        }
        let inserted = videoStreamConnections.insert(id).inserted
        if inserted { videoStreamCount += 1 }
        let count = videoStreamCount
        lock.unlock()
        consumers.setH264(count)
        if inserted { mediaStreamStarted() }
        return true
    }

    private func decrementVideoStreams(for connection: NWConnection) {
        lock.lock()
        let id = ObjectIdentifier(connection)
        let removed = videoStreamConnections.remove(id) != nil
        if removed { videoStreamCount = max(0, videoStreamCount - 1) }
        let count = videoStreamCount
        lock.unlock()
        consumers.setH264(count)
        if removed { mediaStreamStopped() }
    }

    private func isActiveVideoStream(_ connection: NWConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let id = ObjectIdentifier(connection)
        return connections[id] != nil && videoStreamConnections.contains(id)
    }

    /// Adjusts the combined viewer-media count and drives the capture pipeline on the
    /// idle<->active boundary. Must be called WITHOUT holding `lock`.
    private func mediaStreamStarted() {
        lock.lock()
        mediaStreamCount += 1
        let firstViewer = mediaStreamCount == 1
        lock.unlock()
        if firstViewer { captureControl?.acquire() }
    }

    private func mediaStreamStopped() {
        lock.lock()
        mediaStreamCount = max(0, mediaStreamCount - 1)
        let lastViewer = mediaStreamCount == 0
        lock.unlock()
        if lastViewer { captureControl?.release() }
    }

    public var activeInputSockets: Int {
        lock.lock()
        defer { lock.unlock() }
        return inputSocketCount
    }

    public var totalInputEvents: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return inputEventCount
    }

    private func incrementInputSockets(for connection: NWConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let id = ObjectIdentifier(connection)
        guard inputSocketConnections.contains(id) || inputSocketCount < maxInputSockets else { return false }
        if inputSocketConnections.insert(id).inserted {
            inputSocketCount += 1
        }
        return true
    }

    private func decrementInputSockets(for connection: NWConnection) {
        lock.lock()
        let id = ObjectIdentifier(connection)
        if inputSocketConnections.remove(id) != nil {
            inputSocketCount = max(0, inputSocketCount - 1)
        }
        lock.unlock()
    }

    private func recordInputEvent() {
        lock.lock()
        inputEventCount &+= 1
        lock.unlock()
    }

    private var lastInputDispatchMillis: Double {
        lock.lock()
        defer { lock.unlock() }
        return inputDispatchMillisValue
    }

    /// Times a dispatch call and records the duration in milliseconds.
    private func dispatchTimed(_ event: InputEvent) throws {
        let start = DispatchTime.now()
        try inputDispatcher.dispatch(event)
        let millis = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
        lock.lock()
        inputDispatchMillisValue = millis
        lock.unlock()
    }

    static func jpegForStream(nextFrame: Data?, previousFrame: Data?) -> (jpeg: Data, previousFrame: Data?) {
        if let nextFrame {
            return (nextFrame, nextFrame)
        }
        if let previousFrame {
            return (previousFrame, previousFrame)
        }
        return (syntheticJPEG, nil)
    }

    static func isAuthorized(_ request: HTTPRequest, token: String) -> Bool {
        guard !token.isEmpty else { return true }
        if request.headers["x-mirador-token"] == token { return true }
        if request.query["token"] == token { return true }
        return false
    }

    // 1x1 black JPEG. Used only before the first real ScreenCaptureKit frame arrives.
    static let syntheticJPEG = Data([
        0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01,
        0x01, 0x01, 0x00, 0x48, 0x00, 0x48, 0x00, 0x00, 0xff, 0xdb, 0x00, 0x43,
        0x00, 0x03, 0x02, 0x02, 0x03, 0x02, 0x02, 0x03, 0x03, 0x03, 0x03, 0x04,
        0x03, 0x03, 0x04, 0x05, 0x08, 0x05, 0x05, 0x04, 0x04, 0x05, 0x0a, 0x07,
        0x07, 0x06, 0x08, 0x0c, 0x0a, 0x0c, 0x0c, 0x0b, 0x0a, 0x0b, 0x0b, 0x0d,
        0x0e, 0x12, 0x10, 0x0d, 0x0e, 0x11, 0x0e, 0x0b, 0x0b, 0x10, 0x16, 0x10,
        0x11, 0x13, 0x14, 0x15, 0x15, 0x15, 0x0c, 0x0f, 0x17, 0x18, 0x16, 0x14,
        0x18, 0x12, 0x14, 0x15, 0x14, 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x01,
        0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xff, 0xc4, 0x00, 0x14, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x08, 0xff, 0xc4, 0x00, 0x14, 0x10, 0x01, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00,
        0x37, 0xff, 0xd9
    ])
}

public enum HTTPServerError: Error, CustomStringConvertible {
    case invalidPort(Int)

    public var description: String {
        switch self {
        case .invalidPort(let port):
            return "Invalid port: \(port)"
        }
    }
}

enum HTTPHeaderReadResult: Equatable {
    case needMore
    case complete(headerData: Data, remainingData: Data)
    case tooLarge
}

struct HTTPHeaderAccumulator {
    static let maxHeaderBytes = 16 * 1024
    private static let terminator = Data([13, 10, 13, 10])
    private var buffer = Data()

    var byteCount: Int { buffer.count }

    mutating func append(_ data: Data) -> HTTPHeaderReadResult {
        buffer.append(data)
        guard buffer.count <= Self.maxHeaderBytes else { return .tooLarge }
        guard let range = buffer.range(of: Self.terminator) else { return .needMore }
        return .complete(headerData: Data(buffer[..<range.upperBound]), remainingData: Data(buffer[range.upperBound...]))
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    var contentLength: Int? {
        guard let raw = headers["content-length"], let parsed = Int(raw), parsed >= 0 else { return nil }
        return parsed
    }
    var hasValidContentLength: Bool {
        guard let raw = headers["content-length"] else { return true }
        guard let parsed = Int(raw), parsed >= 0, parsed <= 4 * 1024 else { return false }
        return true
    }

    init?(headerData: Data) {
        let text = String(decoding: headerData, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }
        let requestLine = firstLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard requestLine.count == 3,
              HTTPRequest.isValidToken(requestLine[0]),
              requestLine[1].hasPrefix("/"),
              requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0" else {
            return nil
        }

        method = requestLine[0]
        let targetParts = requestLine[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        path = targetParts.first ?? "/"
        query = targetParts.count > 1 ? HTTPRequest.parseQuery(targetParts[1]) : [:]

        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty, HTTPRequest.isValidToken(name), parsedHeaders[name] == nil else { return nil }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            parsedHeaders[name] = value
        }
        headers = parsedHeaders
    }

    private static func parseQuery(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in value.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let name = parts.first, !name.isEmpty else { continue }
            result[name] = parts.count > 1 ? parts[1] : ""
        }
        return result
    }

    private static func isValidToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~").union(.alphanumerics)
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
