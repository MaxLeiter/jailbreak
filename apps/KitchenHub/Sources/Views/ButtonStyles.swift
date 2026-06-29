import SwiftUI

/// Pill used for the timer's quick-set presets.
struct PresetButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.text)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(configuration.isPressed ? 0.20 : 0.08), in: Capsule())
    }
}

/// Round transport control. `prominent` is the play/pause button (amber).
struct ControlButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(prominent ? .black : Theme.text)
            .frame(width: prominent ? 66 : 54, height: 54)
            .background(prominent ? Theme.accent : Color.white.opacity(0.08), in: Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
