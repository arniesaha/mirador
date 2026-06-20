import SwiftUI

/// Fullscreen remote display. Stage 1 shows the H.264 video + a status overlay; Stage 2 layers
/// input capture on top.
struct RemoteScreenView: View {
    @ObservedObject var session: RemoteSession
    let onDisconnect: () -> Void
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VideoSurface(session: session)
                .ignoresSafeArea()
            InputCaptureView(session: session, onRevealControls: revealControls)
                .ignoresSafeArea()
            statusBar
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)   // when hidden, the top is fully draggable
                .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        }
        .onAppear {
            session.start()
            scheduleHide()
        }
        .onDisappear { hideTask?.cancel() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
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
