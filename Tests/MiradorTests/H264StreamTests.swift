import Foundation
import Testing
@testable import Mirador

@Test func h264QueuePublishesLatestAccessUnitWithoutConsuming() async throws {
    let queue = H264FrameQueue(capacity: 2)
    queue.push(Data([1, 2, 3]), isKeyframe: true)
    queue.push(Data([4, 5]), isKeyframe: false)

    let first = queue.latestFrame(after: nil)
    #expect(first?.data == Data([4, 5]))
    #expect(first?.sequence == 2)
    #expect(first?.isKeyframe == false)

    // Non-destructive: reading again yields the same frame.
    #expect(queue.latestFrame(after: nil)?.sequence == 2)
    // Already-seen sequence yields nothing.
    #expect(queue.latestFrame(after: 2) == nil)
}

@Test func h264QueueComputesEncodeFpsBitrateAndKeyframeInterval() async throws {
    let queue = H264FrameQueue(capacity: 8)
    let t0 = Date(timeIntervalSince1970: 3_000_000)
    // 4 frames over 0.75s window, 100 bytes each, every other a keyframe.
    for i in 0..<4 {
        queue.push(Data(repeating: 0xAB, count: 100), isKeyframe: i % 2 == 0, encodeMillis: 5, at: t0.addingTimeInterval(Double(i) * 0.25))
    }
    let snapshot = queue.snapshot(now: t0.addingTimeInterval(0.75))
    // window = 2.0s; 4 frames -> 2.0 fps; 400 bytes -> 1600 bit/s
    #expect(snapshot.encodeFps == 2.0)
    #expect(snapshot.encodeBitrateBitsPerSec == 1600)
    // 4 frames / 2 keyframes -> avg interval of 2 frames
    #expect(snapshot.keyframeIntervalFrames == 2.0)
    #expect(snapshot.encodeMillis == 5)
}

@Test func h264QueueEmptySnapshotHasFiniteZeroRates() async throws {
    let snapshot = H264FrameQueue(capacity: 1).snapshot()
    #expect(snapshot.encodeFps == 0)
    #expect(snapshot.encodeBitrateBitsPerSec == 0)
    #expect(snapshot.keyframeIntervalFrames == 0)
    #expect(snapshot.encodeFps.isFinite)
    #expect(snapshot.encodeBitrateBitsPerSec.isFinite)
}

@Test func h264QueueReportsLatestAgeAndBytes() async throws {
    let queue = H264FrameQueue(capacity: 1)
    queue.push(Data([1, 2, 3, 4]), isKeyframe: true)
    let snapshot = queue.snapshot()
    #expect(snapshot.latestSequence == 1)
    #expect(snapshot.latestBytes == 4)
    #expect(snapshot.latestAgeMillis >= 0)
}
