import CoreGraphics
import CoreVideo
import MapKit

/// CPU-only frame builder (CoreGraphics into an IOSurface-backed pixel buffer). The GPU is
/// off-limits to backgrounded apps, and for a 526×300 frame the CPU path is only a few ms.
/// The buffer goes straight to the hardware H.264 encoder with no copies.
final class FrameCompositor {
    /// Stream size used by the stock app and TripperDash++. The visible glass is a circle
    /// centred at ~(262, 263), radius ~264, so the top corners are hidden.
    static let width = 526, height = 300
    /// Rider sits low in the frame so more road ahead is visible inside the round glass.
    static let anchor = CGPoint(x: 262, y: 220)

    private let tiles: AppleMapTileCache
    private let route: [MKMapPoint]
    private let style: MapStyle
    private var pool: CVPixelBufferPool?
    private var lastDrawn: RiderState?
    private(set) var lastBuffer: CVPixelBuffer?
    private(set) var missingTiles = 0

    init(tiles: AppleMapTileCache, route: MKPolyline?, style: MapStyle) {
        self.tiles = tiles
        self.style = style
        if let r = route {
            route = Array(UnsafeBufferPointer(start: r.points(), count: r.pointCount))
        } else {
            route = []
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.width,
            kCVPixelBufferHeightKey as String: Self.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                                attrs as CFDictionary, &pool)
    }

    /// Skip the whole render+encode when nothing visibly moved (signals, traffic, parking).
    func needsRedraw(_ s: RiderState) -> Bool {
        guard let l = lastDrawn else { return true }
        let movedPx = l.point.distance(to: s.point) / s.metersPerPixel
        var dh = abs(l.heading - s.heading); if dh > 180 { dh = 360 - dh }
        return movedPx > 0.35 || dh > 0.3 || abs(l.metersPerPixel - s.metersPerPixel) > 0.01
    }

    func render(_ s: RiderState) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let W = Self.width, H = Self.height
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: W, height: H,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        let dark = style == .dark
        ctx.setFillColor(dark ? CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1) : CGColor(gray: 0.93, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.interpolationQuality = .medium

        // Work in a top-left, y-down space like map points.
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: 1, y: -1)

        let lat = s.point.coordinate.latitude
        let pxPerMapPoint = 1.0 / (s.metersPerPixel * MKMapPointsPerMeterAtLatitude(lat))

        ctx.saveGState()
        ctx.translateBy(x: Self.anchor.x, y: Self.anchor.y)
        ctx.rotate(by: CGFloat(-s.heading * .pi / 180))          // heading-up
        ctx.scaleBy(x: pxPerMapPoint, y: pxPerMapPoint)
        ctx.translateBy(x: -s.point.x, y: -s.point.y)

        let r = Double(hypot(Double(W), Double(H))) / pxPerMapPoint
        let view = MKMapRect(x: s.point.x - r, y: s.point.y - r, width: 2 * r, height: 2 * r)
        let z = s.metersPerPixel > 1.7 ? 15 : 16

        var missing = 0
        var drawnParents = Set<TileKey>()
        for key in TilePlanner.keys(covering: view, z: z, style: style) {
            if let img = tiles.image(for: key) {
                draw(img, in: key.mapRect, ctx)
            } else if drawnParents.insert(key.parent).inserted, let p = tiles.image(for: key.parent) {
                draw(p, in: key.parent.mapRect, ctx)               // blurrier, but never blank
            } else {
                missing += 1
            }
        }
        missingTiles = missing

        drawRoute(ctx, view: view, lineWidthPx: 7, pxPerMapPoint: pxPerMapPoint)
        ctx.restoreGState()

        drawChevron(ctx, dark: dark)

        lastDrawn = s
        lastBuffer = pb
        return pb
    }

    private func draw(_ img: CGImage, in r: MKMapRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: r.origin.x, y: r.origin.y + r.size.height)
        ctx.scaleBy(x: 1, y: -1)                                 // undo the y-flip for images
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.size.width, height: r.size.height))
        ctx.restoreGState()
    }

    private func drawRoute(_ ctx: CGContext, view: MKMapRect, lineWidthPx: Double, pxPerMapPoint: Double) {
        guard route.count > 1 else { return }
        let cull = view.insetBy(dx: -view.size.width, dy: -view.size.height)
        let path = CGMutablePath()
        var penDown = false
        for p in route {
            if cull.contains(p) {
                if penDown { path.addLine(to: CGPoint(x: p.x, y: p.y)) } else { path.move(to: CGPoint(x: p.x, y: p.y)); penDown = true }
            } else {
                penDown = false
            }
        }
        ctx.addPath(path)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setLineWidth(CGFloat(lineWidthPx / pxPerMapPoint))
        ctx.setStrokeColor(CGColor(red: 1.0, green: 0.72, blue: 0.0, alpha: 1))
        ctx.strokePath()
    }

    private func drawChevron(_ ctx: CGContext, dark: Bool) {
        let a = Self.anchor
        let p = CGMutablePath()
        p.move(to: CGPoint(x: a.x, y: a.y - 14))
        p.addLine(to: CGPoint(x: a.x + 10, y: a.y + 10))
        p.addLine(to: CGPoint(x: a.x, y: a.y + 4))
        p.addLine(to: CGPoint(x: a.x - 10, y: a.y + 10))
        p.closeSubpath()
        ctx.addPath(p)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(2)
        ctx.drawPath(using: .fillStroke)
    }
}
