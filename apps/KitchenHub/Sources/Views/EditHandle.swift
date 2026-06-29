import SwiftUI

/// Unobtrusive corner control. A *long press* enters edit mode, so a stray tap
/// while cooking never rearranges the board. (Later the kiosk tweak can hide
/// this entirely while docked.)
struct EditHandle: View {
    @EnvironmentObject var store: BoardStore

    var body: some View {
        Image(systemName: "slider.horizontal.3")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.subtext)
            .frame(width: 44, height: 44)
            .background(Theme.panelBg.opacity(0.6), in: Circle())
            .overlay(Circle().stroke(Theme.panelStroke))
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .onLongPressGesture(minimumDuration: 0.7) {
                withAnimation(.spring(response: 0.3)) { store.isEditing = true }
            }
            .accessibilityLabel("Edit layout — long press")
    }
}
