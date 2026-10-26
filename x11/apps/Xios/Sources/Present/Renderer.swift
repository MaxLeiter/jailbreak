import Metal
import QuartzCore
import UIKit
import OSLog

/// The Metal side of presenting: device, queue, the one textured-quad pipeline,
/// the optional MetalFX stage, and the small thumbnail pass. Knows nothing about
/// sessions or sockets. The IOSurface-backed textures it samples come from the
/// SurfaceLink that owns the connection.
final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private(set) weak var layer: CAMetalLayer?

    /// Set when the upscale mode changed and the next frame must be re-presented.
    var onNeedsPresent: (() -> Void)?

    // Instruments needs named intervals to show where a frame went. A disabled
    // signposter compiles down to nothing.
    private let signposter = OSSignposter(subsystem: "com.max.xios", category: "present")

    /// nil when there is no GPU yet: MTLCreateSystemDefaultDevice() returns nil for
    /// a backgrounded app (a SpringBoard relaunch, uicache launching us off-screen),
    /// so the caller retries when the app becomes active (invariant 23).
    static func make() -> Renderer? {
        StatusWriter.shared.metal("start")
        guard let dev = MTLCreateSystemDefaultDevice() else {
            StatusWriter.shared.metal("no-device"); return nil
        }
        guard let q = dev.makeCommandQueue() else {
            StatusWriter.shared.metal("no-queue"); return nil
        }
        guard let lib = dev.makeDefaultLibrary() else {
            StatusWriter.shared.metal("no-library"); return nil
        }
        guard let vfn = lib.makeFunction(name: "v_main"),
              let ffn = lib.makeFunction(name: "f_main") else {
            StatusWriter.shared.metal("no-functions"); return nil
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            let pipeline = try dev.makeRenderPipelineState(descriptor: pd)
            StatusWriter.shared.metal("ok")
            return Renderer(device: dev, queue: q, pipeline: pipeline)
        } catch {
            StatusWriter.shared.metal("pipeline-error \(error)")
            return nil
        }
    }

    private init(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState) {
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        upscaleMode = resolveUpscaleMode()
    }

    func attach(layer: CAMetalLayer) {
        self.layer = layer
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = upscaler == nil
        layer.contentsScale = UIScreen.main.scale   // render at native (retina) px
        syncUpscaler()
    }

    // MARK: drawing

    /// Draw `tex` through `fit`. `waitEvent` is the producer's brokered GPU fence
    /// for this frame; `onPresented` runs on main with the drawable's presentedTime
    /// (0 when it never reached the panel) and is the ONLY place a frame is acked
    /// (invariant 1).
    @discardableResult
    func render(_ tex: MTLTexture, fit: FitTransform, flipY: Bool,
                waitEvent: MTLSharedEvent? = nil, waitValue: UInt64 = 0,
                onPresented: ((CFTimeInterval) -> Void)? = nil) -> Bool {
        let interval = signposter.beginInterval("present")
        defer { signposter.endInterval("present", interval) }
        guard let layer, let drawable = layer.nextDrawable(),
              let cmd = queue.makeCommandBuffer(),
              var verts = fit.clipVertices(flipY: flipY) else { return false }
        if let waitEvent, waitValue > 0 {
            cmd.encodeWaitForEvent(waitEvent, value: waitValue)
        }
        // Optional MetalFX stage: composite into a smaller intermediate and let the
        // spatial scaler blow it up to the drawable. clipVertices() is in normalised
        // device coordinates and the intermediate is a uniform scale of the
        // drawable, so the same vertices frame the desktop identically. A nil plan
        // is the direct present: the default, and what every failure degrades to.
        let plan = upscaler?.plan(
            mode: upscaleMode,
            drawableWidth: Int(layer.drawableSize.width),
            drawableHeight: Int(layer.drawableSize.height),
            sourceWidth: tex.width, sourceHeight: tex.height,
            drawableTexture: drawable.texture, pixelFormat: layer.pixelFormat)
        publishUpscaleStatus(plan)

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = plan?.source ?? drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&verts, length: verts.count * MemoryLayout<Float>.size, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        if let plan, let upscaler {
            let up = signposter.beginInterval("upscale")
            upscaler.encode(plan, into: drawable.texture, commandBuffer: cmd)
            signposter.endInterval("upscale", up)
        }
        if let onPresented {
            // Ack on the DRAWABLE's presented handler, not the command buffer's
            // completed handler: completion means the GPU finished, the
            // presentation-time protocol wants the moment the content reached the
            // display. The handler fires even for a drawable that never made it to
            // the panel (presentedTime == 0). If the process is suspended before it
            // runs, iosc's 100 ms present-ack valve retires the callbacks: that valve
            // is the net, so there is no second ack path here to race it.
            drawable.addPresentedHandler { presented in
                let at = presented.presentedTime
                DispatchQueue.main.async { onPresented(at) }
            }
        }
        cmd.present(drawable)
        cmd.commit()
        return true
    }

    /// Clear the drawable to black. The holding frame: nothing sampled, no texture
    /// kept, so it costs no memory beside a new compositor (invariant 21).
    @discardableResult
    func presentBlack() -> Bool {
        guard let layer, let drawable = layer.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return false }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        return true
    }

    // MARK: thumbnails

    /// Scale `tex` down into a small texture on the GPU and hand back a UIImage.
    /// Encoded on the shared queue, so it is ordered after every earlier sample of
    /// the same IOSurface: the caller submits its consumer-release fence after this
    /// call, never before. The readback happens in the completion handler.
    func thumbnail(of tex: MTLTexture, flipY: Bool, maxWidth: Int = 480,
                   completion: @escaping (UIImage?) -> Void) {
        let aspect = Double(tex.height) / Double(max(tex.width, 1))
        let w = max(16, min(maxWidth, tex.width))
        let h = max(16, Int((Double(w) * aspect).rounded()))
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget]
        td.storageMode = .shared
        guard let small = device.makeTexture(descriptor: td),
              let cmd = queue.makeCommandBuffer() else { completion(nil); return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = small
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        var verts: [Float] = [
            -1, 1, 0, flipY ? 1 : 0,
            -1, -1, 0, flipY ? 0 : 1,
            1, 1, 1, flipY ? 1 : 0,
            1, -1, 1, flipY ? 0 : 1,
        ]
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
            completion(nil); return
        }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&verts, length: verts.count * MemoryLayout<Float>.size, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.addCompletedHandler { cb in
            guard cb.status == .completed else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            small.getBytes(&bytes, bytesPerRow: w * 4,
                           from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let image = Self.image(bgra: bytes, width: w, height: h)
            DispatchQueue.main.async { completion(image) }
        }
        cmd.commit()
    }

    private static func image(bgra: [UInt8], width: Int, height: Int) -> UIImage? {
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let cg = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                // The shader forces alpha to 1, so ignore the fourth byte.
                bitmapInfo: CGBitmapInfo(rawValue:
                    CGImageAlphaInfo.noneSkipFirst.rawValue |
                    CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: MetalFX upscaling (opt-in; see XiosUpscale.swift)
    //
    // OFF by default: an opt-in you can measure, not a silent change to what the
    // desktop looks like. Mode resolution, most specific authority first:
    //   1. the in-app choice (the user is the most specific authority there is);
    //   2. XIOS_UPSCALE in our own environment, for a shell-launched debug run;
    //   3. the compositor's xios.json hint (its IOSC_UPSCALE, forwarded);
    //   4. off.

    private static let upscaleDefaultsKey = "XiosUpscale"
    private(set) var upscaleMode = XiosUpscaleMode.off
    private var upscaler: XiosUpscaler?
    private(set) var lastUpscaleStatus = ""
    private var compositorUpscaleHint: String?

    var hasUpscalePreference: Bool {
        (UserDefaults.standard.string(forKey: Self.upscaleDefaultsKey) ?? "").isEmpty == false
    }

    private func resolveUpscaleMode() -> XiosUpscaleMode {
        if let raw = UserDefaults.standard.string(forKey: Self.upscaleDefaultsKey), !raw.isEmpty {
            return XiosUpscaleMode.parse(raw)
        }
        if let env = ProcessInfo.processInfo.environment["XIOS_UPSCALE"], !env.isEmpty {
            return XiosUpscaleMode.parse(env)
        }
        return XiosUpscaleMode.parse(compositorUpscaleHint)
    }

    /// The presented desktop's hint changed (or a new desktop was presented).
    /// Deliberately not part of any re-adopt decision: it only changes how the app
    /// scales its own drawable.
    func setCompositorUpscaleHint(_ hint: String?) {
        compositorUpscaleHint = hint
        applyUpscaleMode(resolveUpscaleMode())
    }

    /// Apply and persist an in-app choice; nil clears it. Takes effect on the next
    /// frame, with no session restart: upscaling is present-side only.
    func setUpscalePreference(_ mode: XiosUpscaleMode?) {
        if let mode {
            UserDefaults.standard.set(mode.spec, forKey: Self.upscaleDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.upscaleDefaultsKey)
        }
        applyUpscaleMode(resolveUpscaleMode())
    }

    private func applyUpscaleMode(_ mode: XiosUpscaleMode) {
        guard mode != upscaleMode else { return }
        upscaleMode = mode
        onNeedsPresent?()
        syncUpscaler()
    }

    /// Make the MetalFX pass match `upscaleMode`. Idempotent; run once Metal exists
    /// and on every foreground, because backgrounding releases the pass and a mode
    /// that was already right would otherwise never rebuild it (invariant 19).
    func syncUpscaler() {
        guard let layer else { return }
        if upscaleMode.isOff {
            guard upscaler != nil else { return }
            upscaler?.releaseResources()
            upscaler = nil
            layer.framebufferOnly = true
            publishUpscaleStatus(nil)
            return
        }
        guard upscaler == nil else { return }
        // MetalFX writes the output texture, which framebufferOnly forbids. Only
        // relaxed while upscaling is on.
        layer.framebufferOnly = false
        upscaler = XiosUpscaler(device: device)
        onNeedsPresent?()
        if !XiosUpscaler.supported(device) { publishUpscaleStatus(nil) }
    }

    func releaseUpscalerResources() { upscaler?.releaseResources() }

    private func publishUpscaleStatus(_ plan: XiosUpscaler.Plan?) {
        let value: String
        if let upscaler, !upscaleMode.isOff {
            value = upscaler.statusValue(for: plan)
        } else {
            value = "off"
        }
        guard value != lastUpscaleStatus else { return }
        lastUpscaleStatus = value
        StatusWriter.shared.setValue("upscale", value)
    }

    /// One line describing the live upscale state and its trade-off, from what
    /// actually happened rather than what was asked for.
    var upscaleSummary: String {
        if upscaleMode.isOff {
            return "Off renders the desktop at the panel's full resolution. A lower scale "
                + "draws fewer pixels and scales up on screen: easier on the GPU, slightly softer."
        }
        switch lastUpscaleStatus {
        case let s where s.hasPrefix("off ("):
            return "Requested \(upscaleMode.title), but this GPU has no MetalFX spatial scaler; "
                + "presenting directly instead."
        case "off", "":
            return upscaleMode == .auto
                ? "Auto is on, but the desktop is already at or below the panel's resolution, "
                  + "so nothing is being upscaled."
                : "Requested \(upscaleMode.title); waiting for the next frame."
        default:
            return "Active: \(lastUpscaleStatus)"
        }
    }
}
