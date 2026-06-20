import Foundation
import Testing
@testable import Mirador

@Test func captureServiceStartsStopped() async throws {
    let service = ScreenCaptureService(frameQueue: MJPEGFrameQueue(capacity: 1))
    #expect(await service.isRunning == false)
    #expect(await service.capturedFrameStats == CaptureFrameStats())
}

@Test func captureServiceCanRecordSyntheticFrameForTests() async throws {
    let queue = MJPEGFrameQueue(capacity: 1)
    let service = ScreenCaptureService(frameQueue: queue)
    await service.recordSyntheticJPEGFrame(bytes: [0xFF, 0xD8, 0xFF, 0xD9])
    #expect(queue.pop() == Data([0xFF, 0xD8, 0xFF, 0xD9]))
    #expect(await service.capturedFrameStats == CaptureFrameStats(capturedFrames: 1, droppedFrames: 0, lastFrameByteCount: 4))
}

@Test func captureFrameStatsRecordsAndDropsWithoutMutatingOriginal() {
    let initial = CaptureFrameStats()
    let recorded = initial.recorded(byteCount: 1234)
    let dropped = recorded.dropped()

    #expect(initial == CaptureFrameStats())
    #expect(recorded == CaptureFrameStats(capturedFrames: 1, droppedFrames: 0, lastFrameByteCount: 1234))
    #expect(dropped == CaptureFrameStats(capturedFrames: 1, droppedFrames: 1, lastFrameByteCount: 1234))
}

@Test func captureServiceStopIsIdempotentWhenNotStarted() async throws {
    let service = ScreenCaptureService(frameQueue: MJPEGFrameQueue(capacity: 1))
    await service.stop()
    await service.stop()
    #expect(await service.isRunning == false)
}

@Test func captureConsumersTrackPerFormatDemand() {
    let consumers = CaptureConsumers()
    #expect(!consumers.wantsMJPEG)
    #expect(!consumers.wantsH264)

    consumers.setH264(1)
    #expect(consumers.wantsH264)
    #expect(!consumers.wantsMJPEG)   // a video viewer must not force JPEG encoding

    consumers.setMJPEG(2)
    #expect(consumers.wantsMJPEG)

    consumers.setH264(0)
    #expect(!consumers.wantsH264)
    #expect(consumers.wantsMJPEG)    // still one MJPEG viewer
}

@Test func configuredBitrateHonorsDefault() {
    // Without the env override, the default 30 Mbit/s applies.
    if ProcessInfo.processInfo.environment["MIRADOR_H264_BITRATE_KBPS"] == nil {
        #expect(ScreenCaptureService.configuredBitrate() == 30_000_000)
    }
}

@Test func configuredMaxFrameQPHonorsDefault() {
    // Default quality floor keeps text legible during motion.
    if ProcessInfo.processInfo.environment["MIRADOR_H264_MAX_QP"] == nil {
        #expect(ScreenCaptureService.configuredMaxFrameQP() == 26)
    }
}
