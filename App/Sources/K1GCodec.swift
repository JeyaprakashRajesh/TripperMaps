import Foundation

/// The Tripper Dash control plane ("K1G"). This is the one part that must be ported byte-for-byte
/// from a project that has verified it on real bikes. Do NOT guess these bytes.
///
/// What is publicly documented (better-dash README, TripperDash++ README):
///  - Dash is always 192.168.1.1 on its own Wi-Fi (SSID "RE_XXXX_XXXXXX", no internet).
///  - Control: phone sends to UDP 2000, binds locally to UDP 2002; dash sends button events
///    (e.g. `09 00 0001 XX`) and expects acks (e.g. `06 80 0001 XX`).
///  - Handshake: dash sends an RSA public key (`07 00` modulus, `07 03` exponent); the phone
///    replies with an RSA-encrypted session key that embeds the dash SSID; dash answers `07 01 01`.
///  - Then 1 Hz heartbeats (phone battery/charging/GPS/signal status ride along).
///  - Navigation: route card TLV `0x007E`, `q3c.z2` enters navigation, projection on/off TLVs,
///    `q3c.h` + `q3c.x` to leave projection. Next-turn glyphs are `0x00–0x59`.
///  - Video: H.264 RTP to UDP 5000. Dash must be set to the "Digital" screen type.
///  - After a fresh connect the dash may say "iPhone connected" ~28 s before its control task is
///    ready: retry the handshake quietly instead of failing (TripperDash++ v1.0.3 notes).
///
/// Port from:
///  - https://github.com/kolaCZek/better-dash  (Python reference; check its LICENSE)
///  - https://github.com/kolaCZek/TripperDashPlusPlus  (Swift; PolyForm Noncommercial: fine
///    for your own bike, not for selling)
protocol K1GCodec {
    func handshake(send: @escaping (Data) -> Void, receive: @escaping () async throws -> Data) async throws
    func heartbeat(batteryPercent: Int, charging: Bool) -> Data?
    func startProjectionMessages() -> [Data]
    func stopProjectionMessages() -> [Data]
    func maneuver(glyph: UInt8, distanceMeters: Int) -> Data?
    /// Replies (acks) the dash expects for an incoming packet, e.g. button events.
    func replies(to incoming: Data) -> [Data]
}

enum DashError: Error, CustomStringConvertible {
    case codecNotPorted, timeout, noBikeWiFi
    var description: String {
        switch self {
        case .noBikeWiFi: return "Not on the bike's Wi-Fi. Join RE_XXXX_XXXXXX in Settings → Wi-Fi (mobile data stays on)"
        case .codecNotPorted: return "K1G control plane not ported yet (see K1GCodec.swift)"
        case .timeout: return "Dash did not answer (on the bike's Wi-Fi? screen type = Digital?)"
        }
    }
}

/// Placeholder so the project builds. Replace with a real port.
struct UnportedK1GCodec: K1GCodec {
    func handshake(send: @escaping (Data) -> Void, receive: @escaping () async throws -> Data) async throws {
        throw DashError.codecNotPorted
    }
    func heartbeat(batteryPercent: Int, charging: Bool) -> Data? { nil }
    func startProjectionMessages() -> [Data] { [] }
    func stopProjectionMessages() -> [Data] { [] }
    func maneuver(glyph: UInt8, distanceMeters: Int) -> Data? { nil }
    func replies(to incoming: Data) -> [Data] { [] }
}
