import Foundation
import SwiftUI
import Network

/// Observable wrapper around the Companion `CompanionClient`, exposing a simple
/// remote API to the UI. Keeps a persistent encrypted session and reconnects
/// lazily if it drops. Reuses stored pairing credentials (no in-app pairing yet).
@MainActor
final class AppleTVController: ObservableObject {
    enum Status: Equatable {
        case idle, connecting, connected, failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// Briefly set to the last button pressed, for subtle UI feedback.
    @Published private(set) var pulse: HidCommand?

    private var client: CompanionClient?
    private var connecting: Task<Bool, Never>?

    var deviceName: String { AppleTVConfig.name }
    var isConfigured: Bool { CompanionCredentials(string: AppleTVConfig.credentials) != nil }

    // MARK: Connection

    /// Establish the session if not already up. Returns true when connected.
    @discardableResult
    func connect() async -> Bool {
        if case .connected = status, client != nil { return true }
        if let connecting { return await connecting.value }

        guard let creds = CompanionCredentials(string: AppleTVConfig.credentials) else {
            status = .failed("Missing credentials"); return false
        }

        status = .connecting
        let task = Task { () -> Bool in
            // Prefer Bonjour (auto-follows the TV's IP); fall back to the
            // configured IP if mDNS resolution fails.
            let candidates: [CompanionClient] = [
                CompanionClient(endpoint: .service(name: AppleTVConfig.name,
                                                   type: "_companion-link._tcp",
                                                   domain: "local.", interface: nil),
                                credentials: creds),
                CompanionClient(host: AppleTVConfig.host, port: AppleTVConfig.port, credentials: creds),
            ]
            var lastError = "Unreachable"
            for c in candidates {
                do {
                    try await c.start()
                    self.client = c
                    self.status = .connected
                    return true
                } catch {
                    lastError = Self.describe(error)
                    c.close()
                }
            }
            self.client = nil
            self.status = .failed(lastError)
            return false
        }
        connecting = task
        let ok = await task.value
        connecting = nil
        return ok
    }

    func disconnect() {
        client?.close()
        client = nil
        status = .idle
    }

    // MARK: Commands

    func send(_ command: HidCommand) {
        Task {
            if await connect(), let client {
                do {
                    try await client.press(command)
                    flashPulse(command)
                } catch {
                    // Session likely dropped — reset so the next press reconnects.
                    self.client = nil
                    self.status = .failed(Self.describe(error))
                }
            }
        }
    }

    /// Forward a trackpad touch sample (phase 1=press, 3=move, 4=release; coords [0,1000]).
    func touch(x: Int, y: Int, phase: Int) {
        guard case .connected = status, let client else { return }
        client.touch(x: x, y: y, phase: phase)
    }

    private func flashPulse(_ command: HidCommand) {
        pulse = command
        Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            if pulse == command { pulse = nil }
        }
    }

    // Convenience actions used by the remote UI.
    func up() { send(.up) }
    func down() { send(.down) }
    func left() { send(.left) }
    func right() { send(.right) }
    func select() { send(.select) }
    func menu() { send(.menu) }
    func home() { send(.home) }
    func playPause() { send(.playPause) }
    func volumeUp() { send(.volumeUp) }
    func volumeDown() { send(.volumeDown) }

    private static func describe(_ error: Error) -> String {
        if let e = error as? ClientError {
            switch e {
            case .timeout: return "No response"
            case .notConnected: return "Not connected"
            case .badResponse: return "Bad response"
            case .commandFailed(let m): return m
            }
        }
        return "\(error)"
    }
}
