import CoreGraphics
import Foundation
import Testing
@testable import Mirador

@Test func successiveClicksCarrySingleDoubleAndTripleClickState() throws {
    var factory = MouseEventFactory()
    for (time, expected) in [(10.0, Int64(1)), (10.2, 2), (10.4, 3)] {
        let events = try click(&factory, at: CGPoint(x: 200, y: 100), time: time)
        #expect(events.map { $0.getIntegerValueField(.mouseEventClickState) } == [expected, expected])
        #expect(events.map(\.type) == [.leftMouseDown, .leftMouseUp])
        #expect(events.allSatisfy { $0.location == CGPoint(x: 200, y: 100) })
    }
}

@Test func slowDistantAndDifferentButtonClicksStartNewSequences() throws {
    for (time, point, button) in [
        (10.8, CGPoint(x: 200, y: 100), CGMouseButton.left),
        (10.2, CGPoint(x: 220, y: 100), CGMouseButton.left),
        (10.2, CGPoint(x: 200, y: 100), CGMouseButton.right)
    ] {
        var factory = MouseEventFactory()
        _ = try click(&factory, at: CGPoint(x: 200, y: 100), time: 10)
        let events = try click(&factory, at: point, time: time, button: button)
        #expect(events.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 1])
        #expect(events.allSatisfy { $0.getIntegerValueField(.mouseEventButtonNumber) == Int64(button.rawValue) })
    }
}

@Test func smallPointerJitterStillAllowsDoubleClick() throws {
    var factory = MouseEventFactory()
    _ = try click(&factory, at: CGPoint(x: 200, y: 100), time: 10)
    factory.pointerMoved(to: CGPoint(x: 202, y: 101))
    let events = try click(&factory, at: CGPoint(x: 202, y: 101), time: 10.2)
    #expect(events.map { $0.getIntegerValueField(.mouseEventClickState) } == [2, 2])
}

@Test func dragReturningToStartDoesNotBecomeFirstHalfOfDoubleClick() throws {
    var factory = MouseEventFactory()
    let origin = CGPoint(x: 200, y: 100)
    _ = factory.makeEvent(type: .leftMouseDown, point: origin, button: .left,
                          flags: [], time: 10, doubleClickInterval: 0.5)
    factory.pointerMoved(to: CGPoint(x: 240, y: 100))
    factory.pointerMoved(to: origin)
    _ = factory.makeEvent(type: .leftMouseUp, point: origin, button: .left,
                          flags: [], time: 10.1, doubleClickInterval: 0.5)
    let events = try click(&factory, at: origin, time: 10.2)
    #expect(events.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 1])
}

private func click(_ factory: inout MouseEventFactory, at point: CGPoint, time: TimeInterval,
                   button: CGMouseButton = .left) throws -> [CGEvent] {
    let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
    let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
    return try [(down, time), (up, time + 0.01)].map { type, timestamp in
        let event = factory.makeEvent(type: type, point: point, button: button,
                                      flags: [], time: timestamp, doubleClickInterval: 0.5)
        return try #require(event)
    }
}
