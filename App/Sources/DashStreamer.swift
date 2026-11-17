import Foundation
import MapKit
import CoreMedia
import QuartzCore
import VideoToolbox
import Network

/// Desk testing without the bike.
struct TestOptions {
    var enabled = false          // stream to a PC instead of the dash (no K1G)
    var host = "192.168.1.10"    // the PC running ffplay/VLC
    var simulateRide = false     // fake GPS along the route
    var speedKmh = 40.0
}

/// The pipeline: GPS -> MotionSmoother -> FrameCompositor (Apple Maps tiles) -> H.264 -> RTP -> dash.
final class DashStreamer {
    let governor = PowerGovernor()
    var onStats: ((StreamStats) -> Void)?

    private let link = DashLink()
    private let smoother = MotionSmoother()
    private let compositor: FrameCompositor
    private let location: LocationEngine
    private var encoder: H264Encoder?
    private var packetizer = RTPPacketizer()
    private let sendQueue = DispatchQueue(label: "dash.send", qos: .userInitiated)
    private var loop: Task<Void, Never>?

    /// Latest frame as an image for the in-app preview (≤2 Hz, only while `previewEnabled`).
    var onPreview: ((CGImage) -> Void)?
    var previewEnabled = true
    private var simulator: RideSimulator?
    private var lastPreview: CFTimeInterval = 0

    init(location: LocationEngine, tiles: AppleMapTileCache, route: MKPolyline?, style: MapStyle,
         test: TestOptions = TestOptions()) {
        self.location = location
        self.compositor = FrameCompositor(tiles: tiles, route: route, style: style)
        let smoother = self.smoother
        if test.enabled {
            link.testMode = true
            link.host = NWEndpoint.Host(test.host)
        }
        if test.simulateRide, let here = location.lastFix?.coordinate {
            // Real GPS keeps running (it keeps the app alive when locked) but is ignored.
            let sim = RideSimulator(route: route, around: here, speedKmh: test.speedKmh)
            sim.onFix = { smoother.ingest($0) }
            simulator = sim
            location.onFix = nil
        } else {
            location.onFix = { smoother.ingest($0) }
            if let l = location.lastFix { smoother.ingest(l) }
        }
    }

    private var linkUp = true
    private var needsKeyFrame = false

    func start() async throws {
        link.onWiFiChange = { [weak self] up in
            guard let self else { return }
            self.linkUp = false                       // pause video while the socket is rebuilt
            guard up else { return }
            Task {
                // Dash may need a moment after the Wi-Fi returns; retry quietly.
                for attempt in 0..<5 {
                    if (try? await self.link.reconnect()) != nil {
                        self.needsKeyFrame = true
                        self.linkUp = true
                        return
                    }
                    try? await Task.sleep(for: .seconds(2 + Double(attempt) * 2))
                }
            }
        }
        try await link.connect()
        link.startProjection()

        let tier = PowerGovernor.smooth
        let enc = try H264Encoder(width: FrameCompositor.width, height: FrameCompositor.height,
                                  fps: tier.fps, bitrate: tier.bitrate)
        enc.onAccessUnit = { [weak self] nalus, pts in
            guard let self else { return }
            self.sendQueue.async {
                let pkts = self.packetizer.packets(for: nalus, pts: pts)
                self.link.sendVideo(pkts)
            }
        }
        encoder = enc
        simulator?.start()
        loop = Task.detached(priority: .userInitiated) { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel(); loop = nil
        simulator?.stop(); simulator = nil
        encoder?.invalidate(); encoder = nil
        link.stopProjection()
        link.close()
        location.onFix = nil
    }

    /// Absolute-deadline pacing: render time is absorbed into the slot, overruns skip slots
    /// instead of bursting (bursts make the dash decoder blink).
    private func run() async {
        let clock = ContinuousClock()
        var next = clock.now
        var currentTier = PowerGovernor.smooth
        var lastEncode = clock.now - .seconds(10)
        var forceKey = true
        var framesThisWindow = 0, bytesAtWindowStart = 0
        var windowStart = clock.now

        while !Task.isCancelled {
            let t = CACurrentMediaTime()
            let tier = governor.tier(speed: smoother.speed, now: t)
            if tier != currentTier {
                encoder?.setFrameRate(tier.fps)
                encoder?.setBitrate(tier.bitrate)
                let parked = tier == PowerGovernor.parked
                DispatchQueue.main.async { [location] in location.setStationary(parked) }
                currentTier = tier
            }
            let status = governor.deviceStatus
            link.batteryPercent = status.percent
            link.charging = status.charging

            if needsKeyFrame { forceKey = true; needsKeyFrame = false }
            if linkUp, let state = smoother.state(at: t) {
                let pts = CMTime(seconds: t, preferredTimescale: 90_000)
                if compositor.needsRedraw(state), let pb = compositor.render(state) {
                    encoder?.encode(pb, pts: pts, forceKeyFrame: forceKey)
                    forceKey = false; lastEncode = clock.now; framesThisWindow += 1
                    if previewEnabled, t - lastPreview > 0.5, let onPreview {
                        var img: CGImage?
                        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &img)
                        if let img { onPreview(img) }
                        lastPreview = t
                    }
                } else if clock.now - lastEncode >= .seconds(1), let pb = compositor.lastBuffer {
                    // Nothing moved: re-send the last frame once a second (tiny P-frame) so the dash
                    // never thinks the stream died.
                    encoder?.encode(pb, pts: pts)
                    lastEncode = clock.now; framesThisWindow += 1
                }
            }

            if clock.now - windowStart >= .seconds(2) {
                let secs = Double((clock.now - windowStart).components.seconds)
                let bytes = (encoder?.bytesOut ?? 0) - bytesAtWindowStart
                onStats?(StreamStats(fps: Double(framesThisWindow) / max(secs, 1),
                                     kbps: Int(Double(bytes) * 8 / 1000 / max(secs, 1)),
                                     tier: currentTier.name,
                                     missingTiles: compositor.missingTiles))
                framesThisWindow = 0; bytesAtWindowStart = encoder?.bytesOut ?? 0; windowStart = clock.now
            }

            let interval = Duration.milliseconds(1000 / max(currentTier.fps, 1))
            next += interval
            if next < clock.now { next = clock.now + interval }
            try? await Task.sleep(until: next, clock: clock)
        }
    }
}
