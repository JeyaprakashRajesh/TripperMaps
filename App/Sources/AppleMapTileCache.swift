import MapKit
import UIKit
import ImageIO
import UniformTypeIdentifiers

enum MapStyle: String { case light, dark }

/// A Web-Mercator tile (same projection as MKMapPoint), rendered by Apple Maps at 512×512 px.
/// z16 ≈ 1.1 m/px (town), z15 ≈ 2.3 m/px (highway) at Indian latitudes.
struct TileKey: Hashable {
    let z: Int, x: Int, y: Int
    let style: MapStyle

    static func size(z: Int) -> Double { MKMapSize.world.width / Double(1 << z) }

    var mapRect: MKMapRect {
        let s = Self.size(z: z)
        return MKMapRect(x: Double(x) * s, y: Double(y) * s, width: s, height: s)
    }
    var parent: TileKey { TileKey(z: z - 1, x: x >> 1, y: y >> 1, style: style) }
    var fileName: String { "\(style.rawValue)_\(z)_\(x)_\(y).png" }

    static func containing(_ p: MKMapPoint, z: Int, style: MapStyle) -> TileKey {
        let s = size(z: z)
        return TileKey(z: z, x: Int(p.x / s), y: Int(p.y / s), style: style)
    }
}

enum TilePlanner {
    static let zooms = [16, 15]
    static let pixels = 512

    /// Tiles around `center` plus a corridor along the route, ordered from the start of the ride.
    static func keys(center: CLLocationCoordinate2D?, route: MKPolyline?, style: MapStyle) -> [TileKey] {
        var ordered: [TileKey] = []
        var seen = Set<TileKey>()
        func add(_ p: MKMapPoint, ring: Int) {
            for z in zooms {
                let c = TileKey.containing(p, z: z, style: style)
                for dx in -ring...ring {
                    for dy in -ring...ring {
                        let k = TileKey(z: z, x: c.x + dx, y: c.y + dy, style: style)
                        if seen.insert(k).inserted { ordered.append(k) }
                    }
                }
            }
        }
        if let c = center { add(MKMapPoint(c), ring: 2) }
        if let r = route, r.pointCount > 0 {
            let pts = r.points()
            var last = pts[0]
            add(last, ring: 1)
            for i in 1..<r.pointCount {
                let p = pts[i]
                let d = last.distance(to: p)
                if d < 300 { continue }
                let steps = Int(d / 300)                 // densify long straight highway segments
                for s in 1...max(steps, 1) {
                    let t = Double(s) / Double(max(steps, 1))
                    add(MKMapPoint(x: last.x + (p.x - last.x) * t, y: last.y + (p.y - last.y) * t), ring: 1)
                }
                last = p
            }
        }
        return ordered
    }

    static func keys(covering r: MKMapRect, z: Int, style: MapStyle) -> [TileKey] {
        let s = TileKey.size(z: z)
        let x0 = Int(floor(r.minX / s)), x1 = Int(floor(r.maxX / s))
        let y0 = Int(floor(r.minY / s)), y1 = Int(floor(r.maxY / s))
        var out: [TileKey] = []
        for x in x0...x1 { for y in y0...y1 { out.append(TileKey(z: z, x: x, y: y, style: style)) } }
        return out
    }
}

/// Apple Maps imagery, rendered once in the foreground with MKMapSnapshotter and replayed from
/// RAM/disk in the background (MKMapSnapshotter will not render while the app is backgrounded).
final class AppleMapTileCache {
    private final class Box { let image: CGImage; init(_ i: CGImage) { image = i } }
    private let memory = NSCache<NSString, Box>()
    private let dir: URL
    private let maxConcurrent = 4

    init() {
        memory.countLimit = 48                       // 48 × 1 MB decoded tiles
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppleTiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Thread-safe, called from the render loop. Memory hit is free; disk hit decodes once.
    func image(for key: TileKey) -> CGImage? {
        let name = key.fileName as NSString
        if let b = memory.object(forKey: name) { return b.image }
        let url = dir.appendingPathComponent(key.fileName)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        memory.setObject(Box(img), forKey: name)
        return img
    }

    func has(_ key: TileKey) -> Bool {
        memory.object(forKey: key.fileName as NSString) != nil ||
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(key.fileName).path)
    }

    /// Renders missing tiles with bounded concurrency. Returns once `readyAfter` tiles are done;
    /// the rest keep rendering while the app stays in the foreground.
    func prefetch(_ keys: [TileKey], readyAfter: Int, progress: @escaping (Int) -> Void) async {
        let todo = keys.filter { !has($0) }
        let alreadyDone = keys.count - todo.count
        progress(alreadyDone)
        let need = max(0, readyAfter - alreadyDone)

        let work = Task.detached(priority: .utility) { [weak self] () -> Void in
            guard let self else { return }
            var done = alreadyDone
            var it = todo.makeIterator()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<self.maxConcurrent {
                    guard let k = it.next() else { break }
                    group.addTask { await self.render(k) }
                }
                while await group.next() != nil {
                    done += 1
                    progress(done)
                    if let k = it.next() { group.addTask { await self.render(k) } }
                }
            }
        }

        if need == 0 { return }
        // Poll until the first `readyAfter` tiles exist (they are rendered in order).
        let firstBatch = Array(todo.prefix(need))
        while !Task.isCancelled {
            if firstBatch.allSatisfy({ has($0) }) { return }
            if work.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(150))
            if firstBatch.isEmpty { return }
        }
    }

    private func render(_ key: TileKey) async {
        let o = MKMapSnapshotter.Options()
        o.mapRect = key.mapRect
        o.size = CGSize(width: TilePlanner.pixels, height: TilePlanner.pixels)
        o.scale = 1
        let cfg = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        cfg.pointOfInterestFilter = .excludingAll    // clean dash: roads + labels only
        cfg.showsTraffic = false
        o.preferredConfiguration = cfg
        o.traitCollection = UITraitCollection(userInterfaceStyle: key.style == .dark ? .dark : .light)

        guard let snap = try? await MKMapSnapshotter(options: o).start(),
              let cg = snap.image.cgImage else { return }
        memory.setObject(Box(cg), forKey: key.fileName as NSString)
        let url = dir.appendingPathComponent(key.fileName)
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}
