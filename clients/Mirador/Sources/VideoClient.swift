import Foundation

/// Streams H.264 over the server's `/ws/video` WebSocket and feeds the decoder.
/// `URLSessionWebSocketTask` delivers one complete WebSocket message per receive, and the
/// server sends exactly one binary frame per access unit, so each `.data` is one wire frame:
/// `seq(8, BE) | captureMillis(8, BE) | flags(1) | Annex-B`.
final class VideoClient: NSObject, URLSessionWebSocketDelegate {
    private let url: URL
    private let decoder: H264Decoder
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closed = false

    /// Called on connection state changes and per-frame age (ms). Invoked on arbitrary threads.
    var onOpen: (() -> Void)?
    var onClose: ((String?) -> Void)?
    var onFrameAge: ((Double) -> Void)?

    init(url: URL, decoder: H264Decoder) {
        self.url = url
        self.decoder = decoder
    }

    func connect() {
        closed = false
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        receive()
    }

    func close() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure(let error):
                self.onClose?(error.localizedDescription)
            case .success(let message):
                if case .data(let data) = message {
                    self.handle(data)
                }
                self.receive()
            }
        }
    }

    private func handle(_ data: Data) {
        guard data.count > 17 else { return }
        let cap = Self.beUInt64(data, 8)
        let flags = data[data.startIndex + 16]
        let annexB = data.subdata(in: data.index(data.startIndex, offsetBy: 17)..<data.endIndex)
        decoder.decode(annexB: annexB, isKeyframe: (flags & 0x01) == 1)
        if cap > 0 {
            onFrameAge?(Date().timeIntervalSince1970 * 1000.0 - Double(cap))
        }
    }

    private static func beUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        let base = data.startIndex + offset
        for i in 0..<8 { v = (v << 8) | UInt64(data[base + i]) }
        return v
    }

    // MARK: URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if !closed { onClose?("closed (\(closeCode.rawValue))") }
    }
}
