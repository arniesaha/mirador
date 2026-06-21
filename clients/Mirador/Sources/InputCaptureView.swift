import SwiftUI
import UIKit
import AVFoundation
import GameController

/// Maps a hardware-keyboard HID usage to the server's KeyboardEvent-style `code` string
/// (see MacKeyCodeMapper on the server).
enum KeyMap {
    static func code(for usage: UIKeyboardHIDUsage) -> String? {
        let raw = usage.rawValue
        if (4...29).contains(raw) {              // A–Z
            let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            return "Key" + String(Array(letters)[raw - 4])
        }
        if (30...38).contains(raw) { return "Digit\(raw - 29)" } // 1–9
        if raw == 39 { return "Digit0" }
        if (58...69).contains(raw) { return "F\(raw - 57)" }     // F1–F12
        return fixed[raw]
    }

    static func isModifier(_ usage: UIKeyboardHIDUsage) -> Bool {
        (224...231).contains(usage.rawValue)
    }

    static func isSpecial(_ usage: UIKeyboardHIDUsage) -> Bool {
        special.contains(usage.rawValue)
    }

    private static let special: Set<Int> = [
        40, 41, 42, 43, 76, 74, 77, 75, 78, 79, 80, 81, 82, // enter,esc,bksp,tab,del,home,end,pgup,pgdn,arrows
        58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69       // F1–F12
    ]

    private static let fixed: [Int: String] = [
        40: "Enter", 41: "Escape", 42: "Backspace", 43: "Tab", 44: "Space",
        45: "Minus", 46: "Equal", 47: "BracketLeft", 48: "BracketRight", 49: "Backslash",
        51: "Semicolon", 52: "Quote", 53: "Backquote", 54: "Comma", 55: "Period", 56: "Slash",
        76: "Delete", 74: "Home", 77: "End", 75: "PageUp", 78: "PageDown",
        79: "ArrowRight", 80: "ArrowLeft", 81: "ArrowDown", 82: "ArrowUp"
    ]
}

/// Maps a *typed character* (from the iOS software keyboard's `insertText`) to a server `code` plus
/// whether Shift is implied, so latched modifiers (⌘/⌃/⌥) can be applied as a real key chord rather
/// than typed text. US-QWERTY layout — codes are positional, so non-US layouts may mis-map.
enum SoftKeyMap {
    static func code(for ch: Character) -> (code: String, shift: Bool)? {
        if let ascii = ch.asciiValue {
            if ascii >= 97, ascii <= 122 {                       // a–z
                return ("Key\(Character(UnicodeScalar(ascii - 32)))", false)
            }
            if ascii >= 65, ascii <= 90 {                        // A–Z (shifted)
                return ("Key\(ch)", true)
            }
        }
        return table[ch]
    }

    private static let table: [Character: (String, Bool)] = [
        "1": ("Digit1", false), "2": ("Digit2", false), "3": ("Digit3", false), "4": ("Digit4", false),
        "5": ("Digit5", false), "6": ("Digit6", false), "7": ("Digit7", false), "8": ("Digit8", false),
        "9": ("Digit9", false), "0": ("Digit0", false),
        "!": ("Digit1", true), "@": ("Digit2", true), "#": ("Digit3", true), "$": ("Digit4", true),
        "%": ("Digit5", true), "^": ("Digit6", true), "&": ("Digit7", true), "*": ("Digit8", true),
        "(": ("Digit9", true), ")": ("Digit0", true),
        "-": ("Minus", false), "=": ("Equal", false), "[": ("BracketLeft", false), "]": ("BracketRight", false),
        "\\": ("Backslash", false), ";": ("Semicolon", false), "'": ("Quote", false), "`": ("Backquote", false),
        ",": ("Comma", false), ".": ("Period", false), "/": ("Slash", false), " ": ("Space", false),
        "_": ("Minus", true), "+": ("Equal", true), "{": ("BracketLeft", true), "}": ("BracketRight", true),
        "|": ("Backslash", true), ":": ("Semicolon", true), "\"": ("Quote", true), "~": ("Backquote", true),
        "<": ("Comma", true), ">": ("Period", true), "?": ("Slash", true)
    ]
}

/// Full-screen transparent view that captures touch/trackpad/keyboard and forwards normalized input
/// to the session. Direct touches drive a relative *virtual cursor* (trackpad model); the iPad Magic
/// Keyboard trackpad keeps its absolute hover/click path. Coordinates map against the letterboxed
/// video content rect.
final class RemoteInputUIView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    weak var session: RemoteSession?
    let state: InputState
    var onRevealControls: (() -> Void)?

    /// How far the virtual cursor travels per point of finger movement (before the zoom divisor).
    private static let sensitivity: CGFloat = 1.4

    private var dragging = false
    private(set) var keyboardVisible = false

    /// The relative virtual-cursor model, pinch-zoom, and on-screen keyboard are phone-only. On iPad
    /// (with its larger screen and trackpad) we keep the original absolute touch model so direct
    /// click-and-drag and the trackpad pointer behave as before.
    private let isPhone = UIDevice.current.userInterfaceIdiom == .phone

    // Recognizers we cross-reference in the delegate.
    private var onePan: UIPanGestureRecognizer!
    private var dragHold: UILongPressGestureRecognizer!
    private var tap: UITapGestureRecognizer!
    private var rightTap: UITapGestureRecognizer!
    private var scroll: UIPanGestureRecognizer!
    private var pinch: UIPinchGestureRecognizer!

    init(session: RemoteSession, state: InputState) {
        self.session = session
        self.state = state
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        setupGestures()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var canBecomeFirstResponder: Bool { true }

    /// Only grab first responder up front when a *physical* keyboard is attached (so its keys flow
    /// without forcing the on-screen keyboard). On a phone, first responder is driven solely by the
    /// keyboard toggle — otherwise every screen tap would pop the software keyboard.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, GCKeyboard.coalesced != nil { becomeFirstResponder() }
    }

    private func setupGestures() {
        if isPhone { setupPhoneGestures() } else { setupPadGestures() }
    }

    /// iPad: the original absolute model — tap clicks at the touch point, one finger drags directly,
    /// two fingers scroll, and the trackpad pointer maps absolutely via hover.
    private func setupPadGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTapAbsolute(_:)))
        addGestureRecognizer(tap)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(onDragAbsolute(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        addGestureRecognizer(drag)

        scroll = UIPanGestureRecognizer(target: self, action: #selector(onScrollAbsolute(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .all
        addGestureRecognizer(scroll)

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(onHoverAbsolute(_:))))

        let reveal = UITapGestureRecognizer(target: self, action: #selector(onThreeFingerTap))
        reveal.numberOfTouchesRequired = 3
        addGestureRecognizer(reveal)
    }

    private func setupPhoneGestures() {
        // One-finger relative cursor (move) folded with a long-press that promotes to a drag.
        onePan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        onePan.maximumNumberOfTouches = 1
        onePan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        onePan.delegate = self
        addGestureRecognizer(onePan)

        dragHold = UILongPressGestureRecognizer(target: self, action: #selector(onDragHold(_:)))
        dragHold.minimumPressDuration = 0.4
        dragHold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        dragHold.delegate = self
        addGestureRecognizer(dragHold)

        // Tap → click at the virtual cursor (works for direct fingers and the indirect trackpad,
        // whose cursor is tracked via hover).
        tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        tap.require(toFail: onePan)
        tap.require(toFail: dragHold)
        addGestureRecognizer(tap)

        // Two-finger drag → pan the zoomed viewport when zoomed in, else scroll the remote content
        // (also accepts indirect scroll from trackpad / mouse wheel).
        scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .all
        scroll.delegate = self
        addGestureRecognizer(scroll)

        // Two-finger tap → right-click (only when it isn't the start of a scroll/pinch).
        rightTap = UITapGestureRecognizer(target: self, action: #selector(onRightTap(_:)))
        rightTap.numberOfTouchesRequired = 2
        addGestureRecognizer(rightTap)

        pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        rightTap.require(toFail: scroll)
        rightTap.require(toFail: pinch)

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:))))

        let reveal = UITapGestureRecognizer(target: self, action: #selector(onThreeFingerTap))
        reveal.numberOfTouchesRequired = 3
        addGestureRecognizer(reveal)
    }

    @objc private func onThreeFingerTap() { onRevealControls?() }

    // MARK: iPad absolute handlers (original behavior)

    @objc private func onTapAbsolute(_ g: UITapGestureRecognizer) {
        if !isFirstResponder, GCKeyboard.coalesced != nil { becomeFirstResponder() }
        guard let (x, y) = normalized(g.location(in: self)) else { return }
        session?.sendPointer("pointerDown", x: x, y: y, button: 0, buttons: 1)
        session?.sendPointer("pointerUp", x: x, y: y, button: 0, buttons: 0)
    }

    @objc private func onDragAbsolute(_ g: UIPanGestureRecognizer) {
        guard let (x, y) = normalized(g.location(in: self)) else { return }
        switch g.state {
        case .began: session?.sendPointer("pointerDown", x: x, y: y, button: 0, buttons: 1)
        case .changed: session?.sendPointer("pointerMove", x: x, y: y, button: 0, buttons: 1)
        case .ended, .cancelled, .failed: session?.sendPointer("pointerUp", x: x, y: y, button: 0, buttons: 0)
        default: break
        }
    }

    @objc private func onScrollAbsolute(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed, let (x, y) = normalized(g.location(in: self)) else {
            g.setTranslation(.zero, in: self); return
        }
        let t = g.translation(in: self)
        session?.sendScroll(x: x, y: y, deltaX: Double(-t.x), deltaY: Double(-t.y))
        g.setTranslation(.zero, in: self)
    }

    @objc private func onHoverAbsolute(_ g: UIHoverGestureRecognizer) {
        guard let (x, y) = normalized(g.location(in: self)) else { return }
        session?.sendPointer("pointerMove", x: x, y: y, button: 0, buttons: 0)
    }

    // MARK: Coordinate mapping

    private var contentRect: CGRect {
        let vs = session?.videoSize ?? CGSize(width: 16, height: 9)
        guard vs.width > 0, vs.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: vs, insideRect: bounds)
    }

    private func normalized(_ p: CGPoint) -> (Double, Double)? {
        let r = contentRect
        guard r.width > 0, r.height > 0 else { return nil }
        let nx = (p.x - r.minX) / r.width
        let ny = (p.y - r.minY) / r.height
        guard (0...1).contains(nx), (0...1).contains(ny) else { return nil }
        return (Double(nx), Double(ny))
    }

    /// Send a pointer event located at the current virtual cursor.
    private func sendCursorPointer(_ type: String, button: Int = 0, buttons: Int = 0) {
        let c = state.cursorNorm
        session?.sendPointer(type, x: Double(c.x), y: Double(c.y), button: button, buttons: buttons)
    }

    /// Advance the virtual cursor by a finger translation (in points). Finer when zoomed in.
    private func moveCursor(byPoints t: CGPoint) {
        let r = contentRect
        guard r.width > 0, r.height > 0 else { return }
        let z = max(state.zoom, 1)
        var c = state.cursorNorm
        c.x = min(max(c.x + (t.x / z) / r.width * Self.sensitivity, 0), 1)
        c.y = min(max(c.y + (t.y / z) / r.height * Self.sensitivity, 0), 1)
        state.cursorNorm = c
        applyEdgeFollow()
    }

    /// When zoomed, pan the viewport so the cursor stays inside an edge margin. Offset is re-derived
    /// from the cursor each call (never accumulated) to avoid drift, and clamped to the letterbox.
    private func applyEdgeFollow() {
        let r = contentRect
        guard r.width > 0, r.height > 0 else { return }
        let z = max(state.zoom, 1)
        guard z > 1.001 else {
            if state.offset != .zero { state.offset = .zero }
            return
        }
        let visible = 1.0 / z
        var cx = 0.5 - state.offset.width / (z * r.width)
        var cy = 0.5 - state.offset.height / (z * r.height)
        let margin = 0.12 * visible
        let cur = state.cursorNorm
        if cur.x < cx - visible / 2 + margin { cx = cur.x - visible / 2 + margin }
        else if cur.x > cx + visible / 2 - margin { cx = cur.x + visible / 2 - margin }
        if cur.y < cy - visible / 2 + margin { cy = cur.y - visible / 2 + margin }
        else if cur.y > cy + visible / 2 - margin { cy = cur.y + visible / 2 - margin }
        cx = min(max(cx, visible / 2), 1 - visible / 2)
        cy = min(max(cy, visible / 2), 1 - visible / 2)
        let newOffset = CGSize(width: (0.5 - cx) * z * r.width, height: (0.5 - cy) * z * r.height)
        if newOffset != state.offset { state.offset = newOffset }
    }

    /// Two-finger drag while zoomed: move the visible viewport by a finger translation (content
    /// follows the fingers), clamped to the content edges. The virtual cursor is recentered in the
    /// new viewport so a subsequent one-finger move's edge-follow doesn't snap the view back.
    private func panViewport(byPoints t: CGPoint) {
        let r = contentRect
        let z = max(state.zoom, 1)
        guard z > 1.001, r.width > 0, r.height > 0 else { return }
        let maxX = 0.5 * (z - 1) * r.width
        let maxY = 0.5 * (z - 1) * r.height
        var o = state.offset
        o.width = min(max(o.width + t.x, -maxX), maxX)
        o.height = min(max(o.height + t.y, -maxY), maxY)
        state.offset = o
        state.cursorNorm = CGPoint(x: 0.5 - o.width / (z * r.width),
                                   y: 0.5 - o.height / (z * r.height))
    }

    // MARK: Gesture handlers

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        sendCursorPointer("pointerDown", button: 0, buttons: 1)
        sendCursorPointer("pointerUp", button: 0, buttons: 0)
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .changed:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            moveCursor(byPoints: t)
            sendCursorPointer("pointerMove", buttons: dragging ? 1 : 0)
        case .ended, .cancelled, .failed:
            if dragging { sendCursorPointer("pointerUp", buttons: 0); dragging = false }
        default: break
        }
    }

    /// A stationary long-press promotes the one-finger gesture to a left-button drag.
    @objc private func onDragHold(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            dragging = true
            sendCursorPointer("pointerDown", button: 0, buttons: 1)
        case .ended, .cancelled, .failed:
            if dragging { sendCursorPointer("pointerUp", buttons: 0); dragging = false }
        default: break
        }
    }

    @objc private func onRightTap(_ g: UITapGestureRecognizer) {
        sendCursorPointer("pointerDown", button: 2, buttons: 2)
        sendCursorPointer("pointerUp", button: 2, buttons: 0)
    }

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed else { g.setTranslation(.zero, in: self); return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        // When zoomed in, two fingers pan the viewport to another part of the screen; otherwise
        // they scroll the remote content as before.
        if state.zoom > 1.001 {
            panViewport(byPoints: t)
            return
        }
        let c = state.cursorNorm
        session?.sendScroll(x: Double(c.x), y: Double(c.y), deltaX: Double(-t.x), deltaY: Double(-t.y))
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .changed:
            state.zoom = min(max(state.zoom * g.scale, 1), 3)
            g.scale = 1
            applyEdgeFollow()
        case .ended, .cancelled:
            applyEdgeFollow()
        default: break
        }
    }

    /// Indirect pointer (iPad trackpad): absolute cursor that also seeds the virtual cursor so taps
    /// land where the pointer is.
    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        guard let (x, y) = normalized(g.location(in: self)) else { return }
        state.cursorNorm = CGPoint(x: x, y: y)
        session?.sendPointer("pointerMove", x: x, y: y, button: 0, buttons: 0)
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch and 2-finger scroll coexist (each reads only its own axis); the long-press timer runs
        // alongside the one-finger pan so a hold can promote an in-flight gesture to a drag.
        if (g == pinch && other == scroll) || (g == scroll && other == pinch) { return true }
        if (g == onePan && other == dragHold) || (g == dragHold && other == onePan) { return true }
        return false
    }

    // MARK: Software keyboard (UIKeyInput)

    /// With a hardware keyboard attached we stay first responder to capture its keys; a zero-size
    /// input view suppresses the on-screen keyboard until the user explicitly asks for it. Without a
    /// hardware keyboard, returning `nil` lets the system keyboard appear whenever we're first
    /// responder.
    private lazy var zeroInputView = UIView(frame: .zero)
    override var inputView: UIView? {
        (!keyboardVisible && GCKeyboard.coalesced != nil) ? zeroInputView : nil
    }

    func syncKeyboard(visible: Bool) {
        guard keyboardVisible != visible else { return }
        keyboardVisible = visible
        if visible {
            if isFirstResponder { reloadInputViews() } else { becomeFirstResponder() }
        } else if GCKeyboard.coalesced != nil {
            reloadInputViews()        // keep capturing hardware keys; just hide the soft keyboard
        } else {
            resignFirstResponder()    // no hardware keyboard: dropping first responder dismisses it
        }
    }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" { sendChord(code: "Enter"); return }
        if text == "\t" { sendChord(code: "Tab"); return }

        // With a modifier latched, a single character becomes a real key chord (⌘C, ⌃C, …).
        if state.anyModifierLatched, text.count == 1, let ch = text.first,
           let mapped = SoftKeyMap.code(for: ch) {
            sendChord(code: mapped.code, extraShift: mapped.shift)
            return
        }
        if state.anyModifierLatched { state.clearModifiers() } // couldn't apply — drop the latch
        session?.sendText(text)
    }

    func deleteBackward() { sendChord(code: "Backspace") }

    /// Send a key down+up with the currently-latched modifiers, then clear the (one-shot) latch.
    private func sendChord(code: String, extraShift: Bool = false) {
        let shift = state.shift || extraShift
        let control = state.control, option = state.option, command = state.command
        session?.sendKey(down: true, code: code, shift: shift, control: control, option: option, command: command)
        session?.sendKey(down: false, code: code, shift: shift, control: control, option: option, command: command)
        state.clearModifiers()
    }

    // MARK: Hardware keyboard
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !presses.allSatisfy({ handleKey($0.key, down: true) }) {
            super.pressesBegan(presses, with: event)
        }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !presses.allSatisfy({ handleKey($0.key, down: false) }) {
            super.pressesEnded(presses, with: event)
        }
    }

    private func handleKey(_ key: UIKey?, down: Bool) -> Bool {
        guard let key else { return false }
        if KeyMap.isModifier(key.keyCode) { return true } // flags ride with the actual key
        let m = key.modifierFlags
        let command = m.contains(.command), control = m.contains(.control)
        let option = m.contains(.alternate), shift = m.contains(.shift)

        if let code = KeyMap.code(for: key.keyCode),
           KeyMap.isSpecial(key.keyCode) || command || control {
            session?.sendKey(down: down, code: code, shift: shift, control: control, option: option, command: command)
            return true
        }
        // Printable: send the resolved character(s) as text on key-down (covers shift/symbols/IME).
        if down {
            let chars = key.characters
            if let first = chars.first, first.unicodeScalars.first.map({ $0.value >= 0x20 }) ?? false {
                session?.sendText(chars)
                return true
            }
            return false
        }
        return true // swallow the key-up of a printable handled as text
    }
}

struct InputCaptureView: UIViewRepresentable {
    let session: RemoteSession
    @ObservedObject var state: InputState
    var onRevealControls: () -> Void = {}

    func makeUIView(context: Context) -> RemoteInputUIView {
        let view = RemoteInputUIView(session: session, state: state)
        view.onRevealControls = onRevealControls
        return view
    }
    func updateUIView(_ uiView: RemoteInputUIView, context: Context) {
        uiView.onRevealControls = onRevealControls
        uiView.syncKeyboard(visible: state.keyboardVisible)
    }
}
