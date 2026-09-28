import XCTest
import UIKit

@MainActor
final class InputCaptureViewTests: XCTestCase {
    func testRepeatedPrimaryClicksSendBothPairsWithoutWaitingForDoubleTap() throws {
        let (view, session) = makePadView()
        let primary = try XCTUnwrap(view.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }
            .first { $0.buttonMaskRequired == .primary && $0.numberOfTouchesRequired == 1 })
        XCTAssertEqual(primary.numberOfTapsRequired, 1)
        let action = NSSelectorFromString("onTapAbsolute:")
        view.perform(action, with: LocatedTap(CGPoint(x: 250, y: 500)))
        view.perform(action, with: LocatedTap(CGPoint(x: 250, y: 500)))
        XCTAssertEqual(session.pointers, [
            .init(type: "pointerDown", x: 0.25, y: 0.5, button: 0, buttons: 1),
            .init(type: "pointerUp", x: 0.25, y: 0.5, button: 0, buttons: 0),
            .init(type: "pointerDown", x: 0.25, y: 0.5, button: 0, buttons: 1),
            .init(type: "pointerUp", x: 0.25, y: 0.5, button: 0, buttons: 0)
        ])
    }

    func testPadRegistersSecondaryClickWithoutConsumingFingerTaps() throws {
        let (view, _) = makePadView()
        let secondary = try XCTUnwrap(view.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }
            .first { $0.buttonMaskRequired == .secondary })
        XCTAssertEqual(secondary.numberOfTouchesRequired, 1)
        XCTAssertEqual(secondary.delegate?.gestureRecognizer?(secondary, shouldReceive: ButtonEvent(.secondary)), true)
        XCTAssertEqual(secondary.delegate?.gestureRecognizer?(secondary, shouldReceive: ButtonEvent(.primary)), false)
        XCTAssertEqual(secondary.delegate?.gestureRecognizer?(secondary, shouldReceive: ButtonEvent([])), false)
    }

    func testSecondaryClickCannotStartLeftDrag() throws {
        let (view, _) = makePadView()
        let drag = try XCTUnwrap(view.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }
            .first { $0.maximumNumberOfTouches == 1 })
        XCTAssertEqual(drag.delegate?.gestureRecognizer?(drag, shouldReceive: ButtonEvent(.secondary)), false)
        XCTAssertEqual(drag.delegate?.gestureRecognizer?(drag, shouldReceive: ButtonEvent(.primary)), true)
        XCTAssertEqual(drag.delegate?.gestureRecognizer?(drag, shouldReceive: ButtonEvent([])), true)
    }

    func testSecondaryClickSendsRightButtonPairAtLetterboxedPointerLocation() throws {
        let (view, session) = makePadView()
        try invokeSecondaryClick(on: view, at: CGPoint(x: 250, y: 250))
        // 2:1 video in a 1000x1000 view occupies y=250...750.
        XCTAssertEqual(session.pointers, [
            .init(type: "pointerDown", x: 0.25, y: 0, button: 2, buttons: 2),
            .init(type: "pointerUp", x: 0.25, y: 0, button: 2, buttons: 0)
        ])
    }

    func testSecondaryClickIgnoresLetterboxBars() throws {
        let (view, session) = makePadView()
        try invokeSecondaryClick(on: view, at: CGPoint(x: 250, y: 100))
        XCTAssertTrue(session.pointers.isEmpty)
    }

    private func makePadView() -> (RemoteInputUIView, RemoteSession) {
        XCTAssertEqual(UIDevice.current.userInterfaceIdiom, .pad, "Run this suite on an iPad simulator")
        let session = RemoteSession()
        let view = RemoteInputUIView(session: session, state: InputState())
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        return (view, session)
    }

    private func invokeSecondaryClick(on view: RemoteInputUIView, at point: CGPoint) throws {
        let action = NSSelectorFromString("onSecondaryClickAbsolute:")
        XCTAssertTrue(view.responds(to: action), "iPad must handle secondary clicks")
        guard view.responds(to: action) else { return }
        view.perform(action, with: LocatedTap(point))
    }
}

private final class ButtonEvent: UIEvent {
    private let mask: ButtonMask
    init(_ mask: ButtonMask) { self.mask = mask; super.init() }
    override var buttonMask: ButtonMask { mask }
}

private final class LocatedTap: UITapGestureRecognizer {
    private let point: CGPoint
    init(_ point: CGPoint) { self.point = point; super.init(target: nil, action: nil) }
    override func location(in view: UIView?) -> CGPoint { point }
}

/// Records the input view's outgoing session calls; never connects to or controls the Mac.
@MainActor
final class RemoteSession {
    struct Pointer: Equatable {
        let type: String
        let x: Double
        let y: Double
        let button: Int
        let buttons: Int
    }
    var videoSize = CGSize(width: 2000, height: 1000)
    var pointers: [Pointer] = []
    func sendPointer(_ type: String, x: Double, y: Double, button: Int = 0, buttons: Int = 0) {
        pointers.append(.init(type: type, x: x, y: y, button: button, buttons: buttons))
    }
    func sendScroll(x: Double, y: Double, deltaX: Double, deltaY: Double) {}
    func sendKey(down: Bool, code: String, shift: Bool, control: Bool, option: Bool, command: Bool) {}
    func sendText(_ text: String) {}
}
