import CoreLocation
import MapKit

/// Fake GPS for desk testing: "rides" along the Apple Maps route (or a 400 m loop around you
/// for a free ride) at a fixed speed, emitting a 1 Hz fix exactly like real GPS would.
final class RideSimulator {
    private let points: [MKMapPoint]
    private let speed: Double                 // m/s
    private var timer: DispatchSourceTimer?
    private var segment = 0
    private var along = 0.0                   // metres into the current segment
    var onFix: ((CLLocation) -> Void)?

    init(route: MKPolyline?, around center: CLLocationCoordinate2D, speedKmh: Double) {
        speed = speedKmh / 3.6
        if let r = route, r.pointCount > 1 {
            points = Array(UnsafeBufferPointer(start: r.points(), count: r.pointCount))
        } else {
            // 400 m radius loop, 48 vertices, clockwise from north.
            let c = MKMapPoint(center)
            let radius = 400 * MKMapPointsPerMeterAtLatitude(center.latitude)
            points = (0...48).map { i in
                let a = Double(i) / 48 * 2 * .pi
                return MKMapPoint(x: c.x + sin(a) * radius, y: c.y - cos(a) * radius)
            }
        }
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func tick() {
        guard points.count > 1 else { return }
        var remaining = speed                  // metres to travel this second
        while true {
            let a = points[segment], b = points[(segment + 1) % points.count]
            let len = a.distance(to: b)
            if along + remaining <= len || len == 0 {
                along += remaining
                break
            }
            remaining -= (len - along)
            along = 0
            segment = (segment + 1) % (points.count - 1)   // loop back to the start at the end
        }
        let a = points[segment], b = points[(segment + 1) % points.count]
        let len = max(a.distance(to: b), 0.001)
        let t = min(along / len, 1)
        let p = MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        // Course: 0 = north, clockwise. Map y grows southward.
        var course = atan2(b.x - a.x, -(b.y - a.y)) * 180 / .pi
        if course < 0 { course += 360 }
        let fix = CLLocation(coordinate: p.coordinate, altitude: 0, horizontalAccuracy: 5,
                             verticalAccuracy: 5, course: course, courseAccuracy: 5,
                             speed: speed, speedAccuracy: 0.5, timestamp: Date())
        onFix?(fix)
    }
}
