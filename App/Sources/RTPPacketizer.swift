import Foundation
import CoreMedia

/// RFC 6184 H.264 over RTP: single-NAL packets when they fit, FU-A fragments otherwise.
/// 1200-byte payloads leave headroom on the bike's Wi-Fi (better-dash defaults to 1380 and
/// suggests 1000–1200 when the link is lossy).
/// VERIFY against better-dash's packetizer: payload type and any dash-specific quirks.
struct RTPPacketizer {
    var maxPayload = 1200
    var payloadType: UInt8 = 96
    private var seq = UInt16.random(in: 0...UInt16.max)
    private let ssrc = UInt32.random(in: 1...UInt32.max)

    mutating func packets(for nalus: [Data], pts: CMTime) -> [Data] {
        let ts = UInt32(truncatingIfNeeded: Int64(CMTimeGetSeconds(pts) * 90_000))
        var out: [Data] = []
        for (i, nal) in nalus.enumerated() where !nal.isEmpty {
            let lastNal = i == nalus.count - 1
            if nal.count <= maxPayload {
                var p = header(marker: lastNal, ts: ts)
                p.append(nal)
                out.append(p)
                continue
            }
            let hdr = nal[nal.startIndex]
            let fuIndicator = (hdr & 0xE0) | 28
            let type = hdr & 0x1F
            var off = nal.startIndex + 1
            var first = true
            while off < nal.endIndex {
                let n = min(maxPayload - 2, nal.endIndex - off)
                let isEnd = off + n == nal.endIndex
                var fuHeader = type
                if first { fuHeader |= 0x80 }
                if isEnd { fuHeader |= 0x40 }
                var p = header(marker: lastNal && isEnd, ts: ts)
                p.append(fuIndicator)
                p.append(fuHeader)
                p.append(nal[off..<(off + n)])
                out.append(p)
                off += n
                first = false
            }
        }
        return out
    }

    private mutating func header(marker: Bool, ts: UInt32) -> Data {
        var d = Data(capacity: 12 + maxPayload)
        d.append(0x80)                                   // V=2, no padding/extension/CSRC
        d.append((marker ? 0x80 : 0) | (payloadType & 0x7F))
        d.append(UInt8(seq >> 8)); d.append(UInt8(seq & 0xFF))
        seq &+= 1
        for shift in stride(from: 24, through: 0, by: -8) { d.append(UInt8((ts >> UInt32(shift)) & 0xFF)) }
        for shift in stride(from: 24, through: 0, by: -8) { d.append(UInt8((ssrc >> UInt32(shift)) & 0xFF)) }
        return d
    }
}
