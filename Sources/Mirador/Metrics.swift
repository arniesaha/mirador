import Darwin
import Foundation

public struct MetricsSnapshot: Sendable, Codable, Equatable {
    public let rssBytes: UInt64
    public let activeStreams: Int
    public let fps: Double
    public let droppedFrames: UInt64
    public let latestFrameSequence: UInt64
    public let latestFrameBytes: Int
    public let latestFrameAgeMillis: Double
    public let inputSockets: Int
    public let inputEvents: UInt64
    public let bitrateBitsPerSec: Double
    public let incompleteFrames: UInt64
    public let inputDispatchMillis: Double
    // H.264 (WebCodecs) encode pipeline.
    public let encodeFps: Double
    public let encodeBitrateBitsPerSec: Double
    public let encodeMillis: Double
    public let keyframeIntervalFrames: Double
    public let videoStreams: Int

    public init(
        rssBytes: UInt64,
        activeStreams: Int,
        fps: Double,
        droppedFrames: UInt64,
        latestFrameSequence: UInt64 = 0,
        latestFrameBytes: Int = 0,
        latestFrameAgeMillis: Double = 0,
        inputSockets: Int = 0,
        inputEvents: UInt64 = 0,
        bitrateBitsPerSec: Double = 0,
        incompleteFrames: UInt64 = 0,
        inputDispatchMillis: Double = 0,
        encodeFps: Double = 0,
        encodeBitrateBitsPerSec: Double = 0,
        encodeMillis: Double = 0,
        keyframeIntervalFrames: Double = 0,
        videoStreams: Int = 0
    ) {
        self.rssBytes = rssBytes
        self.activeStreams = activeStreams
        self.fps = fps
        self.droppedFrames = droppedFrames
        self.latestFrameSequence = latestFrameSequence
        self.latestFrameBytes = latestFrameBytes
        self.latestFrameAgeMillis = latestFrameAgeMillis
        self.inputSockets = inputSockets
        self.inputEvents = inputEvents
        self.bitrateBitsPerSec = bitrateBitsPerSec
        self.incompleteFrames = incompleteFrames
        self.inputDispatchMillis = inputDispatchMillis
        self.encodeFps = encodeFps
        self.encodeBitrateBitsPerSec = encodeBitrateBitsPerSec
        self.encodeMillis = encodeMillis
        self.keyframeIntervalFrames = keyframeIntervalFrames
        self.videoStreams = videoStreams
    }
}

public enum ProcessMetrics {
    public static func currentRSSBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    public static func snapshot(activeStreams: Int, frameStore: MJPEGFrameStoreSnapshot, videoStore: H264FrameStoreSnapshot = H264FrameStoreSnapshot(), videoStreams: Int = 0, inputSockets: Int = 0, inputEvents: UInt64 = 0, inputDispatchMillis: Double = 0) -> MetricsSnapshot {
        MetricsSnapshot(
            rssBytes: currentRSSBytes(),
            activeStreams: activeStreams,
            fps: frameStore.captureFps,
            droppedFrames: frameStore.droppedFrames,
            latestFrameSequence: frameStore.latestFrameSequence,
            latestFrameBytes: frameStore.latestFrameBytes,
            latestFrameAgeMillis: frameStore.latestFrameAgeMillis,
            inputSockets: inputSockets,
            inputEvents: inputEvents,
            bitrateBitsPerSec: frameStore.bitrateBitsPerSec,
            incompleteFrames: frameStore.incompleteFrames,
            inputDispatchMillis: inputDispatchMillis,
            encodeFps: videoStore.encodeFps,
            encodeBitrateBitsPerSec: videoStore.encodeBitrateBitsPerSec,
            encodeMillis: videoStore.encodeMillis,
            keyframeIntervalFrames: videoStore.keyframeIntervalFrames,
            videoStreams: videoStreams
        )
    }

    public static func snapshot(activeStreams: Int, fps: Double, droppedFrames: UInt64) -> MetricsSnapshot {
        MetricsSnapshot(
            rssBytes: currentRSSBytes(),
            activeStreams: activeStreams,
            fps: fps,
            droppedFrames: droppedFrames
        )
    }
}
