import Foundation
import Testing
@testable import Mirador

@Test func inputEventParsesClickJSON() throws {
    let json = Data(#"{"type":"click","x":0.25,"y":0.75}"#.utf8)
    let event = try InputEvent(jsonData: json)

    #expect(event.type == .click)
    #expect(event.x == 0.25)
    #expect(event.y == 0.75)
}

@Test func inputEventDecodeReturnsSequenceNumber() throws {
    let json = Data(#"{"type":"pointerMove","x":0.5,"y":0.5,"buttons":1,"seq":42}"#.utf8)
    let decoded = try InputEvent.decode(jsonData: json)

    #expect(decoded.event.type == .pointerMove)
    #expect(decoded.seq == 42)
}

@Test func inputEventDecodeWithoutSequenceNumberIsNil() throws {
    let json = Data(#"{"type":"click","x":0.5,"y":0.5}"#.utf8)
    let decoded = try InputEvent.decode(jsonData: json)

    #expect(decoded.event.type == .click)
    #expect(decoded.seq == nil)
}

@Test func inputEventRejectsOutOfRangeCoordinates() throws {
    let json = Data(#"{"type":"move","x":1.25,"y":0.5}"#.utf8)

    #expect(throws: InputEventError.self) {
        _ = try InputEvent(jsonData: json)
    }
}

@Test func inputEventMapsNormalizedCoordinatesToScreenPoint() throws {
    let event = try InputEvent(jsonData: Data(#"{"type":"click","x":0.5,"y":0.25}"#.utf8))
    let point = event.point(in: CGRect(x: 100, y: 200, width: 800, height: 600))

    #expect(point.x == 500)
    #expect(point.y == 350)
}

@Test func inputEventParsesPointerDownWithButtonState() throws {
    let json = Data(#"{"type":"pointerDown","x":0.1,"y":0.2,"button":0,"buttons":1,"shiftKey":true}"#.utf8)
    let event = try InputEvent(jsonData: json)

    #expect(event.type == .pointerDown)
    #expect(event.x == 0.1)
    #expect(event.y == 0.2)
    #expect(event.button == 0)
    #expect(event.buttons == 1)
    #expect(event.modifiers.shift)
}

@Test func inputEventParsesScrollDeltaWithoutButton() throws {
    let json = Data(#"{"type":"scroll","x":0.4,"y":0.6,"deltaX":12.5,"deltaY":-42}"#.utf8)
    let event = try InputEvent(jsonData: json)

    #expect(event.type == .scroll)
    #expect(event.deltaX == 12.5)
    #expect(event.deltaY == -42)
}

@Test func inputEventRejectsOversizedFiniteScrollDelta() throws {
    let json = Data(#"{"type":"scroll","x":0.4,"y":0.6,"deltaX":1e20,"deltaY":0}"#.utf8)

    #expect(throws: InputEventError.self) {
        _ = try InputEvent(jsonData: json)
    }
}

@Test func inputEventParsesKeyboardEventsWithoutCoordinates() throws {
    let json = Data(#"{"type":"keyDown","key":"a","code":"KeyA","repeat":false,"metaKey":true}"#.utf8)
    let event = try InputEvent(jsonData: json)

    #expect(event.type == .keyDown)
    #expect(event.x == nil)
    #expect(event.y == nil)
    #expect(event.key == "a")
    #expect(event.code == "KeyA")
    #expect(event.`repeat` == false)
    #expect(event.modifiers.command)
}

@Test func inputEventRejectsPointerEventsWithoutCoordinates() throws {
    let json = Data(#"{"type":"pointerMove"}"#.utf8)

    #expect(throws: InputEventError.self) {
        _ = try InputEvent(jsonData: json)
    }
}

@Test func keyCodeMapperHandlesCommonMagicKeyboardKeys() throws {
    #expect(MacKeyCodeMapper.keyCode(for: "KeyA", key: "a") == 0)
    #expect(MacKeyCodeMapper.keyCode(for: "Digit1", key: "1") == 18)
    #expect(MacKeyCodeMapper.keyCode(for: "Enter", key: "Enter") == 36)
    #expect(MacKeyCodeMapper.keyCode(for: "ArrowLeft", key: "ArrowLeft") == 123)
}

@Test func httpHeaderAccumulatorReturnsRemainingBodyBytes() throws {
    var accumulator = HTTPHeaderAccumulator()
    let request = Data("POST /input HTTP/1.1\r\nHost: test\r\nContent-Length: 2\r\n\r\n{}".utf8)

    switch accumulator.append(request) {
    case .complete(let headerData, let remainingData):
        #expect(String(decoding: headerData, as: UTF8.self).contains("POST /input HTTP/1.1"))
        #expect(remainingData == Data("{}".utf8))
    default:
        Issue.record("Expected complete header with remaining body bytes")
    }
}
