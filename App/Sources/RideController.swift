import Foundation
import MapKit
import UIKit

struct StreamStats {
    var fps: Double = 0
    var kbps: Int = 0
    var tier: String = "-"
    var missingTiles: Int = 0
}

/// UI-facing orchestrator. Everything heavy runs inside `DashStreamer` off the main thread.
@MainActor
final class RideController: ObservableObject {
    enum Phase: Equatable {
        case idle, routing, preparingMap(done: Int, total: Int), connecting, streaming, error(String)
    }

    @Published var phase: Phase = .idle
    @Published var searchResults: [MKMapItem] = []
    @Published var stats = StreamStats()
    @Published var darkMap = true
    @Published var allowTurbo = false { didSet { streamer?.governor.allowTurbo = allowTurbo } }
    @Published var preview: CGImage?

    // Desk testing (no bike), remembered between launches.
    @Published var testMode = UserDefaults.standard.bool(forKey: "testMode") {
        didSet { UserDefaults.standard.set(testMode, forKey: "testMode") } }
    @Published var testHost = UserDefaults.standard.string(forKey: "testHost") ?? "192.168.1.10" {
        didSet { UserDefaults.standard.set(testHost, forKey: "testHost") } }
    @Published var simulateRide = UserDefaults.standard.bool(forKey: "simulateRide") {
        didSet { UserDefaults.standard.set(simulateRide, forKey: "simulateRide") } }
    @Published var simSpeedKmh = 40.0

    let location = LocationEngine()
    let tiles = AppleMapTileCache()
    private var routeLine: MKPolyline?
    private var streamer: DashStreamer?
    private var deviceTimer: Timer?

    var isStreaming: Bool { phase == .streaming }
    var isBusy: Bool { phase != .idle && !isError }
    private var isError: Bool { if case .error = phase { return true }; return false }
    private var style: MapStyle { darkMap ? .dark : .light }

    var statusText: String {
        switch phase {
        case .idle: return "Join the bike's Wi-Fi, then pick a destination"
        case .routing: return "Routing with Apple Maps…"
        case .preparingMap(let d, let t): return "Rendering Apple Maps tiles \(d)/\(t)"
        case .connecting: return testMode ? "Opening stream to \(testHost):5000…" : "Connecting to Tripper Dash…"
        case .streaming: return testMode ? "Test stream → \(testHost):5000" : "Streaming. You can lock the phone."
        case .error(let e): return "Error: \(e)"
        }
    }

    init() {
        location.requestAuthorization()
    }

    func search(_ text: String) async {
        guard !text.isEmpty else { return }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = text
        if let here = location.lastFix?.coordinate {
            req.region = MKCoordinateRegion(center: here, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        searchResults = (try? await MKLocalSearch(request: req).start().mapItems) ?? []
    }

    func start(to destination: MKMapItem?) async {
        location.start()
        routeLine = nil

        if let destination {
            phase = .routing
            let req = MKDirections.Request()
            req.source = MKMapItem.forCurrentLocation()
            req.destination = destination
            req.transportType = .automobile
            do {
                routeLine = try await MKDirections(request: req).calculate().routes.first?.polyline
            } catch {
                phase = .error("Routing failed: \(error.localizedDescription)")
                return
            }
        }

        // Pre-render the start of the corridor before we go "headless".
        let center = location.lastFix?.coordinate ?? destination?.placemark.coordinate
        let keys = TilePlanner.keys(center: center, route: routeLine, style: style)
        phase = .preparingMap(done: 0, total: keys.count)
        let readyCount = min(keys.count, 60)
        await tiles.prefetch(keys, readyAfter: readyCount) { [weak self] done in
            Task { @MainActor in
                guard let self, case .preparingMap = self.phase else { return }
                self.phase = .preparingMap(done: done, total: keys.count)
            }
        }

        phase = .connecting
        if simulateRide && location.lastFix == nil {
            phase = .error("No GPS fix yet. Wait a few seconds near a window and retry")
            return
        }
        let test = TestOptions(enabled: testMode, host: testHost, simulateRide: simulateRide, speedKmh: simSpeedKmh)
        let s = DashStreamer(location: location, tiles: tiles, route: routeLine, style: style, test: test)
        s.onPreview = { [weak self] img in Task { @MainActor in self?.preview = img } }
        s.governor.allowTurbo = allowTurbo
        s.onStats = { [weak self] st in Task { @MainActor in self?.stats = st } }
        do {
            try await s.start()
            streamer = s
            phase = .streaming
            startDevicePolling()
        } catch {
            s.stop()
            phase = .error("\(error)")
        }
    }

    func stop() {
        preview = nil
        streamer?.stop()
        streamer = nil
        deviceTimer?.invalidate()
        location.stop()
        phase = .idle
    }

    /// Called whenever the app comes to the foreground mid-ride.
    func setForeground(_ active: Bool) { streamer?.previewEnabled = active }

    func topUpTiles() {
        guard isStreaming, let here = location.lastFix?.coordinate else { return }
        let keys = TilePlanner.keys(center: here, route: routeLine, style: style)
        Task { await tiles.prefetch(keys, readyAfter: 0, progress: { _ in }) }
    }

    /// UIDevice is main-thread only, so we sample it here and hand plain values to the governor.
    private func startDevicePolling() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        deviceTimer?.invalidate()
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.streamer else { return }
                let d = UIDevice.current
                s.governor.updateDevice(batteryLevel: d.batteryLevel,
                                        charging: d.batteryState == .charging || d.batteryState == .full)
            }
        }
        deviceTimer?.fire()
    }
}
