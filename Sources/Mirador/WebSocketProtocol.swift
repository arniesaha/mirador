import Foundation
import CryptoKit

/// RFC 6455 WebSocket opcodes used by the input channel.
public enum WebSocketOpcode: UInt8, Equatable, Sendable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

/// A fully decoded inbound WebSocket frame (payload already unmasked).
public struct WebSocketFrame: Equatable, Sendable {
    public let opcode: WebSocketOpcode
    public let payload: Data
    public let fin: Bool

    public init(opcode: WebSocketOpcode, payload: Data, fin: Bool) {
        self.opcode = opcode
        self.payload = payload
        self.fin = fin
    }
}

public enum WebSocketHandshake {
    /// RFC 6455 magic GUID appended to the client key before hashing.
    static let acceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// `Sec-WebSocket-Accept` value: base64(SHA1(clientKey + GUID)).
    public static func acceptKey(for clientKey: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((clientKey + acceptGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    /// True when the request is a well-formed WebSocket upgrade with a key.
    static func isUpgradeRequest(_ request: HTTPRequest) -> Bool {
        guard request.method.uppercased() == "GET" else { return false }
        guard request.headers["upgrade"]?.lowercased() == "websocket" else { return false }
        guard let connection = request.headers["connection"]?.lowercased(), connection.contains("upgrade") else { return false }
        guard let key = request.headers["sec-websocket-key"], !key.isEmpty else { return false }
        return true
    }
}

/// Outcome of attempting to pull the next frame off an inbound byte buffer.
public enum WebSocketDecodeResult: Equatable {
    case frame(WebSocketFrame)
    case needMore
    case protocolError
}

/// Incremental decoder for client → server frames. Accumulates raw TCP bytes and
/// yields complete, unmasked frames. Mirrors the streaming style of
/// `HTTPHeaderAccumulator`: feed bytes with `append`, then drain with `next`.
public struct WebSocketFrameDecoder: Sendable {
    /// Hard cap on a single frame payload to bound memory from a hostile peer.
    public static let maxPayloadBytes = 16 * 1024

    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func next() -> WebSocketDecodeResult {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return .needMore }

        let first = bytes[0]
        guard first & 0x70 == 0 else { return .protocolError } // reserved bits must be clear
        let fin = (first & 0x80) != 0
        guard let opcode = WebSocketOpcode(rawValue: first & 0x0F) else { return .protocolError }

        let second = bytes[1]
        // Client frames MUST be masked (RFC 6455 §5.1).
        guard second & 0x80 != 0 else { return .protocolError }

        var payloadLength = Int(second & 0x7F)
        var offset = 2
        if payloadLength == 126 {
            guard bytes.count >= offset + 2 else { return .needMore }
            payloadLength = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
        } else if payloadLength == 127 {
            guard bytes.count >= offset + 8 else { return .needMore }
            var length: UInt64 = 0
            for index in 0..<8 { length = (length << 8) | UInt64(bytes[offset + index]) }
            guard length <= UInt64(Self.maxPayloadBytes) else { return .protocolError }
            payloadLength = Int(length)
            offset += 8
        }

        // Control frames must be short and unfragmented.
        if opcode == .close || opcode == .ping || opcode == .pong {
            guard payloadLength <= 125, fin else { return .protocolError }
        }
        guard payloadLength <= Self.maxPayloadBytes else { return .protocolError }

        let maskOffset = offset
        guard bytes.count >= maskOffset + 4 else { return .needMore }
        let mask = Array(bytes[maskOffset..<maskOffset + 4])
        let payloadStart = maskOffset + 4
        guard bytes.count >= payloadStart + payloadLength else { return .needMore }

        var payload = [UInt8](repeating: 0, count: payloadLength)
        for index in 0..<payloadLength {
            payload[index] = bytes[payloadStart + index] ^ mask[index % 4]
        }

        let consumed = payloadStart + payloadLength
        buffer = Data(bytes[consumed...])
        return .frame(WebSocketFrame(opcode: opcode, payload: Data(payload), fin: fin))
    }
}

/// Encoders for server → client frames. Server frames are never masked.
public enum WebSocketEncoder {
    public static func encode(opcode: WebSocketOpcode, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode.rawValue) // FIN set, single frame
        let length = payload.count
        if length < 126 {
            frame.append(UInt8(length))
        } else if length <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            var remaining = UInt64(length)
            var lengthBytes = [UInt8](repeating: 0, count: 8)
            for index in (0..<8).reversed() {
                lengthBytes[index] = UInt8(remaining & 0xFF)
                remaining >>= 8
            }
            frame.append(contentsOf: lengthBytes)
        }
        frame.append(payload)
        return frame
    }

    public static func text(_ string: String) -> Data {
        encode(opcode: .text, payload: Data(string.utf8))
    }

    public static func pong(_ payload: Data) -> Data {
        encode(opcode: .pong, payload: payload)
    }

    public static func close(code: UInt16 = 1000) -> Data {
        var payload = Data()
        payload.append(UInt8((code >> 8) & 0xFF))
        payload.append(UInt8(code & 0xFF))
        return encode(opcode: .close, payload: payload)
    }
}
