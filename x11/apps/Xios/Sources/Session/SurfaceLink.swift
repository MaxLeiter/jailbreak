import Metal
import IOSurface
import UIKit

/// The IOSurface half of one desktop connection: the XSurface.c typed stream, the
/// brokered GPU fences, and the textures wrapped around the compositor's output
/// buffers. Created already adopted (see `adopt`), used only on the main thread,
/// closed exactly once.
///
/// Frame ownership (invariants 5-10): a DIRTY record transfers one buffer to us.
/// We sample it after its present fence, keep it held for idle redraws and zoom,
/// and only when the NEXT DIRTY is accepted do we signal the consumer-release
/// fence for the held one, in order on the same Metal queue, with no CPU wait.
final class SurfaceLink {
    /// A connection's release-fence import, done on the connect thread and applied
    /// by `adopt`. ok == false fails the adopt.
    struct ReleaseFenceImport {
        var ok: Bool
        var token: Data? = nil
        var event: MTLSharedEvent? = nil
        var failure: String? = nil
    }

    enum PumpResult { case ok, lost }
    enum PresentResult { case presented, notYet, lost }

    let conn: OpaquePointer
    let compositorID: String
    private let renderer: Renderer

    private(set) var fbWidth = 0
    private(set) var fbHeight = 0
    private(set) var surfaceID: UInt32 = 0
    private var surfaceFlags: UInt32 = 0
    private var currentTexture: MTLTexture?
    private(set) var isClosed = false

    /// One texture per IOSurface the compositor exported (invariant: not one per
    /// DIRTY; iosc rotates three outputs, so recreating on every id change cost a
    /// texture per frame). Keyed by id AND the surface's identity, because an id can
    /// be retired and reused for a different buffer. Most recently used last.
    private struct CachedTexture {
        let id: UInt32
        let surface: UnsafeMutableRawPointer
        let texture: MTLTexture
    }
    private var textureCache: [CachedTexture] = []
    private static let textureCacheLimit = 6

    // Present fence (the producer's frame-complete timeline).
    private var presentFenceToken: Data?
    private var presentFenceEvent: MTLSharedEvent?
    private var presentFenceDecodeFailed = false
    // Broker imports run off main (a blocking XPC round trip). While one is out the
    // frame that needs it stays pending; a failed one is remembered so the next
    // tick fails that frame exactly as a synchronous failure would.
    private var presentFenceImportPending = false
    private var presentFenceImportToken: Data?
    private var presentFenceImportFailedToken: Data?
    // Release fence (the consumer-done timeline), imported at connect.
    private(set) var releaseFenceToken: Data?
    private(set) var releaseFenceEvent: MTLSharedEvent?
    private var pendingStreamFrame = false
    private var heldStreamFrame: (surfaceID: UInt32, seq: UInt64)?
    /// The last frame that actually reached a drawable, for thumbnails. Never the
    /// pending one: its present fence may not have been waited on yet.
    private var lastPresented: (texture: MTLTexture, flipY: Bool)?

    // MARK: connect + adopt

    /// Runs off the main thread, before the connection is handed to main, so it
    /// reads only `conn` (not yet shared) and the values captured for it.
    static func importReleaseFence(
        _ conn: OpaquePointer, device: MTLDevice?,
        cached: (token: Data?, event: MTLSharedEvent?)
    ) -> ReleaseFenceImport {
        var bytes: UnsafeRawPointer?
        var length = 0
        guard xsurface_release_fence_token(conn, &bytes, &length) != 0 else {
            // Fixed one-surface producers (currently Mutter/Xorg) retain their
            // legacy contract. They never rotate an allocation, so no consumer
            // release timeline is required (invariant 10).
            return ReleaseFenceImport(ok: true)
        }
        guard let bytes, length > 0, let device else { return ReleaseFenceImport(ok: false) }
        let token = Data(bytes: bytes, count: length)
        if token == cached.token, let event = cached.event {
            return ReleaseFenceImport(ok: true, token: token, event: event)
        }
        guard let event = xios_metal_event_broker_copy_event_timeout(
            device, bytes, length, XIOS_METAL_EVENT_BROKER_TIMEOUT_SEC
        ) else {
            return ReleaseFenceImport(ok: false, failure: "release-fence-broker-import-failed")
        }
        return ReleaseFenceImport(ok: true, token: token, event: event)
    }

    /// Takes ownership of `conn` (closes it on failure). nil when the geometry or
    /// the release fence is unusable: the caller retries the connect.
    static func adopt(conn: OpaquePointer, release: ReleaseFenceImport,
                      renderer: Renderer) -> SurfaceLink? {
        guard release.ok else { xsurface_close(conn); return nil }
        let link = SurfaceLink(conn: conn, renderer: renderer)
        link.releaseFenceToken = release.token
        link.releaseFenceEvent = release.event
        guard link.syncGeometry(onChange: {}) else {
            link.close()
            return nil
        }
        return link
    }

    private init(conn: OpaquePointer, renderer: Renderer) {
        self.conn = conn
        self.renderer = renderer
        self.compositorID = String(cString: xsurface_compositor_id(conn))
    }

    deinit { if !isClosed { close() } }

    // MARK: geometry + textures

    /// Keep Swift's framebuffer geometry and the current texture aligned with the
    /// connection. The IOSurface is the single source of truth (invariant 15); typed
    /// streams can refresh it in-band after xsurface_drain(), so this runs after
    /// every drain (invariant 16). `onChange` runs when the framebuffer size
    /// changed, before anything samples with the new size, so the caller can
    /// resetZoom first (invariant 17).
    @discardableResult
    func syncGeometry(onChange: () -> Void) -> Bool {
        let newWidth = Int(xsurface_width(conn))
        let newHeight = Int(xsurface_height(conn))
        let sourceWidth = Int(xsurface_surface_width(conn))
        let sourceHeight = Int(xsurface_surface_height(conn))
        let id = xsurface_surface_id(conn)
        let flags = xsurface_surface_flags(conn)
        guard newWidth > 0, newHeight > 0, sourceWidth > 0, sourceHeight > 0, id != 0
        else { return false }

        let geometryChanged = newWidth != fbWidth || newHeight != fbHeight
        let textureChanged = surfaceID != id ||
            currentTexture?.width != sourceWidth || currentTexture?.height != sourceHeight
        guard geometryChanged || textureChanged else { return true }

        // C owns the IOSurface ref (released in xsurface_close); borrow it here.
        let unmanaged = xsurface_get(conn)!
        let identity = unmanaged.toOpaque()
        guard let tex = cachedTexture(id: id, identity: identity,
                                      surface: unmanaged.takeUnretainedValue(),
                                      width: sourceWidth, height: sourceHeight) else {
            return false
        }
        fbWidth = newWidth
        fbHeight = newHeight
        currentTexture = tex
        surfaceID = id
        surfaceFlags = flags
        // A dropped dynamic surface must not stay pinned by a cached texture.
        textureCache.removeAll { xsurface_surface_known(conn, $0.id) == 0 }
        if geometryChanged {
            // Buffers of another size can never be shown again: drop their textures
            // so a retired allocation is not pinned in memory by our cache.
            textureCache.removeAll { $0.texture.width != sourceWidth || $0.texture.height != sourceHeight }
            onChange()
        }
        return true
    }

    private func cachedTexture(id: UInt32, identity: UnsafeMutableRawPointer,
                               surface: IOSurfaceRef, width: Int, height: Int) -> MTLTexture? {
        if let index = textureCache.firstIndex(where: {
            $0.id == id && $0.surface == identity &&
                $0.texture.width == width && $0.texture.height == height
        }) {
            let hit = textureCache.remove(at: index)
            textureCache.append(hit)
            return hit.texture
        }
        // The id now names a different buffer: forget what it used to be.
        textureCache.removeAll { $0.id == id }
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        td.usage = .shaderRead
        td.storageMode = .shared
        // Metal reads the surface's own (possibly padded) bytesPerRow; zero-copy.
        guard let tex = renderer.device.makeTexture(descriptor: td, iosurface: surface,
                                                    plane: 0) else { return nil }
        textureCache.append(CachedTexture(id: id, surface: identity, texture: tex))
        if textureCache.count > Self.textureCacheLimit { textureCache.removeFirst() }
        return tex
    }

    // MARK: per-tick work

    /// Report the display clock so the compositor can pace its repaint to the panel
    /// (invariants 2, 3: a delta from now, sent at the top of every tick).
    func sendPacing(untilDeadlineUs: Int32, intervalUs: UInt32, minMfps: Int32, maxMfps: Int32) {
        _ = xsurface_pacing(conn, untilDeadlineUs, intervalUs, minMfps, maxMfps)
    }

    /// Accept at most one DIRTY (never coalesce, invariant 5), release the frame it
    /// replaces, and resync geometry. `newFrame` is true when a frame arrived.
    func pump(onGeometryChange: () -> Void) -> (result: PumpResult, newFrame: Bool) {
        var newFrame = false
        if !pendingStreamFrame {
            let r = xsurface_drain(conn)
            if r < 0 { return (.lost, false) }
            if r > 0 {
                // The newly acquired frame replaces the one retained for idle
                // redraws: submit the previous consumer-release fence now. The empty
                // command buffer is ordered after every Metal sample of that
                // IOSurface on the same queue (invariant 6).
                if !submitHeldRelease() { return (.lost, false) }
                pendingStreamFrame = true
                newFrame = true
            }
        }
        if !syncGeometry(onChange: onGeometryChange) { return (.lost, newFrame) }
        return (.ok, newFrame)
    }

    /// Present the current frame if its fences allow it.
    func present(fit: FitTransform?) -> PresentResult {
        guard let tex = currentTexture, let fit else { return .notYet }
        let seq = xsurface_dirty_sequence(conn)
        // The IOSurface arrives before the compositor's first DIRTY record. Never
        // sample that asynchronously rendered surface until its brokered GPU fence
        // has arrived; an empty sequence here is startup ordering (invariant 8).
        if seq == 0 { return .notYet }
        let fence = gpuFence()
        // Its broker import is still out: keep the frame pending (no drain, no
        // RELEASE) and present it on a later tick (invariant 7).
        if presentFenceImportPending { return .notYet }
        if presentFenceDecodeFailed { return .lost }   // never an unfenced present (9)
        let flipY = (surfaceFlags & UInt32(XIOS_SURFACE_FLAG_FLIP_Y)) != 0
        let conn = self.conn
        let ok = renderer.render(
            tex, fit: fit, flipY: flipY,
            waitEvent: fence?.0, waitValue: fence?.1 ?? 0,
            onPresented: { [weak self] at in
                // Only this closure acks (invariant 1); a connection that was closed
                // or replaced meanwhile must not be written to.
                guard let self, !self.isClosed else { return }
                guard at > 0 else { _ = xsurface_presented(conn, seq); return }
                let ageUs = (max(0, CACurrentMediaTime() - at) * 1_000_000).rounded()
                _ = xsurface_presented_at(conn, seq,
                                          UInt32(clamping: Int(ageUs.isFinite ? ageUs : 0)))
            })
        guard ok else { return .notYet }
        lastPresented = (tex, flipY)
        if pendingStreamFrame {
            heldStreamFrame = (surfaceID, seq)
            pendingStreamFrame = false
        }
        return .presented
    }

    // MARK: fences

    private func gpuFence() -> (MTLSharedEvent, UInt64)? {
        presentFenceDecodeFailed = false
        presentFenceImportPending = false
        var bytes: UnsafeRawPointer?
        var length = 0
        var value: UInt64 = 0
        guard xsurface_gpu_fence_token(conn, &bytes, &length, &value) != 0 else {
            StatusWriter.shared.event("gpu-fence-missing-for-frame")
            presentFenceDecodeFailed = true
            return nil
        }
        guard let bytes, length > 0, value > 0 else {
            presentFenceDecodeFailed = true
            return nil
        }
        let token = Data(bytes: bytes, count: length)
        if token != presentFenceToken {
            if token == presentFenceImportFailedToken {
                presentFenceImportFailedToken = nil
                StatusWriter.shared.event("gpu-fence-broker-import-failed")
                presentFenceDecodeFailed = true
                return nil
            }
            importPresentFence(token)
            presentFenceImportPending = true
            return nil
        }
        guard let event = presentFenceEvent else {
            presentFenceDecodeFailed = true
            return nil
        }
        return (event, value)
    }

    /// Import a present-fence token on a worker queue and hand the event back to
    /// main; the tick holding the frame picks it up. A result for a token nobody is
    /// waiting on any more (closed, superseded) is dropped (invariant 11).
    private func importPresentFence(_ token: Data) {
        guard presentFenceImportToken != token else { return }   // already out
        presentFenceImportToken = token
        let device = renderer.device
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let event: MTLSharedEvent? = token.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return nil }
                return xios_metal_event_broker_copy_event_timeout(
                    device, base, raw.count, XIOS_METAL_EVENT_BROKER_TIMEOUT_SEC)
            }
            DispatchQueue.main.async {
                guard let self, !self.isClosed, self.presentFenceImportToken == token else { return }
                self.presentFenceImportToken = nil
                if let event {
                    self.presentFenceToken = token
                    self.presentFenceEvent = event
                } else {
                    self.presentFenceImportFailedToken = token
                }
            }
        }
    }

    /// Signal the consumer-release timeline for the held frame and tell the
    /// compositor. An empty command buffer on the same queue is ordered after every
    /// sample; no CPU wait (invariant 6).
    private func submitHeldRelease(quiet: Bool = false) -> Bool {
        guard let held = heldStreamFrame else { return true }
        guard let event = releaseFenceEvent else {
            heldStreamFrame = nil       // legacy fixed-output connection
            return true
        }
        guard let cb = renderer.queue.makeCommandBuffer() else { return false }
        cb.label = "Xios IOSurface consumer release"
        cb.encodeSignalEvent(event, value: held.seq)
        cb.commit()
        guard xsurface_released(conn, held.surfaceID, held.seq) == 0 else {
            // On close after an EOF the peer is already gone: not an event.
            if !quiet { StatusWriter.shared.event("release-fence-submit-send-failed") }
            return false
        }
        heldStreamFrame = nil
        return true
    }

    // MARK: thumbnail + close

    /// Capture the last presented frame as a small image. Must be called before
    /// `close()`: it encodes ahead of the release fence on the shared queue.
    func captureThumbnail(completion: @escaping (UIImage?) -> Void) {
        // While a drained frame is pending, the held one is about to be replaced and
        // the connection is mid-transition: keep the previous thumbnail.
        guard !isClosed, !pendingStreamFrame, let last = lastPresented else {
            completion(nil); return
        }
        renderer.thumbnail(of: last.texture, flipY: last.flipY, completion: completion)
    }

    /// Release the held frame, then the connection and every texture: releasing the
    /// IOSurface promptly is what keeps Xios out of the flavor-switch memory spike
    /// (invariant 20).
    func close() {
        guard !isClosed else { return }
        _ = submitHeldRelease(quiet: true)
        isClosed = true
        xsurface_close(conn)
        currentTexture = nil
        lastPresented = nil
        textureCache.removeAll()
        presentFenceToken = nil
        presentFenceEvent = nil
        presentFenceImportToken = nil
        presentFenceImportFailedToken = nil
        // The release event stays readable: the connection caches it by token
        // across reconnects, so a rotation does not pay a broker round trip.
        pendingStreamFrame = false
        heldStreamFrame = nil
    }
}
