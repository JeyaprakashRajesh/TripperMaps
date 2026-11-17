import CoreLocation

/// GPS only (no compass: the magnetometer is unreliable next to a handlebar and costs power).
/// Heading comes from GPS course; MotionSmoother fills the gaps between 1 Hz fixes.
final class LocationEngine: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private var stationary = false

    /// Delivered on the main thread.
    var onFix: ((CLLocation) -> Void)?
    private(set) var lastFix: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation      // road snapping, nav-grade filtering
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    func requestAuthorization() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func start() {
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        // iOS 17: keeps "When In Use" location alive while the phone is locked.
        backgroundSession = CLBackgroundActivitySession()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        backgroundSession?.invalidate()
        backgroundSession = nil
        manager.allowsBackgroundLocationUpdates = false
    }

    /// Parked at a signal or a chai stop: drop GPS to a cheaper accuracy.
    func setStationary(_ value: Bool) {
        guard value != stationary else { return }
        stationary = value
        manager.desiredAccuracy = value ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyBestForNavigation
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0, l.horizontalAccuracy < 50 else { return }
        lastFix = l
        onFix?(l)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
