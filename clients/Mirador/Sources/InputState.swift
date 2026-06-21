import SwiftUI

/// Shared input state bridged between the SwiftUI chrome (key bar, cursor overlay, zoom transform)
/// and the UIKit capture view. Sticky modifiers are written by both the on-screen key bar and the
/// soft-keyboard path; the virtual cursor and zoom are driven by `RemoteInputUIView` and read back
/// by SwiftUI for rendering.
@MainActor
final class InputState: ObservableObject {
    // MARK: Sticky modifiers (one-shot: consumed by the next key, unless the user disarms them)
    @Published var shift = false
    @Published var control = false
    @Published var option = false
    @Published var command = false

    /// Whether the iOS software keyboard is currently requested.
    @Published var keyboardVisible = false

    /// Virtual cursor in normalized Mac space (0...1). Authoritative for input; the streamed video's
    /// real cursor follows with latency.
    @Published var cursorNorm = CGPoint(x: 0.5, y: 0.5)

    // MARK: Zoom / pan (applied as a transform to the video + input stack)
    @Published var zoom: CGFloat = 1
    /// Offset in points applied alongside `scaleEffect`, re-derived from the cursor on edge-follow.
    @Published var offset: CGSize = .zero

    var anyModifierLatched: Bool { shift || control || option || command }

    func clearModifiers() {
        shift = false; control = false; option = false; command = false
    }
}
