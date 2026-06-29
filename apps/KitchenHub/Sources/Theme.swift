import SwiftUI

/// Central look-and-feel. Tuned for a dark, glanceable kitchen wall panel.
enum Theme {
    static let bg          = Color(red: 0.05, green: 0.055, blue: 0.07)
    static let panelBg     = Color(red: 0.11, green: 0.12, blue: 0.15)
    static let panelStroke = Color.white.opacity(0.08)
    static let accent      = Color(red: 0.97, green: 0.64, blue: 0.22)   // warm amber
    static let text        = Color.white
    static let subtext     = Color.white.opacity(0.55)

    static let corner: CGFloat = 20
    static let gap: CGFloat = 10        // visual gutter between panels (points)
}
