import VideoToolbox
import CoreMedia

enum EncoderError: Error { case create(OSStatus) }

/// Hardware H.264 (Apple media engine): far cheaper than any software path.
/// Baseline profile, no B-frames, 1 s keyframes: what the dash decoder accepts.
final class H264Encoder {
    private var session: VTCompressionSession?
    /// NAL units without start codes (SPS/PPS prepended on keyframes) + presentation time.
    var onAccessUnit: (([Data], CMTime) -> Void)?
    private(set) var bytesOut = 0

    init(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { throw EncoderError.create(status) }
        session = s
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1.0 as CFNumber)
        setFrameRate(fps)
        setBitrate(bitrate)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    func setFrameRate(_ fps: Int) {
        guard let s = session else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
    }

    func setBitrate(_ bps: Int) {
        guard let s = session else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        // Hard ceiling: 1.5× average per second, so a rotation-heavy frame can't spike the dash.
        let limits = [NSNumber(value: Double(bps) * 1.5 / 8), NSNumber(value: 1.0)] as CFArray
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    func encode(_ pb: CVPixelBuffer, pts: CMTime, forceKeyFrame: Bool = false) {
        guard let s = session else { return }
        let props: CFDictionary? = forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard status == noErr, let sb else { return }
            self?.handle(sb)
        }
    }

    func invalidate() {
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
        session = nil
    }

    private func handle(_ sb: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sb), let block = CMSampleBufferGetDataBuffer(sb) else { return }
        var nalus: [Data] = []

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        if !notSync, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    nalus.append(Data(bytes: ptr, count: size))
                }
            }
        }

        // AVCC (4-byte length prefixes) -> individual NAL units.
        let total = CMBlockBufferGetDataLength(block)
        var buf = Data(count: total)
        let st = buf.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: $0.baseAddress!) }
        guard st == noErr else { return }
        var off = 0
        while off + 4 <= total {
            let len = Int(buf[off]) << 24 | Int(buf[off + 1]) << 16 | Int(buf[off + 2]) << 8 | Int(buf[off + 3])
            off += 4
            guard len > 0, off + len <= total else { break }
            nalus.append(buf.subdata(in: off..<(off + len)))
            off += len
        }
        bytesOut += total
        onAccessUnit?(nalus, CMSampleBufferGetPresentationTimeStamp(sb))
    }
}
