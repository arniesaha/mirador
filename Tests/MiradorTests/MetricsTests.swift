import Testing
@testable import Mirador

@Test func currentRSSBytesIsPositive() async throws {
    let rss = ProcessMetrics.currentRSSBytes()
    #expect(rss > 0)
}

@Test func metricsSnapshotContainsRSS() async throws {
    let snapshot = ProcessMetrics.snapshot(activeStreams: 0, fps: 0, droppedFrames: 0)
    #expect(snapshot.rssBytes > 0)
    #expect(snapshot.activeStreams == 0)
    #expect(snapshot.fps == 0)
    #expect(snapshot.droppedFrames == 0)
}
