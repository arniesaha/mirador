import Foundation
import Testing
@testable import Mirador

@Test func viewerHTMLContainsExpectedElements() async throws {
    let hostileHost = "127.0.0.1\" onerror=\"alert(1)"
    let html = ViewerHTML.render(host: hostileHost, port: 8787)
    #expect(html.contains("mirador viewer"))
    #expect(html.contains("/metrics"))
    #expect(html.contains("/stream.mjpg"))
    #expect(html.contains("/input"))
    #expect(html.contains("input-overlay"))
    #expect(!html.contains(hostileHost))
}

@Test func viewerAssetsRenderHTMLFromDiskAndInjectToken() async throws {
    let root = try makeTemporaryDirectory()
    try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
    let template = """
    <html><body>
    <img src="/stream.mjpg?token={{AUTH_TOKEN_QUERY}}">
    <script>const authToken = '{{AUTH_TOKEN_JS}}';</script>
    </body></html>
    """
    try template.write(to: root.appendingPathComponent("viewer.html"), atomically: true, encoding: .utf8)

    let assets = ViewerAssets(rootDirectory: root)
    let html = try #require(assets.renderHTML(authToken: "tok'en value"))

    #expect(html.contains("token=tok%27en%20value"))
    #expect(html.contains("const authToken = 'tok\\'en value'"))
}

@Test func viewerAssetsServeOnlyKnownAssetPaths() async throws {
    let root = try makeTemporaryDirectory()
    let assetsDir = root.appendingPathComponent("assets")
    try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
    try "body{}".write(to: assetsDir.appendingPathComponent("viewer.css"), atomically: true, encoding: .utf8)
    try "console.log('ok')".write(to: assetsDir.appendingPathComponent("viewer.js"), atomically: true, encoding: .utf8)

    let assets = ViewerAssets(rootDirectory: root)
    let css = try #require(assets.staticAsset(for: "/assets/viewer.css"))
    let js = try #require(assets.staticAsset(for: "/assets/viewer.js"))

    #expect(css.contentType == "text/css; charset=utf-8")
    #expect(String(decoding: css.data, as: UTF8.self) == "body{}")
    #expect(js.contentType == "application/javascript; charset=utf-8")
    #expect(assets.staticAsset(for: "/assets/../viewer.html") == nil)
    #expect(assets.staticAsset(for: "/assets/unknown.js") == nil)
}

@Test func viewerHTMLCapturesKeyboardAndImageContentCoordinates() async throws {
    let html = renderedViewerBundle(authToken: "secret-token")

    #expect(html.contains("tabindex=\"0\""))
    #expect(html.contains("imageContentRect"))
    #expect(html.contains("keydown"))
    #expect(html.contains("keyup"))
    #expect(html.contains("wheel"))
    #expect(html.contains("requestAnimationFrame"))
    #expect(html.contains("secret-token"))
    #expect(html.contains("X-Mirador-Token"))
    #expect(html.contains("keyboard-capture"))
    #expect(html.contains("beforeinput"))
    #expect(html.contains("type: 'text'"))
    #expect(html.contains("isPrintableTextKey"))
}

@Test func viewerHTMLFitsRemoteScreenInsideDynamicViewport() async throws {
    let html = renderedViewerBundle(authToken: "secret-token")

    #expect(html.contains("height: 100dvh"))
    #expect(html.contains("display: flex"))
    #expect(html.contains("flex: 1 1 auto"))
    #expect(html.contains("min-height: 0"))
    #expect(html.contains("object-fit: contain"))
}

@Test func viewerHTMLSupportsTouchFirstMobileControls() async throws {
    let html = renderedViewerBundle(authToken: "secret-token")

    #expect(html.contains("mobile-controls"))
    #expect(html.contains("keyboard-button"))
    #expect(html.contains("touchstart"))
    #expect(html.contains("touchmove"))
    #expect(html.contains("touchend"))
    #expect(html.contains("handleTouchStart"))
    #expect(html.contains("handleTouchMove"))
    #expect(html.contains("handleTouchEnd"))
    #expect(html.contains("twoFingerScrollState"))
    #expect(html.contains("sendTouchTap"))
    #expect(html.contains("sendTouchDragMove"))
    #expect(html.contains("env(safe-area-inset-bottom)"))
}

@Test func viewerInjectsTokenViaHTMLGlobalNotStaticJS() async throws {
    // viewer.js is served raw (no template substitution), so the token must come from
    // an HTML-injected global. A leftover {{...}} placeholder in a static asset would
    // never be substituted and would make every token-authed request 401 in a browser.
    let assets = ViewerAssets.default
    let html = try #require(assets.renderHTML(authToken: "secret-token"))
    let js = String(decoding: try #require(assets.staticAsset(for: "/assets/viewer.js")).data, as: UTF8.self)

    #expect(html.contains("__MIRADOR_TOKEN__ = 'secret-token'"))
    #expect(js.contains("window.__MIRADOR_TOKEN__"))
    #expect(!js.contains("{{AUTH_TOKEN_JS}}"))
    #expect(!js.contains("{{AUTH_TOKEN_QUERY}}"))
}

@Test func viewerHTMLTokenizesAuthGatedAssetURLs() async throws {
    // /assets/* require the capability token, so the page must reference them with it,
    // otherwise the browser's tokenless subresource loads 401 and viewer.js never runs.
    let html = try #require(ViewerAssets.default.renderHTML(authToken: "secret-token"))

    #expect(html.contains("/assets/viewer.css?v=h264-4&token=secret-token"))
    #expect(html.contains("/assets/viewer.js?v=h264-4&token=secret-token"))
}

@Test func viewerUsesWebSocketInputTransportWithHTTPFallback() async throws {
    let html = renderedViewerBundle(authToken: "secret-token")

    // Persistent transport wired up.
    #expect(html.contains("WebSocket"))
    #expect(html.contains("/ws/input"))
    #expect(html.contains("sendInput"))
    #expect(html.contains("connectInputSocket"))
    #expect(html.contains("transport-status"))
    #expect(html.contains("payload.seq"))
    // HTTP /input retained as the diagnostic fallback.
    #expect(html.contains("postInput"))
    #expect(html.contains("'/input'"))
}

@Test func metricsJSONContainsRSSField() async throws {
    let snapshot = MetricsSnapshot(rssBytes: 1234, activeStreams: 0, fps: 0, droppedFrames: 2)
    let json = HTTPResponses.metricsJSON(snapshot)
    #expect(json.contains("\"rssBytes\":1234"))
    #expect(json.contains("\"droppedFrames\":2"))
}

@Test func metricsJSONIncludesInputTransportFields() async throws {
    let snapshot = MetricsSnapshot(rssBytes: 1234, activeStreams: 0, fps: 0, droppedFrames: 0, inputSockets: 2, inputEvents: 17)
    let json = HTTPResponses.metricsJSON(snapshot)

    #expect(json.contains("\"inputSockets\":2"))
    #expect(json.contains("\"inputEvents\":17"))
}

@Test func metricsJSONIncludesPerformanceFields() async throws {
    let snapshot = MetricsSnapshot(rssBytes: 1, activeStreams: 0, fps: 12.5, droppedFrames: 0, bitrateBitsPerSec: 800000, incompleteFrames: 3, inputDispatchMillis: 1.5)
    let json = HTTPResponses.metricsJSON(snapshot)

    #expect(json.contains("\"fps\":12.5"))
    #expect(json.contains("\"bitrateBitsPerSec\":800000"))
    #expect(json.contains("\"incompleteFrames\":3"))
    #expect(json.contains("\"inputDispatchMillis\":1.5"))
}

@Test func metricsJSONSanitizesNonFinitePerformanceFields() async throws {
    let snapshot = MetricsSnapshot(rssBytes: 1, activeStreams: 0, fps: .nan, droppedFrames: 0, bitrateBitsPerSec: .infinity, incompleteFrames: 0, inputDispatchMillis: .nan)
    let json = HTTPResponses.metricsJSON(snapshot)

    #expect(json.contains("\"bitrateBitsPerSec\":0"))
    #expect(json.contains("\"inputDispatchMillis\":0"))
    #expect(!json.contains("NaN"))
    #expect(!json.contains("Infinity"))
}

@Test func viewerMetricsLineShowsPerformanceFields() async throws {
    let html = renderedViewerBundle(authToken: "secret-token")

    #expect(html.contains("kbit/s"))
    #expect(html.contains("dispatch="))
    #expect(html.contains("bitrateBitsPerSec"))
    #expect(html.contains("inputDispatchMillis"))
}

@Test func metricsJSONIncludesEncodeFields() async throws {
    let snapshot = MetricsSnapshot(rssBytes: 1, activeStreams: 1, fps: 30, droppedFrames: 0, encodeFps: 29.5, encodeBitrateBitsPerSec: 1_500_000, encodeMillis: 4.2, keyframeIntervalFrames: 60, videoStreams: 1)
    let json = HTTPResponses.metricsJSON(snapshot)

    #expect(json.contains("\"encodeFps\":29.5"))
    #expect(json.contains("\"encodeBitrateBitsPerSec\":1500000"))
    #expect(json.contains("\"encodeMillis\":4.2"))
    #expect(json.contains("\"keyframeIntervalFrames\":60"))
    #expect(json.contains("\"videoStreams\":1"))
}

@Test func metricsJSONSanitizesNonFiniteEncodeFields() async throws {
    let snapshot = MetricsSnapshot(rssBytes: 1, activeStreams: 0, fps: 0, droppedFrames: 0, encodeFps: .nan, encodeBitrateBitsPerSec: .infinity, encodeMillis: .nan, keyframeIntervalFrames: .infinity)
    let json = HTTPResponses.metricsJSON(snapshot)

    #expect(json.contains("\"encodeFps\":0"))
    #expect(json.contains("\"encodeBitrateBitsPerSec\":0"))
    #expect(json.contains("\"encodeMillis\":0"))
    #expect(json.contains("\"keyframeIntervalFrames\":0"))
    #expect(!json.contains("NaN"))
    #expect(!json.contains("Infinity"))
}

@Test func viewerUsesWebCodecsVideoPathWithMJPEGFallback() async throws {
    let html = renderedViewerBundle(authToken: "secret-token")

    // H.264/WebCodecs path wired up.
    #expect(html.contains("/ws/video"))
    #expect(html.contains("VideoDecoder"))
    #expect(html.contains("EncodedVideoChunk"))
    #expect(html.contains("connectVideoSocket"))
    #expect(html.contains("avcCodecFromAnnexB"))
    #expect(html.contains("id=\"video\""))
    // MJPEG retained as the fallback surface.
    #expect(html.contains("webCodecsSupported"))
    #expect(html.contains("mjpeg"))
    // Encode metrics surfaced.
    #expect(html.contains("encodeFps"))
    #expect(html.contains("encodeMillis"))
}

@Test func metricsJSONSanitizesNaNFPS() async throws {
    let snapshot = MetricsSnapshot(rssBytes: 1234, activeStreams: 1, fps: .nan, droppedFrames: 2)
    let json = HTTPResponses.metricsJSON(snapshot)

    #expect(json.contains("\"fps\":0"))
    #expect(!json.contains("NaN"))
    #expect(!json.contains("Infinity"))
}

@Test func metricsJSONSanitizesInfiniteFPS() async throws {
    let snapshot = MetricsSnapshot(rssBytes: 1234, activeStreams: 1, fps: .infinity, droppedFrames: 2)
    let json = HTTPResponses.metricsJSON(snapshot)

    #expect(json.contains("\"fps\":0"))
    #expect(!json.contains("NaN"))
    #expect(!json.contains("Infinity"))
}

@Test func shutdownContinuationResumesExactlyOnce() async throws {
    let cleanupCount = LockedCounter()

    let result: ShutdownSignal = await withCheckedContinuation { continuation in
        let oneShot = OneShotContinuation(continuation)
        oneShot.setCleanup {
            cleanupCount.increment()
        }

        #expect(oneShot.resume(returning: ShutdownSignal.interrupt))
        #expect(!oneShot.resume(returning: ShutdownSignal.terminate))
    }

    #expect(result == .interrupt)
    #expect(cleanupCount.value == 1)
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

@Test func httpRequestParsesValidRequest() async throws {
    let data = Data("GET /metrics?x=1&token=abc HTTP/1.1\r\nHost: 127.0.0.1:8787\r\n\r\n".utf8)
    let request = try #require(HTTPRequest(headerData: data))

    #expect(request.method == "GET")
    #expect(request.path == "/metrics")
    #expect(request.query["x"] == "1")
    #expect(request.query["token"] == "abc")
    #expect(request.headers["host"] == "127.0.0.1:8787")
}

@Test func httpRequestRejectsNegativeContentLength() async throws {
    let data = Data("POST /input HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)
    let request = try #require(HTTPRequest(headerData: data))

    #expect(request.contentLength == nil)
    #expect(!request.hasValidContentLength)
}

@Test func httpRequestRejectsDuplicateContentLength() async throws {
    let data = Data("POST /input HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n".utf8)

    #expect(HTTPRequest(headerData: data) == nil)
}

@Test func authValidationRequiresCapabilityToken() async throws {
    let authed = try #require(HTTPRequest(headerData: Data("GET /?token=secret HTTP/1.1\r\nHost: test\r\n\r\n".utf8)))
    let wrong = try #require(HTTPRequest(headerData: Data("GET /?token=wrong HTTP/1.1\r\nHost: test\r\n\r\n".utf8)))
    let header = try #require(HTTPRequest(headerData: Data("POST /input HTTP/1.1\r\nHost: test\r\nX-Mirador-Token: secret\r\nContent-Length: 2\r\n\r\n".utf8)))

    #expect(HTTPServer.isAuthorized(authed, token: "secret"))
    #expect(HTTPServer.isAuthorized(header, token: "secret"))
    #expect(!HTTPServer.isAuthorized(wrong, token: "secret"))
}

@Test func httpRequestRejectsMalformedRequestLines() async throws {
    let malformed = [
        "\r\n",
        "GET\r\n\r\n",
        "GET /\r\n\r\n",
        "GET / FTP/1.0\r\n\r\n",
        "GET http://example.com/ HTTP/1.1\r\n\r\n",
        "GE T / HTTP/1.1\r\n\r\n"
    ]

    for raw in malformed {
        #expect(HTTPRequest(headerData: Data(raw.utf8)) == nil)
    }
}

@Test func httpRequestAcceptsUnsupportedButValidMethodForRouting() async throws {
    let request = try #require(HTTPRequest(headerData: Data("POST / HTTP/1.1\r\n\r\n".utf8)))
    #expect(request.method == "POST")
    #expect(request.path == "/")
}

@Test func httpHeaderAccumulatorHandlesSplitHeaders() async throws {
    var accumulator = HTTPHeaderAccumulator()

    #expect(accumulator.append(Data("GET / HTTP/1.1\r\nHo".utf8)) == .needMore)
    let result = accumulator.append(Data("st: example\r\n\r\nignored-body".utf8))

    guard case .complete(let data, let remainingData) = result else {
        Issue.record("expected complete header")
        return
    }
    #expect(String(decoding: data, as: UTF8.self) == "GET / HTTP/1.1\r\nHost: example\r\n\r\n")
    #expect(remainingData == Data("ignored-body".utf8))
}

@Test func httpHeaderAccumulatorRejectsOversizedHeaders() async throws {
    var accumulator = HTTPHeaderAccumulator()
    let oversized = Data(repeating: UInt8(ascii: "a"), count: HTTPHeaderAccumulator.maxHeaderBytes + 1)

    #expect(accumulator.append(oversized) == .tooLarge)
}

private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mirador-tests")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func renderedViewerBundle(authToken: String) -> String {
    let assets = ViewerAssets.default
    let html = assets.renderHTML(authToken: authToken) ?? ViewerHTML.render(host: "127.0.0.1", port: 8787, authToken: authToken)
    let css = assets.staticAsset(for: "/assets/viewer.css").map { String(decoding: $0.data, as: UTF8.self) } ?? ""
    let js = assets.staticAsset(for: "/assets/viewer.js").map { String(decoding: $0.data, as: UTF8.self) } ?? ""
    return [html, css, js].joined(separator: "\n")
}
