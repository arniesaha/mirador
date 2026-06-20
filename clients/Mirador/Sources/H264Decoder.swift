import Foundation
import CoreMedia

/// Turns the server's Annex-B H.264 access units into `CMSampleBuffer`s ready for an
/// `AVSampleBufferDisplayLayer`. Builds the format description from the SPS/PPS carried on each
/// keyframe (High profile), and converts Annex-B start-code NALs to the length-prefixed (AVCC)
/// form `CMBlockBuffer` expects.
final class H264Decoder {
    private var formatDescription: CMFormatDescription?
    private let onSample: (CMSampleBuffer) -> Void
    /// Reports the decoded video dimensions when the format description is (re)built.
    var onFormat: ((CGSize) -> Void)?

    init(onSample: @escaping (CMSampleBuffer) -> Void) {
        self.onSample = onSample
    }

    /// Feed one access unit. `annexB` is the payload after our 17-byte wire header.
    func decode(annexB: Data, isKeyframe: Bool) {
        let nals = Self.splitAnnexB(annexB)
        if isKeyframe {
            let sps = nals.first { ($0.first.map { $0 & 0x1F } ?? 0) == 7 }
            let pps = nals.first { ($0.first.map { $0 & 0x1F } ?? 0) == 8 }
            if let sps, let pps, let fmt = Self.makeFormatDescription(sps: sps, pps: pps) {
                formatDescription = fmt
                let dims = CMVideoFormatDescriptionGetDimensions(fmt)
                onFormat?(CGSize(width: Int(dims.width), height: Int(dims.height)))
            }
        }
        guard let fmt = formatDescription else { return } // wait for the first keyframe

        // Keep VCL/SEI NALs; SPS(7)/PPS(8) live in the format description, AUD(9) is dropped.
        let payloadNals = nals.filter {
            let t = ($0.first.map { $0 & 0x1F } ?? 0)
            return t != 7 && t != 8 && t != 9
        }
        guard !payloadNals.isEmpty else { return }

        var avcc = Data()
        for nal in payloadNals {
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        if let sample = Self.makeSampleBuffer(avcc: avcc, format: fmt) {
            onSample(sample)
        }
    }

    // MARK: - Annex-B parsing

    /// Split an Annex-B buffer into raw NAL units (start codes stripped).
    static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        let n = bytes.count
        var nals: [Data] = []
        func isStart(_ p: Int) -> Bool {
            p + 3 < n && bytes[p] == 0 && bytes[p + 1] == 0 &&
                (bytes[p + 2] == 1 || (bytes[p + 2] == 0 && p + 3 < n && bytes[p + 3] == 1))
        }
        var i = 0
        while i < n && !isStart(i) { i += 1 }
        while i < n {
            let scLen = (bytes[i + 2] == 1) ? 3 : 4
            let start = i + scLen
            var j = start
            while j < n && !isStart(j) { j += 1 }
            if j > start { nals.append(Data(bytes[start..<j])) }
            i = j
        }
        return nals
    }

    private static func makeFormatDescription(sps: Data, pps: Data) -> CMFormatDescription? {
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)
        return spsBytes.withUnsafeBufferPointer { spsBuf in
            ppsBytes.withUnsafeBufferPointer { ppsBuf in
                let pointers = [spsBuf.baseAddress!, ppsBuf.baseAddress!]
                let sizes = [spsBytes.count, ppsBytes.count]
                var fmt: CMFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &fmt
                )
                return status == noErr ? fmt : nil
            }
        }
    }

    private static func makeSampleBuffer(avcc: Data, format: CMFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let bb = blockBuffer else { return nil }
        status = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sample: CMSampleBuffer?
        var sizes = [avcc.count]
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sizes,
            sampleBufferOut: &sample
        )
        guard status == noErr, let s = sample else { return nil }

        // Render as soon as it arrives (real-time, no PTS scheduling).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return s
    }
}
