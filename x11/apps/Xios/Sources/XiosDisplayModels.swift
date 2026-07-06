import Foundation

struct DisplayProfile {
    let name: String
    let width: Int
    let height: Int
    let dpi: Int
    let detail: String
}

struct SessionStatus {
    let preset: String
    let state: String
    let message: String
    let width: Int?
    let height: Int?
    let display: String?
    let ddx: String?

    static func load(from path: String) -> SessionStatus? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return SessionStatus(
            preset: obj["preset"] as? String ?? "?",
            state: obj["state"] as? String ?? "?",
            message: obj["message"] as? String ?? "",
            width: obj["width"] as? Int,
            height: obj["height"] as? Int,
            display: obj["display"] as? String,
            ddx: obj["ddx"] as? String)
    }
}

struct LauncherApp {
    let id: String
    let name: String
    let exec: String
    let icon: String
    let bundlePath: String
    let enabled: Bool

    static func parseIOSCDLine(_ line: String) -> LauncherApp? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 6 else { return nil }
        return LauncherApp(
            id: String(fields[0]),
            name: String(fields[1]),
            exec: String(fields[2]),
            icon: String(fields[3]),
            bundlePath: String(fields[4]),
            enabled: String(fields[5]).lowercased() != "disabled")
    }
}

struct DesktopPreset {
    let preset: String
    let title: String
    let detail: String
    let iconName: String
}

struct QuickLaunchApp {
    let title: String
    let exec: String
    let iconName: String
}
