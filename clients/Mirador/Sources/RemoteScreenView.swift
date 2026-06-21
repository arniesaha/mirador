import SwiftUI
import AVFoundation

/// Fullscreen remote display. The video, input capture, and virtual-cursor overlay share one
/// transformed stack so pinch-zoom keeps taps aligned; a key bar and software-keyboard toggle make
/// the phone usable for typing and Mac shortcuts.
struct RemoteScreenView: View {
    @ObservedObject var session: RemoteSession
    let onDisconnect: () -> Void
    @StateObject private var input = InputState()
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    /// The virtual cursor, pinch-zoom, key bar, and software keyboard are phone-only; iPad keeps its
    /// previous direct-touch / trackpad behavior with no extra chrome.
    private let isPhone = UIDevice.current.userInterfaceIdiom == .phone
    private var keyBarVisible: Bool { isPhone && (controlsVisible || input.keyboardVisible) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                ZStack {
                    VideoSurface(session: session)
                    InputCaptureView(session: session, state: input, onRevealControls: revealControls)
                    if isPhone { cursorOverlay(in: geo.size) }
                }
            }
            .scaleEffect(isPhone ? input.zoom : 1, anchor: .center)
            .offset(isPhone ? input.offset : .zero)
            .ignoresSafeArea()

            statusBar
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)   // when hidden, the top is fully draggable
                .animation(.easeInOut(duration: 0.25), value: controlsVisible)

            VStack {
                Spacer()
                if keyBarVisible {
                    KeyBar(session: session, state: input)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: keyBarVisible)

            // Always-reachable way to summon the keyboard when the chrome is hidden (phone only).
            if isPhone, !keyBarVisible {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { input.keyboardVisible = true } label: {
                            Image(systemName: "keyboard")
                                .font(.title3)
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(.black.opacity(0.5), in: Circle())
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                    }
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: keyBarVisible)
            }
        }
        .onAppear {
            session.start()
            scheduleHide()
        }
        .onDisappear { hideTask?.cancel() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    /// Small symmetric cursor (center = hotspot) drawn inside the transformed stack so it pans/zooms
    /// with the content; counter-scaled to keep a constant on-screen size.
    private func cursorOverlay(in size: CGSize) -> some View {
        let rect = AVMakeRect(aspectRatio: session.videoSize,
                              insideRect: CGRect(origin: .zero, size: size))
        let x = rect.minX + input.cursorNorm.x * rect.width
        let y = rect.minY + input.cursorNorm.y * rect.height
        return ZStack {
            Circle().fill(.white.opacity(0.18))
            Circle().stroke(.white, lineWidth: 1.5)
            Circle().fill(.white).frame(width: 3, height: 3)
        }
        .frame(width: 18, height: 18)
        .shadow(color: .black.opacity(0.6), radius: 1.5)
        .scaleEffect(1 / max(input.zoom, 1))
        .position(x: x, y: y)
        .allowsHitTesting(false)
    }

    /// Controls auto-hide so the full screen is usable; a 3-finger tap brings them back.
    private func revealControls() {
        controlsVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { controlsVisible = false }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(statusText)
                .font(.caption.monospaced())
                .foregroundStyle(.white)
            Spacer()
            Button("Disconnect", action: onDisconnect)
                .font(.caption)
                .buttonStyle(.bordered)
                .tint(.red)
        }
        .padding(8)
        .background(.black.opacity(0.45), in: Capsule())
    }

    private var statusColor: Color {
        switch session.state {
        case .connecting: return .yellow
        case .connected: return .green
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch session.state {
        case .connecting: return "connecting \(session.config.host)…"
        case .connected:
            let enc = Int(session.encodeFps.rounded())
            let kbit = Int(session.encodeKbitPerSec.rounded())
            let age = max(0, Int(session.lastFrameAgeMs.rounded()))   // clamp clock-skew negatives
            return "\(enc)fps \(kbit)kbit/s · age \(age)ms · in \(Int(session.lastInputLatencyMs))ms"
        case .failed(let reason): return "failed: \(reason)"
        }
    }
}

/// Floating bar of Mac keys the iOS keyboard lacks: Esc, Tab, arrows, and sticky ⌃ ⌥ ⌘ modifiers
/// that latch and combine with the next key press (soft keyboard or this bar).
private struct KeyBar: View {
    let session: RemoteSession
    @ObservedObject var state: InputState

    var body: some View {
        HStack(spacing: 6) {
            specialKey("esc") { send("Escape") }
            specialKey("tab") { send("Tab") }
            modKey("⌃", on: state.control) { state.control.toggle() }
            modKey("⌥", on: state.option) { state.option.toggle() }
            modKey("⌘", on: state.command) { state.command.toggle() }
            Spacer(minLength: 4)
            specialKey("←") { send("ArrowLeft") }
            specialKey("↓") { send("ArrowDown") }
            specialKey("↑") { send("ArrowUp") }
            specialKey("→") { send("ArrowRight") }
            Spacer(minLength: 4)
            specialKey(state.keyboardVisible ? "⌄" : "⌨") { state.keyboardVisible.toggle() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func send(_ code: String) {
        session.sendKey(down: true, code: code, shift: state.shift,
                        control: state.control, option: state.option, command: state.command)
        session.sendKey(down: false, code: code, shift: state.shift,
                        control: state.control, option: state.option, command: state.command)
        state.clearModifiers()
    }

    private func specialKey(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.monospaced())
                .frame(minWidth: 30)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func modKey(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.monospaced().weight(.semibold))
                .frame(minWidth: 30)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(on ? Color.accentColor : .white.opacity(0.15),
                           in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}
