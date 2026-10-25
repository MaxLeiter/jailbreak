import UIKit

/// The present-side cursor. When iosc runs with IOSC_APP_CURSOR it stops
/// compositing the pointer and streams position and shape over the typed socket;
/// we draw it as a CALayer above the Metal content, so a pointer move is a Core
/// Animation reposition with no Metal re-present. With a mouse attached the
/// system pointer is dressed in the desktop's shape instead and this layer hides.
/// Its state belongs to one connection: `reset()` runs on every present and loss.
final class CursorPlane {
    private weak var parent: CALayer?
    private var layer: CALayer?
    /// Set only where iPadOS draws a pointer at all (a mouse/trackpad is connected).
    weak var systemPointerInteraction: UIPointerInteraction?

    private var hardwarePointerActive = false
    private var lastCursorSeq: UInt32 = 0
    private var cursorImageSeq: UInt32 = 0
    private var clientImage: CGImage?
    private var clientSize = CGSize.zero
    private var clientHotspot = CGPoint.zero
    private var hasClientImage = false
    private var isText = false
    /// Latest wp_cursor_shape id. 0 = the desktop hid the pointer OR handed rendering
    /// back to the compositor (nested KWin does: its themed cursor is already in the
    /// framebuffer pixels, so iPadOS must not add a second one).
    private(set) var desktopShape: Int32 = 0

    init(parent: CALayer) { self.parent = parent }

    // MARK: input-source hints

    func hardwarePointerBegan() {
        if !hardwarePointerActive {
            hardwarePointerActive = true
            lastCursorSeq = 0
        }
    }

    func touchBegan() {
        hardwarePointerActive = false
        layer?.isHidden = true
    }

    /// The fit rect moved (rotation, zoom, pan): re-place an idle cursor.
    func invalidatePosition() { lastCursorSeq = 0 }

    func reset() {
        layer?.removeFromSuperlayer()
        layer = nil
        lastCursorSeq = 0
        cursorImageSeq = 0
        clientImage = nil
        hasClientImage = false
        hardwarePointerActive = false
        noteShape(0)
    }

    // MARK: per tick

    /// Cheap: reads the last-parsed state (xsurface_drain already parsed it) and only
    /// touches Core Animation when the sequence changed.
    func update(link: SurfaceLink, fit: FitTransform?) {
        let conn = link.conn
        var x: Int32 = 0, y: Int32 = 0, vis: Int32 = 0, shape: Int32 = 0
        let seq = xsurface_cursor(conn, &x, &y, &vis, &shape)
        // Image content arrives on its own schedule (only when it changes), so it is
        // picked up before the position early-outs below.
        adoptClientImage(conn)
        guard seq != 0 else { return }        // overlay off server-side: compositor draws it
        if seq == lastCursorSeq { return }    // no new pointer state this tick
        lastCursorSeq = seq
        noteShape(vis == 0 ? 0 : shape)

        // With a mouse or trackpad attached iPadOS already draws a pointer in the
        // desktop's shape; a second cursor of ours would only trail it.
        if hardwarePointerActive, systemPointerInteraction != nil {
            layer?.isHidden = true
            return
        }
        // Without a real cursor image the synthesized arrow is only worth drawing
        // where the compositor has no pointer of its own (mutter). Once the client's
        // own bitmap is in hand this layer IS the cursor (the compositor stopped
        // painting one), so hiding it would leave none.
        if !hardwarePointerActive && link.compositorID != "mutter-ios" && !hasClientImage {
            layer?.isHidden = true
            return
        }
        if layer == nil { makeLayer(shape: shape) }
        guard let layer, let fit else { return }
        if vis == 0 { layer.isHidden = true; return }
        layer.isHidden = false
        if hasClientImage {
            applyClientImage(fit: fit)
        } else {
            applyShape(shape)
        }
        // Cursor coords arrive in framebuffer (physical) px; map through the same
        // fit/zoom/pan rect the framebuffer uses so the pointer tracks the content.
        let rect = fit.contentRect
        let vx = rect.minX + CGFloat(x) / CGFloat(max(fit.fbWidth, 1)) * rect.width
        let vy = rect.minY + CGFloat(y) / CGFloat(max(fit.fbHeight, 1)) * rect.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // track instantly, no implicit move animation
        layer.position = CGPoint(x: vx, y: vy)
        CATransaction.commit()
    }

    // MARK: client bitmap

    private func adoptClientImage(_ conn: OpaquePointer) {
        var w: Int32 = 0, h: Int32 = 0, hx: Int32 = 0, hy: Int32 = 0, seq: UInt32 = 0
        // Copy the pixels now: they belong to the connection and are only valid
        // until the next drain (invariant 31).
        let pixels = xsurface_cursor_image(conn, &w, &h, &hx, &hy, &seq)
        guard seq != cursorImageSeq else { return }   // no image change this tick
        cursorImageSeq = seq
        guard let pixels, w > 0, h > 0 else {
            // Withdrawn: the compositor paints the cursor again, so stop drawing ours.
            hasClientImage = false
            clientImage = nil
            return
        }
        let data = Data(bytes: pixels, count: Int(w) * Int(h) * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: Int(w), height: Int(h), bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: Int(w) * 4, space: CGColorSpaceCreateDeviceRGB(),
                // Premultiplied BGRA on the wire == premultipliedFirst + little endian.
                bitmapInfo: CGBitmapInfo(rawValue:
                    CGImageAlphaInfo.premultipliedFirst.rawValue |
                    CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else {
            hasClientImage = false
            clientImage = nil
            return
        }
        clientImage = image
        clientSize = CGSize(width: Int(w), height: Int(h))
        clientHotspot = CGPoint(x: CGFloat(hx) / CGFloat(w), y: CGFloat(hy) / CGFloat(h))
        hasClientImage = true
    }

    /// Size the plane to the framebuffer's on-screen scale, hotspot where the
    /// compositor thinks the pointer is.
    private func applyClientImage(fit: FitTransform) {
        guard let layer, let image = clientImage else { return }
        let rect = fit.contentRect
        let sx = fit.fbWidth > 0 ? rect.width / CGFloat(fit.fbWidth) : 1
        let sy = fit.fbHeight > 0 ? rect.height / CGFloat(fit.fbHeight) : 1
        layer.contents = image
        layer.bounds = CGRect(origin: .zero,
                              size: CGSize(width: clientSize.width * sx, height: clientSize.height * sy))
        layer.anchorPoint = clientHotspot
    }

    private func makeLayer(shape: Int32) {
        let l = CALayer()
        l.contentsScale = UIScreen.main.scale
        l.isHidden = true
        parent?.addSublayer(l)          // above the Metal drawable, below any UIView chrome
        layer = l
        applyShape(shape)
    }

    /// Rebuild the overlay bitmap only when the shape category flips (text vs arrow).
    private func applyShape(_ shape: Int32) {
        let text = (shape == 9 || shape == 10)   // wp_cursor_shape: 9=text, 10=vertical-text
        guard let layer, layer.contents == nil || text != isText else { return }
        isText = text
        let (image, hotspot) = Self.cursorImage(isText: text)
        layer.contents = image.cgImage
        layer.bounds = CGRect(origin: .zero, size: image.size)
        layer.anchorPoint = hotspot
    }

    /// A small pointer bitmap + its hotspot (as a unit anchorPoint). Black fill with a
    /// white outline so it reads on any background.
    private static func cursorImage(isText: Bool) -> (UIImage, CGPoint) {
        if isText {
            let size = CGSize(width: 9, height: 22)
            let img = UIGraphicsImageRenderer(size: size).image { ctx in
                let c = ctx.cgContext
                let beam = { (c: CGContext) in
                    c.move(to: CGPoint(x: 4.5, y: 2));  c.addLine(to: CGPoint(x: 4.5, y: 20))
                    c.move(to: CGPoint(x: 2, y: 2));    c.addLine(to: CGPoint(x: 7, y: 2))
                    c.move(to: CGPoint(x: 2, y: 20));   c.addLine(to: CGPoint(x: 7, y: 20))
                }
                c.setLineCap(.round)
                c.setStrokeColor(UIColor.white.cgColor); c.setLineWidth(3); beam(c); c.strokePath()
                c.setStrokeColor(UIColor.black.cgColor); c.setLineWidth(1); beam(c); c.strokePath()
            }
            return (img, CGPoint(x: 0.5, y: 0.5))
        }
        let size = CGSize(width: 16, height: 24)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let p = CGMutablePath()
            p.addLines(between: [
                CGPoint(x: 1, y: 1),   CGPoint(x: 1, y: 19),  CGPoint(x: 5.5, y: 14.5),
                CGPoint(x: 8.5, y: 21), CGPoint(x: 11, y: 20), CGPoint(x: 8, y: 13.5),
                CGPoint(x: 14, y: 13.5),
            ])
            p.closeSubpath()
            c.addPath(p); c.setStrokeColor(UIColor.white.cgColor)
            c.setLineWidth(2); c.setLineJoin(.round); c.strokePath()
            c.addPath(p); c.setFillColor(UIColor.black.cgColor); c.fillPath()
        }
        return (img, CGPoint(x: 1.0 / 16.0, y: 1.0 / 24.0))
    }

    // MARK: system pointer shape

    /// Remember the desktop's cursor shape and re-ask UIKit for a pointer style only
    /// when the category flips; invalidating on every CURSOR record would fight the
    /// pointer's own morph animation (invariant 36).
    private func noteShape(_ shape: Int32) {
        guard let interaction = systemPointerInteraction else {
            desktopShape = shape
            return
        }
        let before = Self.category(desktopShape)
        desktopShape = shape
        if Self.category(shape) != before { interaction.invalidate() }
    }

    private enum Category { case hidden, arrow, text, resizeH, resizeV, system }

    /// Map a wp_cursor_shape id onto what iPadOS can draw. `system` keeps iPadOS's own
    /// pointer for shapes we have nothing better for (wait/progress): a wrong glyph
    /// reads worse than the default.
    private static func category(_ shape: Int32) -> Category {
        switch shape {
        case 0:                     return .hidden
        case 9:                     return .text
        case 10:                    return .resizeH     // vertical-text: the beam lies flat
        case 18, 25, 26, 30:        return .resizeH     // e/w/ew/col-resize
        case 19, 22, 27, 31:        return .resizeV     // n/s/ns/row-resize
        case 5, 6:                  return .system      // progress, wait
        default:                    return .arrow
        }
    }

    /// The style iPadOS should draw for the current desktop cursor. Shape 0 = hidden.
    func systemPointerStyle() -> UIPointerStyle? {
        switch Self.category(desktopShape) {
        case .hidden:  return .hidden()
        case .system:  return nil                       // nil = iPadOS's standard pointer
        case .text:    return UIPointerStyle(shape: .verticalBeam(length: 22))
        case .resizeH: return UIPointerStyle(shape: .horizontalBeam(length: 22))
        case .resizeV: return UIPointerStyle(shape: .verticalBeam(length: 22))
        case .arrow:   return UIPointerStyle(shape: .path(Self.arrowPath()), constrainedAxes: [])
        }
    }

    /// The classic left_ptr silhouette, authored tip-first at the origin.
    private static func arrowPath() -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0, y: 18))
        p.addLine(to: CGPoint(x: 4.5, y: 13.5))
        p.addLine(to: CGPoint(x: 7.5, y: 20))
        p.addLine(to: CGPoint(x: 10, y: 19))
        p.addLine(to: CGPoint(x: 7, y: 12.5))
        p.addLine(to: CGPoint(x: 13, y: 12.5))
        p.close()
        return p
    }
}
