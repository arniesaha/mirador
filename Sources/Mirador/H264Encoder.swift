import Foundation
import CoreMedia
import CoreVideo
#if canImport(VideoToolbox)
import VideoToolbox
#endif

/// Hardware H.264 encoder wrapping a `VTCompressionSession`, tuned for low-latency
/// real-time streaming (no B-frames, real-time mode, periodic IDR). Each encoded
/// access unit is emitted in Annex-B form via `onAccessUnit(annexB, isKeyframe, encodeMillis)`;
/// SPS/PPS are prepended ahead of every keyframe so a freshly-connected WebCodecs
/// decoder can configure itself without a separate avcC description.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`, and the VideoToolbox
/// session is internally thread-safe for encode submission from the capture queue.
public final class H264Encoder: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var width: Int
        public var height: Int
        public var fps: Int
        public var bitrate: Int
        /// Quality floor: the encoder may not exceed this H.264 quantizer (1–51, lower = sharper),
        /// so text stays legible during motion instead of the rate controller softening it. 0 = unset.
        public var maxFrameQP: Int
        public init(width: Int, height: Int, fps: Int = 30, bitrate: Int = 8_000_000, maxFrameQP: Int = 0) {
            self.width = width
            self.height = height
            self.fps = fps
            self.bitrate = bitrate
            self.maxFrameQP = maxFrameQP
        }
    }

    private let onAccessUnit: (Data, Bool, Double) -> Void
    private let lock = NSLock()
    private var forceKeyframe = false
    private var frameIndex: Int64 = 0
    private let timescale: Int32

    #if canImport(VideoToolbox)
    private var session: VTCompressionSession?
    #endif

    /// Returns nil when a VideoToolbox session cannot be created (or VideoToolbox is
    /// unavailable on the platform), so the caller can fall back to MJPEG-only.
    public init?(configuration: Configuration, onAccessUnit: @escaping (Data, Bool, Double) -> Void) {
        self.onAccessUnit = onAccessUnit
        self.timescale = Int32(max(1, configuration.fps) * 1000)

        #if canImport(VideoToolbox)
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let session = created else { return nil }
        self.session = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // High profile compresses screen text/detail better per bit than Main; Safari decodes it.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: configuration.bitrate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: configuration.fps))
        // Bound the keyframe interval so a viewer that joins mid-GOP recovers within ~2s
        // even if an explicit keyframe request is missed.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: configuration.fps * 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2))
        // Quality floor for legible text during motion (macOS 13+; harmless no-op if unsupported).
        if configuration.maxFrameQP > 0 {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: NSNumber(value: configuration.maxFrameQP))
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        #else
        return nil
        #endif
    }

    /// Request that the next encoded frame be an IDR keyframe (e.g. when a new viewer
    /// connects while capture is already running).
    public func requestKeyframe() {
        lock.lock()
        forceKeyframe = true
        lock.unlock()
    }

    /// Submit a captured pixel buffer for encoding. Safe to call from the capture queue.
    public func encode(_ pixelBuffer: CVPixelBuffer) {
        #if canImport(VideoToolbox)
        guard let session else { return }

        lock.lock()
        let force = forceKeyframe
        forceKeyframe = false
        let pts = CMTime(value: frameIndex, timescale: timescale)
        frameIndex += 1
        lock.unlock()

        var frameProperties: CFDictionary?
        if force {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        }

        let start = DispatchTime.now()
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self, status == noErr, let sampleBuffer else { return }
            let millis = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
            self.handleEncoded(sampleBuffer, encodeMillis: millis)
        }
        #endif
    }

    public func invalidate() {
        #if canImport(VideoToolbox)
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        #endif
    }

    #if canImport(VideoToolbox)
    private func handleEncoded(_ sampleBuffer: CMSampleBuffer, encodeMillis: Double) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let isKeyframe = Self.isKeyframe(sampleBuffer)

        var annexB = Data()
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            annexB.append(Self.parameterSetsAnnexB(format))
        }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let dataPointer else { return }

        // VideoToolbox emits AVCC: each NAL unit prefixed by a 4-byte big-endian length.
        // Rewrite to Annex-B (00 00 00 01 start codes) for WebCodecs.
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        var offset = 0
        while offset + 4 <= totalLength {
            var naluLength: UInt32 = 0
            memcpy(&naluLength, dataPointer + offset, 4)
            naluLength = CFSwapInt32BigToHost(naluLength)
            let nalStart = offset + 4
            guard naluLength > 0, nalStart + Int(naluLength) <= totalLength else { break }
            annexB.append(contentsOf: startCode)
            dataPointer.withMemoryRebound(to: UInt8.self, capacity: totalLength) { base in
                annexB.append(base + nalStart, count: Int(naluLength))
            }
            offset = nalStart + Int(naluLength)
        }

        guard !annexB.isEmpty else { return }
        onAccessUnit(annexB, isKeyframe, encodeMillis)
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true // no attachments: treat as sync sample
        }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }

    private static func parameterSetsAnnexB(_ format: CMFormatDescription) -> Data {
        var data = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr else {
            return data
        }
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
               let pointer {
                data.append(contentsOf: startCode)
                data.append(pointer, count: size)
            }
        }
        return data
    }
    #endif
}
