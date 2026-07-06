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
}

struct LauncherApp {
    let id: String
    let name: String
    let exec: String
    let icon: String
    let bundlePath: String
    let enabled: Bool
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
