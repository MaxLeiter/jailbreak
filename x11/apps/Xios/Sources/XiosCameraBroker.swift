import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation

private let xiosMediaMagic: UInt32 = 0x4d4f4958
private let xiosMediaVersion: UInt32 = 1
private let xiosMediaVideoSocket = "/var/jb/tmp/xios-media-video.sock"
private let xiosMediaMsgVideoFrame: UInt32 = 1
private let xiosMediaVideoFmtBGRA32: UInt32 = 1

private struct XiosMediaMsg {
    var magic: UInt32
    var version: UInt32
    var type: UInt32
    var size: UInt32
}

private struct XiosMediaVideoFrame {
    var timestampNs: UInt64
    var width: UInt32
    var height: UInt32
    var stride: UInt32
    var format: UInt32
    var frameIndex: UInt32
    var flags: UInt32
}

final class XiosCameraBroker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = XiosCameraBroker()

    private let acceptQueue = DispatchQueue(label: "xios.camera.accept")
    private let captureQueue = DispatchQueue(label: "xios.camera.capture")
    private let clientLock = NSLock()
    private var clients: [Int32] = []
    private var listener: Int32 = -1
    private var session: AVCaptureSession?
    private var captureRequested = false
    private var captureRunning = false
    private var frameIndex: UInt32 = 0
    private var started = false

    func start() {
        if started { return }
        started = true
        startSocket()
    }

    private func startSocket() {
        unlink(xiosMediaVideoSocket)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log("socket failed: \(errno)")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(xiosMediaVideoSocket.utf8) + [0]
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        if pathBytes.count > sunPathCapacity {
            close(fd)
            log("socket path too long")
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { dst in
                for i in 0..<pathBytes.count {
                    dst[i] = CChar(bitPattern: pathBytes[i])
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            log("bind \(xiosMediaVideoSocket) failed: \(errno)")
            close(fd)
            return
        }
        chmod(xiosMediaVideoSocket, 0o666)

        guard listen(fd, 16) == 0 else {
            log("listen failed: \(errno)")
            close(fd)
            unlink(xiosMediaVideoSocket)
            return
        }
        listener = fd
        log("video socket listening at \(xiosMediaVideoSocket)")

        acceptQueue.async { [weak self] in
            self?.acceptLoop(fd: fd)
        }
    }

    private func acceptLoop(fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            #if os(iOS)
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            clientLock.lock()
            clients.append(client)
            clientLock.unlock()
            log("video client connected")
            requestCaptureForClient()
        }
    }

    private func clientCount() -> Int {
        clientLock.lock()
        let count = clients.count
        clientLock.unlock()
        return count
    }

    private func requestCaptureForClient() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            guard !self.captureRequested, !self.captureRunning else { return }
            guard self.clientCount() > 0 else { return }
            self.captureRequested = true
            self.startCaptureAfterAuthorization()
        }
    }

    private func startCaptureAfterAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                self.captureQueue.async {
                    guard self.captureRequested else { return }
                    guard self.clientCount() > 0 else {
                        self.captureRequested = false
                        return
                    }
                    if granted {
                        self.startCapture()
                    } else {
                        self.captureRequested = false
                        self.log("camera authorization denied")
                    }
                }
            }
        default:
            captureRequested = false
            log("camera authorization unavailable: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
        }
    }

    private func startCapture() {
        guard !captureRunning else { return }
        guard clientCount() > 0 else {
            captureRequested = false
            return
        }
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
        let ordered = devices.filter { $0.position == .front } + devices.filter { $0.position != .front }
        guard let device = ordered.first ?? AVCaptureDevice.default(for: .video) else {
            captureRequested = false
            log("no camera device")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.setSampleBufferDelegate(self, queue: captureQueue)

            let session = AVCaptureSession()
            if session.canSetSessionPreset(.vga640x480) {
                session.sessionPreset = .vga640x480
            }
            guard session.canAddInput(input), session.canAddOutput(output) else {
                captureRequested = false
                log("cannot add camera input/output")
                return
            }
            session.addInput(input)
            session.addOutput(output)
            session.startRunning()
            self.session = session
            captureRunning = true
            log("camera started: \(device.localizedName)")
        } catch {
            captureRequested = false
            log("camera input failed for \(device.localizedName): \(error.localizedDescription)")
        }
    }

    private func stopCaptureIfIdle() {
        guard clientCount() == 0, captureRunning else { return }
        session?.stopRunning()
        session = nil
        captureRunning = false
        captureRequested = false
        log("camera stopped: no clients")
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(image) else { return }
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        let stride = CVPixelBufferGetBytesPerRow(image)
        let byteCount = stride * height
        guard clientCount() > 0 else {
            stopCaptureIfIdle()
            return
        }
        guard width <= UInt32.max, height <= UInt32.max, stride <= UInt32.max else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(pts)
        let timestampNs: UInt64 =
            seconds.isFinite && seconds > 0 ? UInt64(seconds * 1_000_000_000.0) : 0

        frameIndex &+= 1
        var frame = XiosMediaVideoFrame(
            timestampNs: timestampNs,
            width: UInt32(width),
            height: UInt32(height),
            stride: UInt32(stride),
            format: xiosMediaVideoFmtBGRA32,
            frameIndex: frameIndex,
            flags: 0
        )
        if broadcast(frame: &frame, bytes: UnsafeRawBufferPointer(start: base, count: byteCount)) == 0 {
            stopCaptureIfIdle()
        }
    }

    private func broadcast(frame: inout XiosMediaVideoFrame, bytes: UnsafeRawBufferPointer) -> Int {
        var msg = XiosMediaMsg(
            magic: xiosMediaMagic,
            version: xiosMediaVersion,
            type: xiosMediaMsgVideoFrame,
            size: UInt32(MemoryLayout<XiosMediaVideoFrame>.size + bytes.count)
        )

        clientLock.lock()
        var alive: [Int32] = []
        for fd in clients {
            let ok = withUnsafeBytes(of: &msg) { writeAll(fd: fd, bytes: $0) } &&
                     withUnsafeBytes(of: &frame) { writeAll(fd: fd, bytes: $0) } &&
                     writeAll(fd: fd, bytes: bytes)
            if ok {
                alive.append(fd)
            } else {
                close(fd)
            }
        }
        clients = alive
        let aliveCount = alive.count
        clientLock.unlock()
        return aliveCount
    }

    private func writeAll(fd: Int32, bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        var sent = 0
        while sent < bytes.count {
            let n = Darwin.send(fd, base.advanced(by: sent), bytes.count - sent, 0)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            sent += n
        }
        return true
    }

    private func log(_ message: String) {
        let line = "XiosCameraBroker: \(message)\n"
        if let data = line.data(using: .utf8),
           let handle = FileHandle(forWritingAtPath: "/var/jb/tmp/xios-camera-broker.log") {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? line.write(toFile: "/var/jb/tmp/xios-camera-broker.log",
                            atomically: true,
                            encoding: .utf8)
        }
        NSLog("%@", line)
    }
}
