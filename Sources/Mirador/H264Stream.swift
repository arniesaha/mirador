import Foundation

/// One encoded H.264 access unit (one coded picture), in Annex-B byte-stream form
/// (start-code delimited NAL units; SPS/PPS are prepended ahead of each keyframe).
public struct H264AccessUnit: Equatable, Sendable {
    public let data: Data
    public let sequence: UInt64
    public let capturedAt: Date
    public let isKeyframe: Bool

    public init(data: Data, sequence: UInt64, capturedAt: Date, isKeyframe: Bool) {
        self.data = data
        self.sequence = sequence
        self.capturedAt = capturedAt
        self.isKeyframe = isKeyframe
    }
}

public struct H264FrameStoreSnapshot: Equatable, Sendable {
    public let latestSequence: UInt64
    public let latestBytes: Int
    public let latestAgeMillis: Double
    public let encodeFps: Double
    public let encodeBitrateBitsPerSec: Double
    /// Average number of frames between keyframes over the window (0 if none seen).
    public let keyframeIntervalFrames: Double
    public let encodeMillis: Double
    public let droppedFrames: UInt64

    public init(
        latestSequence: UInt64 = 0,
        latestBytes: Int = 0,
        latestAgeMillis: Double = 0,
        encodeFps: Double = 0,
        encodeBitrateBitsPerSec: Double = 0,
        keyframeIntervalFrames: Double = 0,
        encodeMillis: Double = 0,
        droppedFrames: UInt64 = 0
    ) {
        self.latestSequence = latestSequence
        self.latestBytes = latestBytes
        self.latestAgeMillis = latestAgeMillis
        self.encodeFps = encodeFps
        self.encodeBitrateBitsPerSec = encodeBitrateBitsPerSec
        self.keyframeIntervalFrames = keyframeIntervalFrames
        self.encodeMillis = encodeMillis
        self.droppedFrames = droppedFrames
    }
}

/// Thread-safe latest-access-unit store for the H.264 video stream. Mirrors
/// `MJPEGFrameQueue`: viewers read `latestFrame(after:)` non-destructively so a slow
/// client never forces others to repeat stale frames, and `snapshot()` yields rolling
/// encode FPS/bitrate over a short window.
public final class H264FrameQueue: @unchecked Sendable {
    /// Window over which encode FPS and bitrate are averaged.
    static let statsWindow: TimeInterval = 2.0

    private let lock = NSLock()
    private let capacity: Int
    private var dropped: UInt64 = 0
    private var sequence: UInt64 = 0
    private var latest: H264AccessUnit?
    private var lastEncodeMillis: Double = 0
    // Rolling window of recent access units for FPS/bitrate/keyframe-interval.
    private var recent: [(at: Date, bytes: Int, isKeyframe: Bool)] = []

    public init(capacity: Int = 2) {
        self.capacity = max(1, capacity)
    }

    public var droppedFrames: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    public func push(_ data: Data, isKeyframe: Bool, encodeMillis: Double = 0) {
        push(data, isKeyframe: isKeyframe, encodeMillis: encodeMillis, at: Date())
    }

    /// Timestamp-injectable entry point used by tests for deterministic rates.
    func push(_ data: Data, isKeyframe: Bool, encodeMillis: Double, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        if latest != nil { dropped += 1 } // previous unconsumed frame is superseded
        sequence += 1
        latest = H264AccessUnit(data: data, sequence: sequence, capturedAt: date, isKeyframe: isKeyframe)
        if encodeMillis > 0 { lastEncodeMillis = encodeMillis }
        recent.append((at: date, bytes: data.count, isKeyframe: isKeyframe))
        pruneRecent(now: date)
    }

    public func latestFrame(after lastSequence: UInt64?) -> H264AccessUnit? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest else { return nil }
        if let lastSequence, latest.sequence <= lastSequence { return nil }
        return latest
    }

    public func snapshot(now: Date = Date()) -> H264FrameStoreSnapshot {
        lock.lock()
        defer { lock.unlock() }
        pruneRecent(now: now)
        let windowBytes = recent.reduce(0) { $0 + $1.bytes }
        let encodeFps = Double(recent.count) / Self.statsWindow
        let bitrate = Double(windowBytes) * 8.0 / Self.statsWindow
        let keyframes = recent.reduce(0) { $0 + ($1.isKeyframe ? 1 : 0) }
        let keyframeInterval = keyframes > 0 ? Double(recent.count) / Double(keyframes) : 0
        let age = latest.map { max(0, now.timeIntervalSince($0.capturedAt) * 1000) } ?? 0
        return H264FrameStoreSnapshot(
            latestSequence: latest?.sequence ?? 0,
            latestBytes: latest?.data.count ?? 0,
            latestAgeMillis: age,
            encodeFps: encodeFps,
            encodeBitrateBitsPerSec: bitrate,
            keyframeIntervalFrames: keyframeInterval,
            encodeMillis: lastEncodeMillis,
            droppedFrames: dropped
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
