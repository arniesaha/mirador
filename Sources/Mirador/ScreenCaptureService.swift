import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

/// Live per-format consumer demand, shared between the HTTP server (which knows how many
/// MJPEG vs video viewers are connected) and the capture callback (which uses it to skip
/// whichever encoder has no consumer). Both encoders are hardware-accelerated but still
/// cost power, so we only run the one a viewer is actually watching.
public final class CaptureConsumers: @unchecked Sendable {
    private let lock = NSLock()
    private var mjpeg = 0
    private var h264 = 0

    public init() {}

    public var wantsMJPEG: Bool { lock.lock(); defer { lock.unlock() }; return mjpeg > 0 }
    public var wantsH264: Bool { lock.lock(); defer { lock.unlock() }; return h264 > 0 }

    public func setMJPEG(_ count: Int) { lock.lock(); mjpeg = max(0, count); lock.unlock() }
    public func setH264(_ count: Int) { lock.lock(); h264 = max(0, count); lock.unlock() }
}

public actor ScreenCaptureService {
    /// Capture/encode frame rate. The H.264 path targets ~30 fps for near-native feel;
    /// the MJPEG fallback rides the same capture clock.
    static let captureFps = 30

    private let frameQueue: MJPEGFrameQueue
    private let h264Queue: H264FrameQueue
    private let consumers: CaptureConsumers
    private var running = false
    private var stream: AnyObject?
    private var streamOutput: AnyObject?
    private var h264Encoder: H264Encoder?
    private var frameStats = CaptureFrameStats()

    public init(frameQueue: MJPEGFrameQueue, h264Queue: H264FrameQueue = H264FrameQueue(capacity: 2), consumers: CaptureConsumers = CaptureConsumers()) {
        self.frameQueue = frameQueue
        self.h264Queue = h264Queue
        self.consumers = consumers
    }

    /// H.264 average bitrate (bits/s); override with `MIRADOR_H264_BITRATE_KBPS` for tuning.
    /// Default is generous (30 Mbit/s) so text stays readable during motion on LAN/Tailscale —
    /// still well under the MJPEG path's bandwidth, and H.264 collapses to a trickle when idle.
    static func configuredBitrate() -> Int {
        if let raw = ProcessInfo.processInfo.environment["MIRADOR_H264_BITRATE_KBPS"],
           let kbps = Int(raw.trimmingCharacters(in: .whitespaces)), kbps > 0 {
            return kbps * 1000
        }
        return 30_000_000
    }

    /// Max-allowed H.264 quantizer (1–51, lower = sharper). Default 26 keeps text legible
    /// during motion; override with `MIRADOR_H264_MAX_QP`.
    static func configuredMaxFrameQP() -> Int {
        if let raw = ProcessInfo.processInfo.environment["MIRADOR_H264_MAX_QP"],
           let qp = Int(raw.trimmingCharacters(in: .whitespaces)), (1...51).contains(qp) {
            return qp
        }
        return 26
    }

    public var isRunning: Bool { running }
    public var capturedFrameStats: CaptureFrameStats { frameStats }

    public func start() async throws {
        guard !running else { return }

        #if canImport(ScreenCaptureKit)
        do {
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                throw ScreenCaptureServiceError.screenRecordingPermissionDenied
            }

            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = Self.selectDisplay(from: content.displays) else {
                throw ScreenCaptureServiceError.noDisplayAvailable
            }

            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = false
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.captureFps))
            configuration.queueDepth = 3
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = true
            // H.264 is bandwidth-cheap, so capture at native width for sharp text on the
            // viewer (the MJPEG fallback gets heavier, but it is only a fallback).
            let maxWidth = 1920
            if display.width > maxWidth {
                configuration.width = maxWidth
                configuration.height = max(1, Int(Double(display.height) * Double(maxWidth) / Double(display.width)))
            } else {
                configuration.width = display.width
                configuration.height = display.height
            }

            // Hardware H.264 encoder feeding the WebCodecs viewer path. Created here so it
            // exists only while capturing (idle = no VideoToolbox session). MJPEG still
            // works if the session can't be created.
            let encoder = H264Encoder(
                configuration: H264Encoder.Configuration(width: configuration.width, height: configuration.height, fps: Self.captureFps, bitrate: Self.configuredBitrate(), maxFrameQP: Self.configuredMaxFrameQP()),
                onAccessUnit: { [h264Queue] data, isKeyframe, encodeMillis in
                    h264Queue.push(data, isKeyframe: isKeyframe, encodeMillis: encodeMillis)
                }
            )
            if encoder == nil {
                log("VideoToolbox H.264 session unavailable; MJPEG-only this session")
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let output = ScreenCaptureStreamOutput(owner: self, h264Encoder: encoder, consumers: consumers)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: ScreenCaptureStreamOutput.sampleQueue)
            try await stream.startCapture()

            self.stream = stream
            self.streamOutput = output
            self.h264Encoder = encoder
            self.frameStats = CaptureFrameStats()
            self.running = true
            log("ScreenCaptureKit capture started for displayID=\(display.displayID) captureSize=\(configuration.width)x\(configuration.height) displaySize=\(display.width)x\(display.height) at ~\(Self.captureFps) fps (h264=\(encoder != nil))")
        } catch {
            self.running = false
            log("ScreenCaptureKit capture failed: \(error). Grant Screen Recording permission to the built mirador executable in System Settings > Privacy & Security > Screen & System Audio Recording, then restart mirador.")
            throw error
        }
        #else
        throw ScreenCaptureServiceError.screenCaptureKitUnavailable
        #endif
    }

    public func stop() async {
        guard running || stream != nil else {
            running = false
            return
        }

        #if canImport(ScreenCaptureKit)
        if let stream = stream as? SCStream {
            do {
                try await stream.stopCapture()
            } catch {
                log("ScreenCaptureKit stop failed: \(error)")
            }
        }
        #endif
        h264Encoder?.invalidate()
        h264Encoder = nil
        stream = nil
        streamOutput = nil
        running = false
    }

    /// Asks the H.264 encoder to emit an IDR on its next frame (e.g. when a new viewer
    /// connects while capture is already running). No-op when not capturing.
    public func requestKeyframe() {
        h264Encoder?.requestKeyframe()
    }

    public func recordSyntheticJPEGFrame(bytes: [UInt8]) async {
        frameQueue.push(Data(bytes))
        frameStats = frameStats.recorded(byteCount: bytes.count)
    }

    fileprivate func receiveCapturedJPEG(_ jpeg: Data?) async {
        guard running else { return }
        guard let jpeg else {
            frameStats = frameStats.dropped()
            frameQueue.recordIncompleteFrame()
            return
        }
        frameQueue.push(jpeg)
        frameStats = frameStats.recorded(byteCount: jpeg.count)
    }

    #if canImport(ScreenCaptureKit)
    private static func selectDisplay(from displays: [SCDisplay]) -> SCDisplay? {
        let mainDisplayID = CGMainDisplayID()
        return displays.first(where: { $0.displayID == mainDisplayID }) ?? displays.max { lhs, rhs in
            (lhs.width * lhs.height) < (rhs.width * rhs.height)
        }
    }
    #endif

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("mirador: \(message)\n".utf8))
    }
}

public enum ScreenCaptureServiceError: Error, CustomStringConvertible, Equatable {
    case noDisplayAvailable
    case screenRecordingPermissionDenied
    case screenCaptureKitUnavailable

    public var description: String {
        switch self {
        case .noDisplayAvailable:
            return "No capturable display is available"
        case .screenRecordingPermissionDenied:
            return "Screen Recording permission is not granted"
        case .screenCaptureKitUnavailable:
            return "ScreenCaptureKit is unavailable on this platform"
        }
    }
}

public struct CaptureFrameStats: Equatable, Sendable {
    public let capturedFrames: UInt64
    public let droppedFrames: UInt64
    public let lastFrameByteCount: Int

    public init(capturedFrames: UInt64 = 0, droppedFrames: UInt64 = 0, lastFrameByteCount: Int = 0) {
        self.capturedFrames = capturedFrames
        self.droppedFrames = droppedFrames
        self.lastFrameByteCount = lastFrameByteCount
    }

    public func recorded(byteCount: Int) -> CaptureFrameStats {
        CaptureFrameStats(capturedFrames: capturedFrames + 1, droppedFrames: droppedFrames, lastFrameByteCount: byteCount)
    }

    public func dropped() -> CaptureFrameStats {
        CaptureFrameStats(capturedFrames: capturedFrames, droppedFrames: droppedFrames + 1, lastFrameByteCount: lastFrameByteCount)
    }
}

enum ScreenCaptureSampleValidator {
    static func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        #if canImport(ScreenCaptureKit)
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRawValue = attachments.first?[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue) else {
            return sampleBuffer.isValid
        }
        return status == .complete
        #else
        return sampleBuffer.isValid
        #endif
    }
}

#if canImport(CoreImage)
final class ScreenCaptureJPEGEncoder: @unchecked Sendable {
    static let shared = ScreenCaptureJPEGEncoder()

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    func jpegData(from pixelBuffer: CVPixelBuffer, quality: CGFloat) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return context.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        )
    }
}
#else
final class ScreenCaptureJPEGEncoder: @unchecked Sendable {
    static let shared = ScreenCaptureJPEGEncoder()
    func jpegData(from pixelBuffer: CVPixelBuffer, quality: Double) -> Data? { nil }
}
#endif

#if canImport(ScreenCaptureKit)
private final class ScreenCaptureStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let sampleQueue = DispatchQueue(label: "mirador.screen-capture.samples", qos: .userInitiated)

    private let owner: ScreenCaptureService
    private let h264Encoder: H264Encoder?
    private let consumers: CaptureConsumers

    init(owner: ScreenCaptureService, h264Encoder: H264Encoder?, consumers: CaptureConsumers) {
        self.owner = owner
        self.h264Encoder = h264Encoder
        self.consumers = consumers
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }

        let pixelBuffer = ScreenCaptureSampleValidator.isCompleteScreenFrame(sampleBuffer)
            ? CMSampleBufferGetImageBuffer(sampleBuffer)
            : nil

        // Only run the encoder a viewer is actually watching (both are HW-accelerated but
        // still cost power). H.264 for the WebCodecs path; CoreImage JPEG for MJPEG.
        if let pixelBuffer, consumers.wantsH264 {
            h264Encoder?.encode(pixelBuffer)
        }
        if consumers.wantsMJPEG {
            let jpeg = pixelBuffer.flatMap { ScreenCaptureJPEGEncoder.shared.jpegData(from: $0, quality: 0.62) }
            Task { [owner] in
                await owner.receiveCapturedJPEG(jpeg)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("mirador: ScreenCaptureKit stream stopped: \(error)\n".utf8))
    }
}
#endif
