import SwiftUI

/// The raised surface every dashboard tile and the list container sit on: card
/// fill, hairline ring (a 1px stroke, not a heavy border), rounded corners.
private struct CardBackground: ViewModifier {
    var padding: CGFloat = Theme.cardPadding

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = Theme.cardPadding) -> some View {
        modifier(CardBackground(padding: padding))
    }

    /// Small caps-y section label used above tiles and stat groups.
    func tileLabel() -> some View {
        self.font(.caption).fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.5)
    }
}
