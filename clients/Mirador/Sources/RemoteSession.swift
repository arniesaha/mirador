import SwiftUI
import AVFoundation

/// Builds the server endpoint URLs from user-entered host/port/token.
struct ServerConfig: Equatable {
    var host: String
    var port: String
    var token: String

    private var base: String { "ws://\(host):\(port)" }
    private var query: String {
        guard !token.isEmpty,
              let escaped = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return "" }
        return "?token=\(escaped)"
    }
    var videoURL: URL? { URL(string: "\(base)/ws/video\(query)") }
    var inputURL: URL? { URL(string: "\(base)/ws/input\(query)") }
    var metricsURL: URL? { URL(string: "http://\(host):\(port)/metrics\(query)") }
}

/// Orchestrates the video stream (and, in Stage 2, input) for one connection.
@MainActor
final class RemoteSession: ObservableObject {
    enum State: Equatable {
        case connecting
        case connected
        case failed(String)
    }

    @Published var state: State = .connecting
    @Published var lastFrameAgeMs: Double = 0
    @Published var lastInputLatencyMs: Double = 0
    @Published var captureFps: Double = 0
    @Published var encodeFps: Double = 0
    @Published var encodeKbitPerSec: Double = 0
    /// Native pixel size of the stream, used to map input into the letterboxed content rect.
    @Published var videoSize: CGSize = CGSize(width: 16, height: 9)

    let config: ServerConfig
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var decoder: H264Decoder?
    private var videoClient: VideoClient?
    private var inputClient: InputClient?
    private var metricsTask: Task<Void, Never>?
    private var stopped = false
    private var reconnecting = false
    private var retryDelay: TimeInterval = 0.5

    init(config: ServerConfig) {
        self.config = config
    }

    func attach(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    func start() {
        stopped = false
        connect()
    }

    private func connect() {
        reconnecting = false
        guard let url = config.videoURL else {
            state = .failed("Invalid host/port")
            return
        }
        state = .connecting
        let decoder = H264Decoder(onSample: { [weak self] sample in self?.enqueue(sample) })
        decoder.onFormat = { [weak self] size in Task { @MainActor in self?.videoSize = size } }
        self.decoder = decoder
        let client = VideoClient(url: url, decoder: decoder)
        client.onOpen = { [weak self] in Task { @MainActor in self?.handleOpen() } }
        client.onClose = { [weak self] reason in Task { @MainActor in self?.handleDrop(reason) } }
        client.onFrameAge = { [weak self] age in Task { @MainActor in self?.lastFrameAgeMs = age } }
        self.videoClient = client
        client.connect()

        if let inputURL = config.inputURL {
            let input = InputClient(url: inputURL)
            input.onLatency = { [weak self] ms in Task { @MainActor in self?.lastInputLatencyMs = ms } }
            self.inputClient = input
            input.connect()
        }
        startMetricsPolling()
    }

    func stop() {
        stopped = true
        metricsTask?.cancel(); metricsTask = nil
        teardownClients()
    }

    private func teardownClients() {
        videoClient?.close(); videoClient = nil
        inputClient?.close(); inputClient = nil
        decoder = nil
    }

    private func handleOpen() {
        retryDelay = 0.5
        state = .connected
    }

    /// On an unexpected drop, tear down and reconnect with capped backoff.
    private func handleDrop(_ reason: String?) {
        guard !stopped, !reconnecting else { return }
        reconnecting = true
        state = .failed(reason ?? "Disconnected")
        teardownClients()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 5)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if !self.stopped { self.connect() }
        }
    }

    private func startMetricsPolling() {
        metricsTask?.cancel()
        guard let url = config.metricsURL else { return }
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                if let (data, _) = try? await URLSession.shared.data(from: url),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    await MainActor.run {
                        guard let self else { return }
                        self.captureFps = (obj["fps"] as? NSNumber)?.doubleValue ?? 0
                        self.encodeFps = (obj["encodeFps"] as? NSNumber)?.doubleValue ?? 0
                        self.encodeKbitPerSec = ((obj["encodeBitrateBitsPerSec"] as? NSNumber)?.doubleValue ?? 0) / 1000
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - Input helpers (called from the input capture view on the main thread)

    func sendPointer(_ type: String, x: Double, y: Double, button: Int = 0, buttons: Int = 0) {
        inputClient?.send(["type": type, "x": x, "y": y, "button": button, "buttons": buttons])
    }

    func sendScroll(x: Double, y: Double, deltaX: Double, deltaY: Double) {
        inputClient?.send(["type": "scroll", "x": x, "y": y, "deltaX": deltaX, "deltaY": deltaY])
    }

    func sendKey(down: Bool, code: String, shift: Bool, control: Bool, option: Bool, command: Bool) {
        inputClient?.send([
            "type": down ? "keyDown" : "keyUp", "code": code,
            "shiftKey": shift, "ctrlKey": control, "altKey": option, "metaKey": command
        ])
    }

    func sendText(_ text: String) {
        inputClient?.send(["type": "text", "text": text])
    }

    /// Called off the main thread by the decoder; hop to main to touch the layer.
    nonisolated private func enqueue(_ sample: CMSampleBuffer) {
        Task { @MainActor in
            guard let layer = self.displayLayer else { return }
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sample)
        }
    }
}
