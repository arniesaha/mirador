import Foundation
import Testing
@testable import Mirador

@Test func frameQueueKeepsNewestFrameWhenCapacityIsOne() async throws {
    let queue = MJPEGFrameQueue(capacity: 1)
    queue.push(Data([1]))
    queue.push(Data([2]))

    #expect(queue.droppedFrames == 1)
    #expect(queue.pop() == Data([2]))
    #expect(queue.pop() == nil)
}

@Test func frameQueuePublishesLatestFrameWithoutConsumingIt() async throws {
    let queue = MJPEGFrameQueue(capacity: 3)
    queue.push(Data([1]))
    queue.push(Data([2]))

    let first = queue.latestFrame(after: nil)
    #expect(first?.jpeg == Data([2]))
    #expect(first?.sequence == 2)

    let repeatRead = queue.latestFrame(after: nil)
    #expect(repeatRead?.jpeg == Data([2]))
    #expect(repeatRead?.sequence == 2)

    #expect(queue.latestFrame(after: 2) == nil)
}

@Test func frameQueueComputesCaptureFpsAndBitrateOverWindow() async throws {
    let queue = MJPEGFrameQueue(capacity: 4)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    for i in 0..<4 {
        queue.push(Data(repeating: 0xAB, count: 100), at: t0.addingTimeInterval(Double(i) * 0.25))
    }
    let snapshot = queue.snapshot(now: t0.addingTimeInterval(0.75))
    // window = 2.0s; 4 frames -> 2.0 fps; 400 bytes -> 3200 bits / 2.0 = 1600 bit/s
    #expect(snapshot.captureFps == 2.0)
    #expect(snapshot.bitrateBitsPerSec == 1600)
}

@Test func frameQueueDropsCaptureSamplesOutsideStatsWindow() async throws {
    let queue = MJPEGFrameQueue(capacity: 10)
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    queue.push(Data([1]), at: t0)                              // older than the window
    queue.push(Data([2]), at: t0.addingTimeInterval(3.0))     // within the window
    let snapshot = queue.snapshot(now: t0.addingTimeInterval(3.0))
    #expect(snapshot.captureFps == 1.0 / MJPEGFrameQueue.statsWindow)   // 0.5
}

@Test func frameQueueCountsIncompleteFramesSeparately() async throws {
    let queue = MJPEGFrameQueue(capacity: 2)
    queue.recordIncompleteFrame()
    queue.recordIncompleteFrame()
    let snapshot = queue.snapshot()
    #expect(snapshot.incompleteFrames == 2)
    #expect(snapshot.droppedFrames == 0)   // distinct from queue-overflow drops
}

@Test func frameQueueEmptySnapshotHasFiniteZeroRates() async throws {
    let snapshot = MJPEGFrameQueue(capacity: 1).snapshot()
    #expect(snapshot.captureFps == 0)
    #expect(snapshot.bitrateBitsPerSec == 0)
    #expect(snapshot.captureFps.isFinite)
    #expect(snapshot.bitrateBitsPerSec.isFinite)
}

@Test func frameQueueReportsLatestFrameAgeAndByteCount() async throws {
    let queue = MJPEGFrameQueue(capacity: 1)
    queue.push(Data([1, 2, 3]))

    let snapshot = queue.snapshot()
    #expect(snapshot.latestFrameSequence == 1)
    #expect(snapshot.latestFrameBytes == 3)
    #expect(snapshot.latestFrameAgeMillis >= 0)
}
