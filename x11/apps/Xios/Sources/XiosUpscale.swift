import Foundation
import Metal
import MetalFX

/// Present-side MetalFX spatial upscaling (docs/ios-platform-features.md §2).
///
/// The iPad 7 panel is 2160x1620 driven by an A10 whose `thermalState` is already
/// `serious` at idle, so every pixel the desktop composites at native resolution is
/// paid for twice: once by the compositor's GL pass and once by our present pass
/// sampling it. Compositing below native and letting MetalFX scale up on present
/// trades some sharpness for a large, cheap saving.
///
/// This is entirely present-side. The compositor's output IOSurface, its wl_output
/// state, and every Wayland client's view of the desktop are untouched — no client
/// can observe it, which is why it can be a runtime switch rather than a session
/// property.
///
/// Device-probed on the target (iPad7,12, A10 GPU, families Apple1-3 + Common1-2):
/// `MTLFXSpatialScalerDescriptor.supportsDevice` = YES, temporal = NO. That inverts
/// the usual assumption that MetalFX needs recent silicon, and is why the gate here
/// is the runtime `supportsDevice` call and never a GPU-family check. MetalFX is
/// also weak-linked (see project.yml), so the class lookup below is what keeps a
/// device without the framework on the plain direct-present path instead of
/// crashing on a null class.
enum XiosUpscaleMode: Equatable {
    /// Direct present, exactly as before this existed. The default.
    case off
    /// Upscale only when the compositor is ALREADY producing a surface smaller than
    /// the drawable — i.e. someone lowered iosc's `-logical`/`-scale` and we should
    /// stop letting a bilinear sampler stretch it.
    case auto
    /// Always composite into an intermediate of drawable/factor and scale up.
    /// Exercises the win without reconfiguring the compositor.
    case factor(Double)

    /// Parses the `XIOS_UPSCALE` environment value or xios.json's `upscale` field.
    /// Anything unrecognised is `off`: a typo in a perf knob must not silently change
    /// what the user sees.
    static func parse(_ raw: String?) -> XiosUpscaleMode {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces).lowercased(),
              !trimmed.isEmpty else { return .off }
        switch trimmed {
        case "0", "1", "off", "no", "false", "none":
            return .off                       // factor 1 is a no-op, so it means off
        case "auto", "on", "yes", "true":
            return .auto
        default:
            guard let f = Double(trimmed), f > 1.0, f <= 4.0 else { return .off }
            return .factor(f)
        }
    }

    var isOff: Bool { self == .off }
}

/// Owns the intermediate render target and the scaler, and rebuilds both when the
/// geometry changes. One instance per XScreenView; `nil` plan means present directly.
final class XiosUpscaler {
    /// Where the desktop is composited, and where MetalFX puts the result.
    struct Plan {
        /// Render the desktop into this instead of the drawable.
        let source: MTLTexture
        /// MetalFX's destination. When `staging` is nil this IS the drawable texture.
        let staging: MTLTexture?
        let scaler: MTLFXSpatialScaler
        let inputSize: (width: Int, height: Int)
        let outputSize: (width: Int, height: Int)
    }

    private let device: MTLDevice
    private var source: MTLTexture?
    private var staging: MTLTexture?
    private var scaler: MTLFXSpatialScaler?
    private var builtFor: (inW: Int, inH: Int, outW: Int, outH: Int)?
    /// Whether MetalFX may write the CAMetalLayer drawable directly. Decided from the
    /// drawable's actual usage on the first upscaled frame rather than assumed: a
    /// drawable without `.shaderWrite` is a Metal validation abort, not a soft
    /// failure, and `framebufferOnly = false` is documented to relax the usage but
    /// not to promise a specific set.
    private var directToDrawable: Bool?

    /// Cached answer to "can this GPU's MetalFX do a spatial scale at all". The
    /// NSClassFromString probe comes FIRST: with MetalFX weak-linked, a device
    /// missing the framework binds the class symbol to null, and touching the type
    /// before this check is what would crash.
    private static var supportCache: [ObjectIdentifier: Bool] = [:]
    static func supported(_ device: MTLDevice) -> Bool {
        let key = ObjectIdentifier(device)
        if let known = supportCache[key] { return known }
        var ok = false
        if NSClassFromString("MTLFXSpatialScalerDescriptor") != nil {
            ok = MTLFXSpatialScalerDescriptor.supportsDevice(device)
        }
        supportCache[key] = ok
        return ok
    }

    init(device: MTLDevice) {
        self.device = device
    }

    /// Intermediate size for `mode`, or nil when this frame should present directly.
    ///
    /// Always `drawable / factor` for some factor > 1, never an arbitrary size: the
    /// caller reuses the drawable's normalised-device vertices to frame the desktop in
    /// the intermediate, and that only holds if the intermediate is a UNIFORM scale of
    /// the drawable. A differently-shaped intermediate would stretch the desktop.
    ///
    /// `source` is the compositor's own output surface in pixels. In `.auto` it picks
    /// the factor: when the compositor is already producing fewer pixels than the
    /// panel, compositing our present pass at that same density and scaling up with a
    /// tuned edge-directed filter beats stretching it with a bilinear sampler.
    private func targetSize(mode: XiosUpscaleMode,
                            drawable: (width: Int, height: Int),
                            source: (width: Int, height: Int)) -> (width: Int, height: Int)? {
        let factor: Double
        switch mode {
        case .off:
            return nil
        case .auto:
            guard source.width > 0, source.height > 0 else { return nil }
            // The factor by which the panel out-resolves the compositor. At or below 1
            // the surface already carries at least a panel's worth of detail, and
            // routing it through a smaller intermediate would discard information for
            // nothing — so auto stays off there.
            let byWidth = Double(drawable.width) / Double(source.width)
            let byHeight = Double(drawable.height) / Double(source.height)
            factor = min(byWidth, byHeight)
            guard factor > 1.05 else { return nil }   // ignore rounding-scale noise
        case .factor(let f):
            factor = f
        }
        guard factor > 1 else { return nil }
        let w = Int((Double(drawable.width) / factor).rounded())
        let h = Int((Double(drawable.height) / factor).rounded())
        guard w > 0, h > 0, w < drawable.width, h < drawable.height else { return nil }
        return (w, h)
    }

    /// Build (or reuse) the pass for this frame. Returns nil when this frame should
    /// present directly — mode off, geometry that does not want scaling, an
    /// unsupported GPU, or any allocation failure. Every nil is a clean degrade to
    /// the pre-existing path, never a dropped frame.
    func plan(mode: XiosUpscaleMode,
              drawableWidth: Int,
              drawableHeight: Int,
              sourceWidth: Int,
              sourceHeight: Int,
              drawableTexture: MTLTexture,
              pixelFormat: MTLPixelFormat) -> Plan? {
        guard !mode.isOff, drawableWidth > 0, drawableHeight > 0 else { return nil }
        guard Self.supported(device) else { return nil }
        guard let target = targetSize(
            mode: mode,
            drawable: (drawableWidth, drawableHeight),
            source: (sourceWidth, sourceHeight)) else { return nil }

        // Decide the destination once we can see a real drawable.
        if directToDrawable == nil {
            directToDrawable = drawableTexture.usage.contains(.shaderWrite)
        }
        let direct = directToDrawable ?? false

        let want = (inW: target.width, inH: target.height,
                    outW: drawableWidth, outH: drawableHeight)
        let stale = builtFor.map { $0 != want } ?? true
        if stale || source == nil || scaler == nil || (!direct && staging == nil) {
            guard rebuild(want, format: pixelFormat, direct: direct) else { return nil }
        }
        guard let source, let scaler else { return nil }
        return Plan(source: source,
                    staging: direct ? nil : staging,
                    scaler: scaler,
                    inputSize: (target.width, target.height),
                    outputSize: (drawableWidth, drawableHeight))
    }

    private func rebuild(_ want: (inW: Int, inH: Int, outW: Int, outH: Int),
                         format: MTLPixelFormat, direct: Bool) -> Bool {
        source = nil; staging = nil; scaler = nil; builtFor = nil

        let sd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: want.inW, height: want.inH, mipmapped: false)
        sd.usage = [.renderTarget, .shaderRead]
        sd.storageMode = .private
        guard let src = device.makeTexture(descriptor: sd) else { return false }

        var stage: MTLTexture?
        if !direct {
            // The drawable would not accept a shader write, so MetalFX lands here and
            // we blit across. A blit is a plain copy rather than a render pass, which
            // is the cheapest way to pay for the drawable's usage restriction.
            let od = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: want.outW, height: want.outH, mipmapped: false)
            od.usage = [.shaderWrite, .shaderRead, .renderTarget]
            od.storageMode = .private
            guard let s = device.makeTexture(descriptor: od) else { return false }
            stage = s
        }

        let desc = MTLFXSpatialScalerDescriptor()
        desc.inputWidth = want.inW
        desc.inputHeight = want.inH
        desc.outputWidth = want.outW
        desc.outputHeight = want.outH
        desc.colorTextureFormat = format
        desc.outputTextureFormat = format
        // The desktop is already tone-mapped, gamma-encoded LDR content, which is
        // what `perceptual` describes; `linear` would over-sharpen the midtones.
        desc.colorProcessingMode = .perceptual
        guard let s = desc.makeSpatialScaler(device: device) else { return false }
        s.inputContentWidth = want.inW
        s.inputContentHeight = want.inH

        source = src
        staging = stage
        scaler = s
        builtFor = want
        return true
    }

    /// Encode the scale for a frame whose desktop is already rendered into
    /// `plan.source`. Writes straight into `drawableTexture` when the drawable allows
    /// it, otherwise into the staging texture followed by a blit.
    func encode(_ plan: Plan, into drawableTexture: MTLTexture,
                commandBuffer cmd: MTLCommandBuffer) {
        plan.scaler.colorTexture = plan.source
        plan.scaler.outputTexture = plan.staging ?? drawableTexture
        plan.scaler.encode(commandBuffer: cmd)
        if let staging = plan.staging, let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: staging, to: drawableTexture)
            blit.endEncoding()
        }
    }

    /// One-line description for the `upscale` status key. Upscaling changes what the
    /// user sees, so it must never be undiscoverable (§0).
    func statusValue(for plan: Plan?) -> String {
        guard let plan else {
            return Self.supported(device) ? "off" : "off (GPU has no MetalFX spatial scaler)"
        }
        let path = plan.staging == nil ? "direct" : "via-staging-blit"
        return "\(plan.inputSize.width)x\(plan.inputSize.height)"
            + "->\(plan.outputSize.width)x\(plan.outputSize.height)"
            + " metalfx-spatial \(path)"
    }

    /// Drop the GPU allocations (app backgrounded, compositor lost, mode turned off).
    func releaseResources() {
        source = nil; staging = nil; scaler = nil; builtFor = nil
    }
}
