import Foundation

public struct MJPEGFrame: Equatable, Sendable {
    public let jpeg: Data
    public let sequence: UInt64
    public let capturedAt: Date
}

public struct MJPEGFrameStoreSnapshot: Equatable, Sendable {
    public let droppedFrames: UInt64
    public let latestFrameSequence: UInt64
    public let latestFrameBytes: Int
    public let latestFrameAgeMillis: Double
    public let captureFps: Double
    public let bitrateBitsPerSec: Double
    public let incompleteFrames: UInt64

    public init(
        droppedFrames: UInt64,
        latestFrameSequence: UInt64,
        latestFrameBytes: Int,
        latestFrameAgeMillis: Double,
        captureFps: Double = 0,
        bitrateBitsPerSec: Double = 0,
        incompleteFrames: UInt64 = 0
    ) {
        self.droppedFrames = droppedFrames
        self.latestFrameSequence = latestFrameSequence
        self.latestFrameBytes = latestFrameBytes
        self.latestFrameAgeMillis = latestFrameAgeMillis
        self.captureFps = captureFps
        self.bitrateBitsPerSec = bitrateBitsPerSec
        self.incompleteFrames = incompleteFrames
    }
}

public final class MJPEGFrameQueue: @unchecked Sendable {
    /// Window over which capture FPS and bitrate are averaged.
    static let statsWindow: TimeInterval = 2.0

    private let lock = NSLock()
    private let capacity: Int
    private var frames: [Data] = []
    private var dropped: UInt64 = 0
    private var incomplete: UInt64 = 0
    private var sequence: UInt64 = 0
    private var latest: MJPEGFrame?
    // Rolling window of recently captured frames for FPS/bitrate.
    private var recent: [(at: Date, bytes: Int)] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public var droppedFrames: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    public func push(_ frame: Data) {
        push(frame, at: Date())
    }

    /// Timestamp-injectable entry point used by tests for deterministic FPS/bitrate.
    func push(_ frame: Data, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        latest = MJPEGFrame(jpeg: frame, sequence: sequence, capturedAt: date)
        frames.append(frame)
        while frames.count > capacity {
            frames.removeFirst()
            dropped += 1
        }
        recent.append((at: date, bytes: frame.count))
        pruneRecent(now: date)
    }

    /// Counts a capture-side frame that arrived incomplete and never entered the queue.
    /// Distinct from `droppedFrames`, which counts queue-overflow drops.
    public func recordIncompleteFrame() {
        lock.lock()
        incomplete += 1
        lock.unlock()
    }

    /// Legacy destructive FIFO read retained for tests/backwards compatibility.
    /// Streaming code should prefer latestFrame(after:) so slow clients do not
    /// consume global state or force other viewers to repeat stale frames.
    public func pop() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst()
    }

    public func latestFrame(after lastSequence: UInt64?) -> MJPEGFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest else { return nil }
        if let lastSequence, latest.sequence <= lastSequence { return nil }
        return latest
    }

    public func snapshot(now: Date = Date()) -> MJPEGFrameStoreSnapshot {
        lock.lock()
        defer { lock.unlock() }
        pruneRecent(now: now)
        let windowBytes = recent.reduce(0) { $0 + $1.bytes }
        let captureFps = Double(recent.count) / Self.statsWindow
        let bitrate = Double(windowBytes) * 8.0 / Self.statsWindow
        let age = latest.map { max(0, now.timeIntervalSince($0.capturedAt) * 1000) } ?? 0
        return MJPEGFrameStoreSnapshot(
            droppedFrames: dropped,
            latestFrameSequence: latest?.sequence ?? 0,
            latestFrameBytes: latest?.jpeg.count ?? 0,
            latestFrameAgeMillis: age,
            captureFps: captureFps,
            bitrateBitsPerSec: bitrate,
            incompleteFrames: incomplete
        )
    }

    /// Drops samples older than the stats window. Caller must hold `lock`.
    private func pruneRecent(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.statsWindow)
        while let first = recent.first, first.at < cutoff {
            recent.removeFirst()
        }
    }
}
