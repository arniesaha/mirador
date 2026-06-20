import Foundation

/// Demand-driven control of the screen-capture/encode pipeline. The HTTP server
/// acquires capture when the first viewer stream opens and releases it when the last
/// one closes, satisfying the design constraint that the host run no ScreenCaptureKit /
/// VideoToolbox pipeline while idle.
public protocol CaptureControlling: Sendable {
    func acquire()
    func release()
    func requestKeyframe()
}

/// Reference-counts active viewer streams and reconciles the capture service to the
/// desired running state. Calls into the service are serialized through this actor; the
/// reconcile loop re-reads the count each iteration so out-of-order acquire/release
/// bursts still converge to "running iff at least one viewer".
public actor CaptureCoordinator: CaptureControlling {
    private let service: ScreenCaptureService
    private var refCount = 0
    private var reconciling = false

    public init(service: ScreenCaptureService) {
        self.service = service
    }

    public nonisolated func acquire() {
        Task { await self.changeRefCount(by: 1) }
    }

    public nonisolated func release() {
        Task { await self.changeRefCount(by: -1) }
    }

    public nonisolated func requestKeyframe() {
        Task { await self.service.requestKeyframe() }
    }

    private func changeRefCount(by delta: Int) async {
        refCount = max(0, refCount + delta)
        await reconcile()
    }

    private func reconcile() async {
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }

        while true {
            let shouldRun = refCount > 0
            let isRunning = await service.isRunning
            if shouldRun == isRunning { break }
            if shouldRun {
                do {
                    try await service.start()
                } catch {
                    // Permission denied / no display: stop retrying in a tight loop.
                    // A later acquire() will trigger another attempt.
                    break
                }
            } else {
                await service.stop()
            }
        }
    }
}
