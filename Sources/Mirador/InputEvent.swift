import Foundation
import CoreGraphics
import ApplicationServices

public struct InputEvent: Equatable, Sendable {
    public enum EventType: String, Codable, Sendable {
        case move
        case click
        case pointerMove
        case pointerDown
        case pointerUp
        case scroll
        case keyDown
        case keyUp
        case text

        var requiresCoordinates: Bool {
            switch self {
            case .move, .click, .pointerMove, .pointerDown, .pointerUp, .scroll:
                return true
            case .keyDown, .keyUp, .text:
                return false
            }
        }
    }

    public let type: EventType
    public let x: Double?
    public let y: Double?
    public let button: Int?
    public let buttons: Int?
    public let deltaX: Double?
    public let deltaY: Double?
    public let key: String?
    public let code: String?
    public let `repeat`: Bool?
    public let text: String?
    public let modifiers: InputModifiers

    public init(
        type: EventType,
        x: Double? = nil,
        y: Double? = nil,
        button: Int? = nil,
        buttons: Int? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        key: String? = nil,
        code: String? = nil,
        repeat: Bool? = nil,
        text: String? = nil,
        modifiers: InputModifiers = InputModifiers()
    ) throws {
        if type.requiresCoordinates {
            guard let x, let y, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                throw InputEventError.invalidCoordinates
            }
        }
        if let x, (!x.isFinite || !(0...1).contains(x)) { throw InputEventError.invalidCoordinates }
        if let y, (!y.isFinite || !(0...1).contains(y)) { throw InputEventError.invalidCoordinates }
        if let deltaX, !Self.isValidScrollDelta(deltaX) { throw InputEventError.invalidDelta }
        if let deltaY, !Self.isValidScrollDelta(deltaY) { throw InputEventError.invalidDelta }

        self.type = type
        self.x = x
        self.y = y
        self.button = button
        self.buttons = buttons
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.key = key
        self.code = code
        self.`repeat` = `repeat`
        self.text = text
        self.modifiers = modifiers
    }

    private static func isValidScrollDelta(_ value: Double) -> Bool {
        value.isFinite && (-10_000...10_000).contains(value)
    }

    public init(jsonData: Data) throws {
        self = try Self.decode(jsonData: jsonData).event
    }

    /// Decodes an event and its optional client sequence number in a single pass.
    /// The persistent input transport uses `seq` to ack events and measure latency.
    public static func decode(jsonData: Data) throws -> (event: InputEvent, seq: UInt64?) {
        let payload = try JSONDecoder().decode(InputEventPayload.self, from: jsonData)
        let modifiers = InputModifiers(
            shift: payload.shiftKey ?? false,
            control: payload.ctrlKey ?? false,
            option: payload.altKey ?? false,
            command: payload.metaKey ?? false
        )
        let event = try InputEvent(
            type: payload.type,
            x: payload.x,
            y: payload.y,
            button: payload.button,
            buttons: payload.buttons,
            deltaX: payload.deltaX,
            deltaY: payload.deltaY,
            key: payload.key,
            code: payload.code,
            repeat: payload.repeat,
            text: payload.text,
            modifiers: modifiers
        )
        return (event, payload.seq)
    }

    public func point(in bounds: CGRect) -> CGPoint {
        let normalizedX = x ?? 0
        let normalizedY = y ?? 0
        return CGPoint(
            x: bounds.minX + bounds.width * normalizedX,
            y: bounds.minY + bounds.height * normalizedY
        )
    }
}

public struct InputModifiers: Equatable, Sendable {
    public let shift: Bool
    public let control: Bool
    public let option: Bool
    public let command: Bool

    public init(shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false) {
        self.shift = shift
        self.control = control
        self.option = option
        self.command = command
    }

    var cgFlags: CGEventFlags {
        var flags = CGEventFlags()
        if shift { flags.insert(.maskShift) }
        if control { flags.insert(.maskControl) }
        if option { flags.insert(.maskAlternate) }
        if command { flags.insert(.maskCommand) }
        return flags
    }
}

public enum InputEventError: Error, Equatable, CustomStringConvertible {
    case invalidCoordinates
    case invalidDelta
    case unsupportedKey(String)
    case accessibilityPermissionDenied

    public var description: String {
        switch self {
        case .invalidCoordinates:
            return "Input coordinates must be finite normalized values in 0...1"
        case .invalidDelta:
            return "Scroll deltas must be finite values"
        case .unsupportedKey(let key):
            return "Unsupported key: \(key)"
        case .accessibilityPermissionDenied:
            return "Accessibility permission is not granted"
        }
    }
}

private struct InputEventPayload: Decodable {
    let type: InputEvent.EventType
    let x: Double?
    let y: Double?
    let button: Int?
    let buttons: Int?
    let deltaX: Double?
    let deltaY: Double?
    let key: String?
    let code: String?
    let `repeat`: Bool?
    let text: String?
    let shiftKey: Bool?
    let ctrlKey: Bool?
    let altKey: Bool?
    let metaKey: Bool?
    let seq: UInt64?
}

public protocol InputEventDispatching: Sendable {
    func dispatch(_ event: InputEvent) throws
}

public enum MacKeyCodeMapper {
    private static let codeMap: [String: CGKeyCode] = [
        "KeyA": 0, "KeyS": 1, "KeyD": 2, "KeyF": 3, "KeyH": 4, "KeyG": 5, "KeyZ": 6, "KeyX": 7,
        "KeyC": 8, "KeyV": 9, "KeyB": 11, "KeyQ": 12, "KeyW": 13, "KeyE": 14, "KeyR": 15, "KeyY": 16,
        "KeyT": 17, "Digit1": 18, "Digit2": 19, "Digit3": 20, "Digit4": 21, "Digit6": 22, "Digit5": 23,
        "Equal": 24, "Digit9": 25, "Digit7": 26, "Minus": 27, "Digit8": 28, "Digit0": 29, "BracketRight": 30,
        "KeyO": 31, "KeyU": 32, "BracketLeft": 33, "KeyI": 34, "KeyP": 35, "Enter": 36, "KeyL": 37,
        "KeyJ": 38, "Quote": 39, "KeyK": 40, "Semicolon": 41, "Backslash": 42, "Comma": 43, "Slash": 44,
        "KeyN": 45, "KeyM": 46, "Period": 47, "Tab": 48, "Space": 49, "Backquote": 50, "Backspace": 51,
        "Escape": 53, "MetaRight": 54, "MetaLeft": 55, "ShiftLeft": 56, "CapsLock": 57, "AltLeft": 58,
        "ControlLeft": 59, "ShiftRight": 60, "AltRight": 61, "ControlRight": 62, "F17": 64, "F18": 79, "F19": 80,
        "F20": 90, "F5": 96, "F6": 97, "F7": 98, "F3": 99, "F8": 100, "F9": 101, "F11": 103,
        "F13": 105, "F16": 106, "F14": 107, "F10": 109, "F12": 111, "F15": 113, "Help": 114, "Home": 115,
        "PageUp": 116, "Delete": 117, "F4": 118, "End": 119, "F2": 120, "PageDown": 121, "F1": 122,
        "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126
    ]

    public static func keyCode(for code: String?, key: String?) -> CGKeyCode? {
        if let code, let mapped = codeMap[code] { return mapped }
        guard let key else { return nil }
        switch key {
        case "Enter": return 36
        case "Tab": return 48
        case " ", "Spacebar": return 49
        case "Backspace": return 51
        case "Escape": return 53
        case "ArrowLeft": return 123
        case "ArrowRight": return 124
        case "ArrowDown": return 125
        case "ArrowUp": return 126
        default: return nil
        }
    }
}

public final class CGEventInputDispatcher: InputEventDispatching, @unchecked Sendable {
    public init() {}

    public func dispatch(_ event: InputEvent) throws {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw InputEventError.accessibilityPermissionDenied
        }

        let bounds = CGDisplayBounds(CGMainDisplayID())
        switch event.type {
        case .move, .pointerMove:
            postMove(to: event.point(in: bounds), buttons: event.buttons ?? 0, flags: event.modifiers.cgFlags)
        case .click:
            let point = event.point(in: bounds)
            postMouse(type: .leftMouseDown, at: point, button: .left, flags: event.modifiers.cgFlags)
            postMouse(type: .leftMouseUp, at: point, button: .left, flags: event.modifiers.cgFlags)
        case .pointerDown:
            let point = event.point(in: bounds)
            postMouse(type: mouseDownType(for: event.button), at: point, button: mouseButton(for: event.button), flags: event.modifiers.cgFlags)
        case .pointerUp:
            let point = event.point(in: bounds)
            postMouse(type: mouseUpType(for: event.button), at: point, button: mouseButton(for: event.button), flags: event.modifiers.cgFlags)
        case .scroll:
            postMove(to: event.point(in: bounds), buttons: 0, flags: event.modifiers.cgFlags)
            postScroll(deltaX: event.deltaX ?? 0, deltaY: event.deltaY ?? 0)
        case .keyDown:
            try postKey(event, keyDown: true)
        case .keyUp:
            try postKey(event, keyDown: false)
        case .text:
            try postText(event.text ?? event.key ?? "")
        }
    }

    private func postMove(to point: CGPoint, buttons: Int, flags: CGEventFlags) {
        let type: CGEventType = buttons == 1 ? .leftMouseDragged : buttons == 2 ? .rightMouseDragged : .mouseMoved
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: buttons == 2 ? .right : .left)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func postMouse(type: CGEventType, at point: CGPoint, button: CGMouseButton, flags: CGEventFlags) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func postScroll(deltaX: Double, deltaY: Double) {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(-deltaY),
            wheel2: Int32(-deltaX),
            wheel3: 0
        )
        event?.post(tap: .cghidEventTap)
    }

    private func postKey(_ event: InputEvent, keyDown: Bool) throws {
        guard let keyCode = MacKeyCodeMapper.keyCode(for: event.code, key: event.key) else {
            throw InputEventError.unsupportedKey(event.code ?? event.key ?? "unknown")
        }
        let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)
        cgEvent?.flags = event.modifiers.cgFlags
        cgEvent?.post(tap: .cghidEventTap)
    }

    private func postText(_ text: String) throws {
        guard !text.isEmpty else { return }
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        event?.post(tap: .cghidEventTap)
    }

    private func mouseButton(for button: Int?) -> CGMouseButton {
        switch button {
        case 2: return .right
        case 1: return .center
        default: return .left
        }
    }

    private func mouseDownType(for button: Int?) -> CGEventType {
        switch button {
        case 2: return .rightMouseDown
        case 1: return .otherMouseDown
        default: return .leftMouseDown
        }
    }

    private func mouseUpType(for button: Int?) -> CGEventType {
        switch button {
        case 2: return .rightMouseUp
        case 1: return .otherMouseUp
        default: return .leftMouseUp
        }
    }
}
