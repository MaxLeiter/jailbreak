import SwiftUI

/// KioskMode's look: a calm "appliance" feel. One warm amber accent that reads
/// like a physical indicator light, rounded system type for headings, and system
/// materials so it sits naturally on iPadOS in light or dark.
enum Theme {
    /// Warm amber — the brand accent / "armed" indicator.
    static let accent = Color(red: 0.93, green: 0.62, blue: 0.22)
    /// Calm green — a paused/safe state.
    static let paused = Color(red: 0.36, green: 0.70, blue: 0.52)
    /// Muted slate — the off/idle state.
    static let idle = Color(red: 0.55, green: 0.57, blue: 0.62)

    /// A soft, deterministic tint for an app's monogram tile, derived from its
    /// bundle id so the same app always gets the same colour.
    static func tint(for seed: String) -> Color {
        var hash: UInt64 = 1469598103934665603
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.42, brightness: 0.82)
    }
}

extension Font {
    /// Rounded display face for titles — friendly, native, distinct from body.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// A grouped "card" surface used throughout settings and onboarding.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 1)
            )
    }
}

/// Full-width primary action button in the accent colour.
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(.display(19, .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(.black.opacity(0.85))
        }
        .buttonStyle(.plain)
    }
}

/// Rounded monogram tile standing in for an app icon (no private icon APIs).
struct Monogram: View {
    let text: String
    let seed: String
    var size: CGFloat = 52

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Theme.tint(for: seed).gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(text)
                    .font(.display(size * 0.42, .bold))
                    .foregroundStyle(.white.opacity(0.95))
            )
    }
}
