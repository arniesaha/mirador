import Foundation
import Testing
@testable import Mirador

@Test func webSocketAcceptKeyMatchesRFC6455Sample() async throws {
    // RFC 6455 §1.3 worked example.
    #expect(WebSocketHandshake.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
}

@Test func webSocketUpgradeRequestDetection() async throws {
    let upgrade = try #require(HTTPRequest(headerData: Data("GET /ws/input HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: abc\r\n\r\n".utf8)))
    let plain = try #require(HTTPRequest(headerData: Data("GET /ws/input HTTP/1.1\r\nHost: t\r\n\r\n".utf8)))
    let noKey = try #require(HTTPRequest(headerData: Data("GET /ws/input HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".utf8)))

    #expect(WebSocketHandshake.isUpgradeRequest(upgrade))
    #expect(!WebSocketHandshake.isUpgradeRequest(plain))
    #expect(!WebSocketHandshake.isUpgradeRequest(noKey))
}

/// Builds a masked client text frame as a browser would send it.
private func maskedClientTextFrame(_ text: String, mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]) -> Data {
    let payload = Array(text.utf8)
    var frame: [UInt8] = [0x81] // FIN + text
    let length = payload.count
    if length < 126 {
        frame.append(0x80 | UInt8(length))
    } else {
        frame.append(0x80 | 126)
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
    }
    frame.append(contentsOf: mask)
    for (index, byte) in payload.enumerated() {
        frame.append(byte ^ mask[index % 4])
    }
    return Data(frame)
}

@Test func webSocketDecoderUnmasksTextFrame() async throws {
    var decoder = WebSocketFrameDecoder()
    decoder.append(maskedClientTextFrame("{\"type\":\"pointerMove\"}"))

    guard case .frame(let frame) = decoder.next() else {
        Issue.record("expected a decoded frame")
        return
    }
    #expect(frame.opcode == .text)
    #expect(frame.fin)
    #expect(String(decoding: frame.payload, as: UTF8.self) == "{\"type\":\"pointerMove\"}")
    #expect(decoder.next() == .needMore)
}

@Test func webSocketDecoderHandlesMultipleFramesInOneBuffer() async throws {
    var decoder = WebSocketFrameDecoder()
    var buffer = maskedClientTextFrame("one")
    buffer.append(maskedClientTextFrame("two"))
    decoder.append(buffer)

    guard case .frame(let first) = decoder.next(), case .frame(let second) = decoder.next() else {
        Issue.record("expected two frames")
        return
    }
    #expect(String(decoding: first.payload, as: UTF8.self) == "one")
    #expect(String(decoding: second.payload, as: UTF8.self) == "two")
    #expect(decoder.next() == .needMore)
}

@Test func webSocketDecoderNeedsMoreForPartialFrame() async throws {
    let full = maskedClientTextFrame("partial-frame-data")
    var decoder = WebSocketFrameDecoder()
    decoder.append(full.prefix(4))
    #expect(decoder.next() == .needMore)

    decoder.append(full.suffix(from: full.index(full.startIndex, offsetBy: 4)))
    guard case .frame(let frame) = decoder.next() else {
        Issue.record("expected a completed frame after the rest arrived")
        return
    }
    #expect(String(decoding: frame.payload, as: UTF8.self) == "partial-frame-data")
}

@Test func webSocketDecoderRejectsUnmaskedClientFrame() async throws {
    // FIN + text, mask bit clear, zero-length payload.
    var decoder = WebSocketFrameDecoder()
    decoder.append(Data([0x81, 0x00]))
    #expect(decoder.next() == .protocolError)
}

@Test func webSocketDecoderRejectsOversizedFrame() async throws {
    // 64-bit length header claiming more than the payload cap.
    var header: [UInt8] = [0x81, 0x80 | 127]
    let huge = UInt64(WebSocketFrameDecoder.maxPayloadBytes) + 1
    for shift in stride(from: 56, through: 0, by: -8) {
        header.append(UInt8((huge >> UInt64(shift)) & 0xFF))
    }
    header.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // mask key
    var decoder = WebSocketFrameDecoder()
    decoder.append(Data(header))
    #expect(decoder.next() == .protocolError)
}

@Test func webSocketDecoderRecognizesPing() async throws {
    var frame: [UInt8] = [0x89, 0x80] // FIN + ping, masked, zero length
    frame.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
    var decoder = WebSocketFrameDecoder()
    decoder.append(Data(frame))

    guard case .frame(let decoded) = decoder.next() else {
        Issue.record("expected a ping frame")
        return
    }
    #expect(decoded.opcode == .ping)
}

@Test func webSocketEncoderWritesUnmaskedShortFrame() async throws {
    let encoded = WebSocketEncoder.text("hi")
    #expect(encoded[0] == 0x81)          // FIN + text
    #expect(encoded[1] == 0x02)          // unmasked, length 2
    #expect(Array(encoded.suffix(2)) == Array("hi".utf8))
}

@Test func webSocketEncoderUsesExtendedLengthAt126() async throws {
    let payload = String(repeating: "x", count: 200)
    let encoded = WebSocketEncoder.text(payload)
    #expect(encoded[0] == 0x81)
    #expect(encoded[1] == 126)           // 16-bit extended length marker
    #expect(Int(encoded[2]) << 8 | Int(encoded[3]) == 200)
    #expect(encoded.count == 4 + 200)
}

@Test func webSocketEncoderBuildsCloseFrame() async throws {
    let encoded = WebSocketEncoder.close(code: 1002)
    #expect(encoded[0] == 0x88)          // FIN + close
    #expect(encoded[1] == 0x02)          // length 2, unmasked
    #expect(Int(encoded[2]) << 8 | Int(encoded[3]) == 1002)
}
