import CoreLocation
import MapKit
import QuartzCore

struct RiderState {
    var point: MKMapPoint
    var heading: Double          // degrees, 0 = north, clockwise
    var speed: Double            // m/s
    var metersPerPixel: Double   // zoom: grows with speed so you see further ahead
}

/// The real secret to a "smooth" dash: GPS arrives at ~1 Hz, but every frame we send must move
/// the map by the same small amount. We dead-reckon from the last fix (speed + course) and ease
/// the displayed state toward that prediction, so 10 fps looks like 10 fps instead of
/// 1 jump + 9 duplicates. Even motion also compresses far better (smaller P-frames = less power).
final class MotionSmoother {
    private let lock = NSLock()
    private var fix: CLLocation?
    private var fixTime: CFTimeInterval = 0
    private var course: Double = 0
    private var display: RiderState?
    private var lastFrameTime: CFTimeInterval = 0

    var speed: Double {
        lock.lock(); defer { lock.unlock() }
        return max(0, fix?.speed ?? 0)
    }

    func ingest(_ l: CLLocation) {
        lock.lock()
        fix = l
        fixTime = CACurrentMediaTime()
        if l.course >= 0 && l.speed > 1.5 { course = l.course }   // hold heading when crawling
        lock.unlock()
    }

    func state(at t: CFTimeInterval) -> RiderState? {
        lock.lock(); defer { lock.unlock() }
        guard let f = fix else { return nil }

        let v = max(0, f.speed)
        let dt = min(max(t - fixTime, 0), 1.5)          // don't extrapolate forever (tunnels)
        let ppm = MKMapPointsPerMeterAtLatitude(f.coordinate.latitude)
        let rad = course * .pi / 180
        let base = MKMapPoint(f.coordinate)
        // Map points: +x = east, +y = south.
        let predicted = MKMapPoint(x: base.x + sin(rad) * v * dt * ppm,
                                   y: base.y - cos(rad) * v * dt * ppm)
        let target = RiderState(point: predicted, heading: course, speed: v,
                                metersPerPixel: Self.zoom(forSpeed: v))

        guard var d = display, lastFrameTime > 0 else {
            display = target; lastFrameTime = t
            return target
        }

        let k = min(1, (t - lastFrameTime) * 6)          // ~170 ms easing time constant
        if d.point.distance(to: target.point) > 80 {
            d = target                                   // big GPS correction: snap, don't swim
        } else {
            d.point = MKMapPoint(x: d.point.x + (target.point.x - d.point.x) * k,
                                 y: d.point.y + (target.point.y - d.point.y) * k)
            d.heading = Self.lerpAngle(d.heading, target.heading, k * 0.6)
            d.metersPerPixel += (target.metersPerPixel - d.metersPerPixel) * min(1, k * 0.2)
            d.speed = v
        }
        display = d
        lastFrameTime = t
        return d
    }

    /// ~0.9 m/px in town (≈470 m across the dash), up to 3.2 m/px on the highway.
    static func zoom(forSpeed v: Double) -> Double {
        min(max(0.9 + v * 0.07, 0.9), 3.2)
    }

    static func lerpAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var diff = (b - a).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        var r = a + diff * t
        if r < 0 { r += 360 }
        if r >= 360 { r -= 360 }
        return r
    }
}
