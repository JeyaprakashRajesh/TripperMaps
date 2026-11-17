import Foundation
import Network

/// UDP transport to the dash, hard-bound to the bike's Wi-Fi interface.
///
/// Split routing: the bike's Wi-Fi has no internet, so iOS makes mobile data the default route
/// (Apple Maps routing, search, tile rendering, your other apps all go over 4G/5G). That is what we
/// want, but it means a socket left to the default route would try 192.168.1.1 over cellular.
/// So every dash socket here is pinned to the concrete Wi-Fi `NWInterface` (not just "a Wi-Fi
/// type"), cellular is prohibited for it, and we watch that interface and reconnect when it returns.
final class DashLink {
    /// The real dash is always 192.168.1.1. Test mode points this at your PC instead.
    var host = NWEndpoint.Host("192.168.1.1")
    /// Test mode: no K1G control plane, video only (RTP → host:5000), e.g. ffplay/VLC on a PC.
    var testMode = false
    private let queue = DispatchQueue(label: "dash.link", qos: .userInitiated)
    private var control: NWConnection?
    private var video: NWConnection?
    private var heartbeat: DispatchSourceTimer?
    private var inbox: AsyncStream<Data>.Continuation?
    private var inboxStream: AsyncStream<Data>?
    private var wifiMonitor: NWPathMonitor?
    private var wifiInterface: NWInterface?

    var codec: K1GCodec = UnportedK1GCodec()
    var batteryPercent = 100
    var charging = false
    /// true = bike Wi-Fi came back after a drop (reconnect), false = it went away. Called on `queue`.
    var onWiFiChange: ((Bool) -> Void)?

    func connect() async throws {
        wifiInterface = try await waitForWiFi()
        try await openSockets()
    }

    private func openSockets() async throws {
        if !testMode {
            let c = NWConnection(host: host, port: 2000, using: wifiParameters(localPort: 2002))
            try await start(c)
            control = c

            let (stream, cont) = AsyncStream<Data>.makeStream()
            inboxStream = stream
            inbox = cont
            receiveLoop(c)

            try await withTimeout(seconds: 40) { [self] in
                try await codec.handshake(send: { [weak self] d in self?.sendControl(d) },
                                          receive: { [weak self] in try await self?.nextMessage() ?? Data() })
            }
        }

        let v = NWConnection(host: host, port: 5000, using: wifiParameters(localPort: nil))
        try await start(v)
        video = v
        if !testMode { startHeartbeat() }
    }

    func startProjection() { codec.startProjectionMessages().forEach(sendControl) }
    func stopProjection() { codec.stopProjectionMessages().forEach(sendControl) }

    func sendVideo(_ packets: [Data]) {
        guard let v = video, !packets.isEmpty else { return }
        v.batch {
            for p in packets { v.send(content: p, completion: .idempotent) }
        }
    }

    /// Closes the sockets but keeps watching Wi-Fi (used for reconnects).
    func closeSockets() {
        heartbeat?.cancel(); heartbeat = nil
        inbox?.finish()
        control?.cancel(); video?.cancel()
        control = nil; video = nil
    }

    func close() {
        wifiMonitor?.cancel(); wifiMonitor = nil
        heartbeat?.cancel(); heartbeat = nil
        inbox?.finish()
        control?.cancel(); video?.cancel()
        control = nil; video = nil
    }

    // MARK: - Wi-Fi pinning

    private func wifiParameters(localPort: NWEndpoint.Port?) -> NWParameters {
        let p = NWParameters.udp
        if let iface = wifiInterface { p.requiredInterface = iface }   // this exact en0, nothing else
        p.requiredInterfaceType = .wifi
        p.prohibitedInterfaceTypes = [.cellular]                      // never 192.168.1.1 over 4G/5G
        p.multipathServiceType = .disabled                            // no Wi-Fi Assist handover
        if let localPort {
            p.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.any), port: localPort)
            p.allowLocalEndpointReuse = true
        }
        return p
    }

    /// Waits for a Wi-Fi interface. Deliberately ignores `path.status`: iOS may mark the bike's
    /// network "No Internet Connection", but the interface is up and 192.168.1.1 is reachable.
    private func waitForWiFi() async throws -> NWInterface {
        wifiMonitor?.cancel()
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        wifiMonitor = monitor
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWInterface, Error>) in
            var resumed = false
            var hadWiFi = false
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                let iface = path.availableInterfaces.first { $0.type == .wifi }
                if !resumed {
                    if let iface { resumed = true; hadWiFi = true; cont.resume(returning: iface) }
                    return
                }
                if let iface, !hadWiFi {
                    hadWiFi = true
                    self.wifiInterface = iface
                    self.onWiFiChange?(true)
                } else if iface == nil, hadWiFi {
                    hadWiFi = false
                    self.onWiFiChange?(false)
                }
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) {
                if !resumed { resumed = true; cont.resume(throwing: DashError.noBikeWiFi) }
            }
        }
    }

    /// Re-runs connect on the already-watched Wi-Fi interface after a drop.
    func reconnect() async throws {
        closeSockets()
        try await openSockets()
        startProjection()
    }

    // MARK: - Internals

    private func sendControl(_ d: Data) {
        control?.send(content: d, completion: .idempotent)
    }

    private func nextMessage() async throws -> Data {
        guard let s = inboxStream else { throw DashError.timeout }
        for await m in s { return m }
        throw DashError.timeout
    }

    private func receiveLoop(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.codec.replies(to: data).forEach(self.sendControl)
                self.inbox?.yield(data)
            }
            if error == nil { self.receiveLoop(c) }
        }
    }

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))   // leeway lets iOS coalesce wakeups
        t.setEventHandler { [weak self] in
            guard let self, let hb = self.codec.heartbeat(batteryPercent: self.batteryPercent, charging: self.charging) else { return }
            self.sendControl(hb)
        }
        t.resume()
        heartbeat = t
    }

    private func start(_ c: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            c.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; cont.resume()
                case .failed(let e): resumed = true; cont.resume(throwing: e)
                default: break      // .waiting = Local Network prompt pending; keep waiting
                }
            }
            c.start(queue: queue)
        }
    }

    private func withTimeout(seconds: Double, _ op: @escaping () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { g in
            g.addTask { try await op() }
            g.addTask { try await Task.sleep(for: .seconds(seconds)); throw DashError.timeout }
            try await g.next()
            g.cancelAll()
        }
    }
}
