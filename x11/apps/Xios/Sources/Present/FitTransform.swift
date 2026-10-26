import CoreGraphics

/// The one place the framebuffer-to-glass mapping lives. The framebuffer is
/// drawn aspect-fit at zoom 1, then scaled and panned in view points. Rendering
/// (clip vertices), pointer mapping, the cursor plane and the accessibility
/// frames all go through the same instance, so they cannot disagree. Pure value
/// type: no UIKit, so Tests/ runs it on the host.
struct FitTransform {
    let fbWidth: Int
    let fbHeight: Int
    let viewBounds: CGRect
    let drawableSize: CGSize
    let contentsScale: CGFloat
    let scale: CGFloat
    let contentRect: CGRect

    static func make(fbWidth: Int, fbHeight: Int, viewBounds: CGRect,
                     drawableSize: CGSize, contentsScale: CGFloat,
                     zoom: CGFloat, pan: CGPoint) -> FitTransform? {
        guard fbWidth > 0, fbHeight > 0,
              viewBounds.width > 0, viewBounds.height > 0,
              drawableSize.width > 0, drawableSize.height > 0,
              contentsScale > 0 else { return nil }
        let baseScale = min(viewBounds.width / CGFloat(fbWidth),
                            viewBounds.height / CGFloat(fbHeight))
        let scale = baseScale * zoom
        let size = CGSize(width: CGFloat(fbWidth) * scale,
                          height: CGFloat(fbHeight) * scale)
        let origin = CGPoint(
            x: viewBounds.midX - size.width / 2 + pan.x,
            y: viewBounds.midY - size.height / 2 + pan.y)
        return FitTransform(
            fbWidth: fbWidth, fbHeight: fbHeight, viewBounds: viewBounds,
            drawableSize: drawableSize, contentsScale: contentsScale,
            scale: scale, contentRect: CGRect(origin: origin, size: size))
    }

    /// View point -> framebuffer pixel, clamped to the framebuffer. nil when the
    /// point is outside the drawn content (letterbox).
    func framebufferPoint(from point: CGPoint) -> CGPoint? {
        guard contentRect.contains(point),
              contentRect.width > 0, contentRect.height > 0 else { return nil }
        let fx = (point.x - contentRect.minX) / contentRect.width * CGFloat(fbWidth)
        let fy = (point.y - contentRect.minY) / contentRect.height * CGFloat(fbHeight)
        return CGPoint(
            x: max(0, min(CGFloat(fbWidth - 1), fx)),
            y: max(0, min(CGFloat(fbHeight - 1), fy)))
    }

    /// Framebuffer-pixel rect -> view points (the inverse mapping).
    func viewRect(fromFramebuffer r: CGRect) -> CGRect {
        CGRect(x: contentRect.minX + r.minX * scale,
               y: contentRect.minY + r.minY * scale,
               width: r.width * scale, height: r.height * scale)
    }

    /// Triangle strip TL, BL, TR, BR as (pos.xy, uv.xy), in clip space.
    func clipVertices(flipY: Bool = false) -> [Float]? {
        let dw = drawableSize.width
        let dh = drawableSize.height
        guard dw > 0, dh > 0 else { return nil }
        let left = contentRect.minX * contentsScale
        let right = contentRect.maxX * contentsScale
        let top = contentRect.minY * contentsScale
        let bottom = contentRect.maxY * contentsScale
        let x0 = Float(2 * left / dw - 1)
        let x1 = Float(2 * right / dw - 1)
        let y0 = Float(1 - 2 * top / dh)
        let y1 = Float(1 - 2 * bottom / dh)
        var v: [Float] = [
            x0, y0, 0, 0,
            x0, y1, 0, 1,
            x1, y0, 1, 0,
            x1, y1, 1, 1,
        ]
        if flipY {
            // Client GL IOSurfaces have bottom-left content: swap only each V
            // (invariant 14). Geometry and input stay the compositor output.
            for index in stride(from: 3, to: v.count, by: 4) { v[index] = 1 - v[index] }
        }
        return v
    }
}

/// Zoom and pan of the presented desktop. Finger pinch is app zoom 1...6; pan is
/// view points from centre. Pure math over FitTransform so the clamps are testable.
struct ViewportState: Equatable {
    static let minZoom: CGFloat = 1
    static let maxZoom: CGFloat = 6

    var zoom: CGFloat = 1
    var pan: CGPoint = .zero

    mutating func reset() { zoom = Self.minZoom; pan = .zero }

    private func fit(_ geometry: Geometry, zoom: CGFloat, pan: CGPoint) -> FitTransform? {
        FitTransform.make(fbWidth: geometry.fbWidth, fbHeight: geometry.fbHeight,
                          viewBounds: geometry.bounds, drawableSize: geometry.drawableSize,
                          contentsScale: geometry.contentsScale, zoom: zoom, pan: pan)
    }

    struct Geometry {
        var fbWidth: Int
        var fbHeight: Int
        var bounds: CGRect
        var drawableSize: CGSize
        var contentsScale: CGFloat
    }

    func transform(_ g: Geometry) -> FitTransform? { fit(g, zoom: zoom, pan: pan) }

    func clampedPan(_ p: CGPoint, zoom z: CGFloat, _ g: Geometry) -> CGPoint {
        guard let t = fit(g, zoom: z, pan: .zero) else { return .zero }
        let maxX = max(0, (t.contentRect.width - g.bounds.width) / 2)
        let maxY = max(0, (t.contentRect.height - g.bounds.height) / 2)
        return CGPoint(x: min(max(p.x, -maxX), maxX), y: min(max(p.y, -maxY), maxY))
    }

    /// Zoom so the content under `anchor` stays under it.
    mutating func setZoom(_ z: CGFloat, around anchor: CGPoint? = nil, _ g: Geometry) {
        guard let old = transform(g) else { return }
        let oldRect = old.contentRect
        let a = anchor ?? CGPoint(x: g.bounds.midX, y: g.bounds.midY)
        let ux = oldRect.width > 0 ? (a.x - oldRect.minX) / oldRect.width : 0.5
        let uy = oldRect.height > 0 ? (a.y - oldRect.minY) / oldRect.height : 0.5
        let next = min(max(z, Self.minZoom), Self.maxZoom)
        let nextSize = fit(g, zoom: next, pan: .zero)?.contentRect.size ?? oldRect.size
        let nextPan = CGPoint(x: a.x - g.bounds.midX + nextSize.width * (0.5 - ux),
                              y: a.y - g.bounds.midY + nextSize.height * (0.5 - uy))
        zoom = next
        pan = clampedPan(nextPan, zoom: next, g)
    }
}
