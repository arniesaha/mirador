import CoreGraphics
import Foundation

/// Builds mouse events before they are posted to the desktop.
struct MouseEventFactory {
    private struct Click {
        let button: CGMouseButton
        let point: CGPoint
        let time: TimeInterval
        let count: Int64
        var moved = false
    }

    private var previousClick: Click?
    private var pressedClick: Click?
    private static let movementTolerance: CGFloat = 4

    mutating func makeEvent(type: CGEventType, point: CGPoint, button: CGMouseButton,
                            flags: CGEventFlags, time: TimeInterval,
                            doubleClickInterval: TimeInterval) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return nil }
        let count: Int64
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if let previous = previousClick,
               previous.button == button,
               time >= previous.time, time - previous.time <= doubleClickInterval,
               Self.isNear(point, previous.point) {
                count = previous.count + 1
            } else {
                count = 1
            }
            pressedClick = Click(button: button, point: point, time: time, count: count)
            previousClick = nil
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if let pressed = pressedClick, pressed.button == button {
                count = pressed.count
                // A drag or a long hold must not seed the next double-click sequence.
                previousClick = !pressed.moved && Self.isNear(point, pressed.point)
                    && time >= pressed.time && time - pressed.time <= doubleClickInterval ? pressed : nil
            } else {
                count = 1
                previousClick = nil
            }
            pressedClick = nil
        default:
            count = 0
        }
        event.flags = flags
        // CGEvent does not infer multi-clicks from separately injected down/up events.
        // Both halves must carry the same count for Finder and AppKit controls.
        event.setIntegerValueField(.mouseEventClickState, value: count)
        return event
    }

    mutating func pointerMoved(to point: CGPoint) {
        if let pressed = pressedClick, !Self.isNear(point, pressed.point) {
            pressedClick?.moved = true
        }
        if let previous = previousClick, !Self.isNear(point, previous.point) {
            previousClick = nil
        }
    }

    private static func isNear(_ a: CGPoint, _ b: CGPoint) -> Bool {
        hypot(a.x - b.x, a.y - b.y) <= movementTolerance
    }
}
