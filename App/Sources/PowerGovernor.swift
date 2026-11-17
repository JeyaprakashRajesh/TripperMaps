import Foundation
import QuartzCore

struct StreamTier: Equatable {
    let name: String
    let fps: Int
    let bitrate: Int
}

/// Picks frame rate + bitrate from speed, battery, thermal state and Low Power Mode.
/// 12 fps is the ceiling: the dash decoder starts blinking above ~12 fps (TripperDash++ PR #150).
final class PowerGovernor {
    static let turbo  = StreamTier(name: "Turbo",  fps: 12, bitrate: 650_000)
    static let smooth = StreamTier(name: "Smooth", fps: 10, bitrate: 550_000)
    static let eco    = StreamTier(name: "Eco",    fps: 6,  bitrate: 400_000)
    static let parked = StreamTier(name: "Parked", fps: 1,  bitrate: 200_000)

    private let lock = NSLock()
    private var battery: Float = 1
    private var charging = false
    private var stationarySince: CFTimeInterval?
    var allowTurbo = false

    /// Called from the main thread every few seconds.
    func updateDevice(batteryLevel: Float, charging: Bool) {
        lock.lock(); battery = batteryLevel < 0 ? 1 : batteryLevel; self.charging = charging; lock.unlock()
    }

    var deviceStatus: (percent: Int, charging: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (Int(battery * 100), charging)
    }

    func tier(speed: Double, now: CFTimeInterval) -> StreamTier {
        lock.lock(); defer { lock.unlock() }

        if speed < 0.8 { stationarySince = stationarySince ?? now } else { stationarySince = nil }
        if let s = stationarySince, now - s > 8 { return Self.parked }

        let info = ProcessInfo.processInfo
        let hot = info.thermalState == .serious || info.thermalState == .critical
        if hot || info.isLowPowerModeEnabled || (!charging && battery < 0.2) { return Self.eco }
        if allowTurbo && charging && info.thermalState == .nominal { return Self.turbo }
        return Self.smooth
    }
}
