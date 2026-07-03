import SwiftUI

/// Visual system for the app. Dark-first: the app forces dark mode, and the
/// resource colors are the validated dark-surface steps (see the dataviz
/// palette). Marks carry these colors; text always uses semantic tokens
/// (`.primary`/`.secondary`) so identity comes from the mark beside the text,
/// never from tinting the text.
enum Theme {
    /// CPU accent — categorical blue. Every CPU mark (sparklines, core bars,
    /// the overall trend) uses exactly this hue so CPU reads as one thing.
    static let cpu = Color(hex: 0x3987E5)
    /// Memory accent — categorical aqua. CVD ΔE 69.8 vs `cpu` (well clear of
    /// the ≥12 target), so the two resources never blur together.
    static let memory = Color(hex: 0x199E70)

    /// Page + card surfaces. Near-black page with a raised card, echoing the
    /// dataviz dark surfaces while staying at home on iOS.
    static let page = Color(hex: 0x0D0D0D)
    static let card = Color(hex: 0x1A1A19)
    static let cardStroke = Color.white.opacity(0.06)
    /// One-step-off-surface hairline, for gridlines and dividers.
    static let hairline = Color.white.opacity(0.08)

    // Spacing scale.
    static let gutter: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let cardRadius: CGFloat = 16
    static let tileSpacing: CGFloat = 12

    /// Severity for a fraction that fills a track (memory, a busy core). Kept
    /// off the resource hues so a full ring never impersonates a CPU/memory
    /// mark; always paired with a visible number, never color alone.
    static func load(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.75: return memory
        case ..<0.9:  return Color(hex: 0xFAB219)  // status: warning
        default:      return Color(hex: 0xD03B3B)  // status: critical
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Formatting

enum Fmt {
    /// Compact memory string: 842 MB, 1.4 GB.
    static func memory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    static func percent(_ value: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", value)
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "—" }
        let s = Int(seconds)
        let (d, h, m) = (s / 86_400, (s % 86_400) / 3_600, (s % 3_600) / 60)
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
