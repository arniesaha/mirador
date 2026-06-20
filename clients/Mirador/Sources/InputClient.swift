import Foundation
import QuartzCore

/// Sends input events over the server's `/ws/input` WebSocket as JSON text, attaching a `seq` so
/// the server's `{"type":"ack","seq":N,"ok":bool}` reply yields a round-trip latency reading.
final class InputClient: NSObject, URLSessionWebSocketDelegate {
    private let url: URL
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closed = false

    private let lock = NSLock()
    private var seq: UInt64 = 0
    private var pending: [UInt64: CFTimeInterval] = [:]

    var onLatency: ((Double) -> Void)?
    var onOpen: (() -> Void)?
    var onClose: ((String?) -> Void)?

    init(url: URL) { self.url = url }

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

    /// Send one event. `event` is the JSON object minus `seq`, which is added here.
    func send(_ event: [String: Any]) {
        guard let task else { return }
        lock.lock()
        seq &+= 1
        let s = seq
        pending[s] = CACurrentMediaTime()
        if pending.count > 512 { pending.removeValue(forKey: pending.keys.min() ?? s) }
        lock.unlock()

        var payload = event
        payload["seq"] = s
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        task.send(.string(json)) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure(let error):
                self.onClose?(error.localizedDescription)
            case .success(let message):
                if case .string(let text) = message { self.handleAck(text) }
                self.receive()
            }
        }
    }

    private func handleAck(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "ack",
              let seq = (obj["seq"] as? NSNumber)?.uint64Value else { return }
        lock.lock()
        let sentAt = pending.removeValue(forKey: seq)
        lock.unlock()
        if let sentAt {
            onLatency?((CACurrentMediaTime() - sentAt) * 1000.0)
        }
    }

    // MARK: URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        onOpen?()
    }
}
