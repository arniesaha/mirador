import SwiftUI
import UIKit
import AVFoundation

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

/// Full-screen transparent view that captures touch/trackpad/keyboard and forwards normalized
/// input to the session. Coordinates are mapped against the letterboxed video content rect.
final class RemoteInputUIView: UIView {
    weak var session: RemoteSession?
    var onRevealControls: (() -> Void)?

    init(session: RemoteSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        setupGestures()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        addGestureRecognizer(tap)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(onDrag(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        addGestureRecognizer(drag)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        // Also accept indirect scroll events (Magic Keyboard trackpad / mouse wheel), which a pan
        // recognizer ignores by default. These arrive with numberOfTouches == 0, bypassing the
        // 2-touch constraint above, so the same handler serves touchscreen and trackpad scrolling.
        scroll.allowedScrollTypesMask = .all
        addGestureRecognizer(scroll)

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:))))

        let reveal = UITapGestureRecognizer(target: self, action: #selector(onThreeFingerTap))
        reveal.numberOfTouchesRequired = 3
        addGestureRecognizer(reveal)
    }

    @objc private func onThreeFingerTap() { onRevealControls?() }

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

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        if !isFirstResponder { becomeFirstResponder() }
        guard let (x, y) = normalized(g.location(in: self)) else { return }
        session?.sendPointer("pointerDown", x: x, y: y, button: 0, buttons: 1)
        session?.sendPointer("pointerUp", x: x, y: y, button: 0, buttons: 0)
    }

    @objc private func onDrag(_ g: UIPanGestureRecognizer) {
        guard let (x, y) = normalized(g.location(in: self)) else { return }
        switch g.state {
        case .began: session?.sendPointer("pointerDown", x: x, y: y, button: 0, buttons: 1)
        case .changed: session?.sendPointer("pointerMove", x: x, y: y, button: 0, buttons: 1)
        case .ended, .cancelled, .failed: session?.sendPointer("pointerUp", x: x, y: y, button: 0, buttons: 0)
        default: break
        }
    }

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed, let (x, y) = normalized(g.location(in: self)) else {
            g.setTranslation(.zero, in: self); return
        }
        let t = g.translation(in: self)
        session?.sendScroll(x: x, y: y, deltaX: Double(-t.x), deltaY: Double(-t.y))
        g.setTranslation(.zero, in: self)
    }

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        guard let (x, y) = normalized(g.location(in: self)) else { return }
        session?.sendPointer("pointerMove", x: x, y: y, button: 0, buttons: 0)
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
    var onRevealControls: () -> Void = {}
    func makeUIView(context: Context) -> RemoteInputUIView {
        let view = RemoteInputUIView(session: session)
        view.onRevealControls = onRevealControls
        return view
    }
    func updateUIView(_ uiView: RemoteInputUIView, context: Context) {
        uiView.onRevealControls = onRevealControls
    }
}
