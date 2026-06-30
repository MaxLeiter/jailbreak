import AVFoundation
import AudioToolbox

/// Owns the app's audio session and two looping players:
///
///  * **keep-alive** — a near-silent loop kept playing while a timer is running,
///    so the `audio` background mode prevents iOS from suspending the app. That
///    lets countdowns keep ticking (and the alarm fire) even after the iPad's
///    screen auto-locks. Released when no timer runs, so the app suspends and the
///    device rests normally when idle.
///  * **alarm** — a loud "beep-beep … beep" loop, played at media volume through a
///    `.playback` session so it's heard even with the mute switch on, until the
///    finished timer is dismissed (or a 2-minute safety cutoff).
///
/// Both run through one `.playback` session; it's deactivated only when both are
/// idle. Audio is synthesized at runtime — no bundled assets.
@MainActor
final class AlarmPlayer {
    static let shared = AlarmPlayer()

    private var alarmPlayer: AVAudioPlayer?
    private var keepAlivePlayer: AVAudioPlayer?
    private var autoStop: Foundation.Timer?

    private lazy var alarmWAV: Data = AlarmPlayer.makeAlarmWAV()
    private lazy var silentWAV: Data = AlarmPlayer.makeSilentWAV()

    // MARK: Keep-alive (background survival)

    func setKeepAlive(_ on: Bool) {
        if on {
            guard keepAlivePlayer == nil else { return }
            activateSession()
            if let p = makePlayer(silentWAV) {   // amplitude is already ~inaudible
                p.play()
                keepAlivePlayer = p
            }
        } else {
            keepAlivePlayer?.stop()
            keepAlivePlayer = nil
            deactivateIfIdle()
        }
    }

    // MARK: Alarm

    func start() {
        if alarmPlayer?.isPlaying == true { return }
        activateSession()
        if let p = makePlayer(alarmWAV) {
            p.play()
            alarmPlayer = p
        } else {
            AudioServicesPlaySystemSound(1005)   // fallback if the session won't open
        }
        autoStop?.invalidate()
        autoStop = Foundation.Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    func stop() {
        autoStop?.invalidate(); autoStop = nil
        alarmPlayer?.stop(); alarmPlayer = nil
        deactivateIfIdle()
    }

    // MARK: Session plumbing

    private func activateSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, options: [.mixWithOthers])
        try? s.setActive(true)
    }
    private func deactivateIfIdle() {
        guard alarmPlayer == nil, keepAlivePlayer == nil else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func makePlayer(_ data: Data) -> AVAudioPlayer? {
        guard let p = try? AVAudioPlayer(data: data) else { return nil }
        p.numberOfLoops = -1          // loop until stopped; volume stays at the default 1.0
        p.prepareToPlay()
        return p
    }

    // MARK: Tone synthesis

    /// One "beep-beep … pause" cycle as 16-bit mono PCM, looped by the player.
    private static func makeAlarmWAV() -> Data {
        var samples = [Int16]()
        func tone(_ freq: Double, _ dur: Double) { appendTone(&samples, freq: freq, dur: dur, amp: 0.9) }
        func silence(_ dur: Double) { samples.append(contentsOf: repeatElement(0, count: Int(44100.0 * dur))) }
        tone(880, 0.16);  silence(0.10)
        tone(880, 0.16);  silence(0.10)
        tone(1175, 0.20); silence(0.75)
        return wav(samples)
    }

    /// 1s of a deep, ~inaudible tone (−80 dBFS) — "real" audio so the background
    /// mode holds the app alive, but far below anything you'd hear in a kitchen.
    private static func makeSilentWAV() -> Data {
        var samples = [Int16]()
        appendTone(&samples, freq: 30, dur: 1.0, amp: 0.0001)
        return wav(samples)
    }

    private static func appendTone(_ samples: inout [Int16], freq: Double, dur: Double, amp: Double) {
        let sr = 44100.0
        let n = Int(sr * dur)
        let ramp = 0.005 * sr
        for i in 0..<n {
            let t = Double(i) / sr
            var env = 1.0
            if Double(i) < ramp { env = Double(i) / ramp }
            else if Double(n - i) < ramp { env = Double(n - i) / ramp }
            let v = sin(2 * .pi * freq * t) * env * amp
            samples.append(Int16(max(-1, min(1, v)) * 32767))
        }
    }

    private static func wav(_ samples: [Int16]) -> Data {
        let sr = 44100.0
        let channels: UInt16 = 1, bits: UInt16 = 16
        let byteRate = UInt32(sr) * UInt32(channels) * UInt32(bits / 8)
        let blockAlign = UInt16(channels * bits / 8)
        let dataBytes = samples.count * 2

        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(u32(UInt32(36 + dataBytes)))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(u32(16))
        data.append(u16(1))                 // PCM
        data.append(u16(channels))
        data.append(u32(UInt32(sr)))
        data.append(u32(byteRate))
        data.append(u16(blockAlign))
        data.append(u16(bits))
        data.append("data".data(using: .ascii)!)
        data.append(u32(UInt32(dataBytes)))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
