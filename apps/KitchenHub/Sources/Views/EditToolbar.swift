import SwiftUI

/// Floating toolbar shown in edit mode: add panels, or finish editing.
struct EditToolbar: View {
    @EnvironmentObject var store: BoardStore

    var body: some View {
        HStack(spacing: 16) {
            Menu {
                ForEach(PanelKind.allCases) { kind in
                    Button {
                        store.add(kind)
                    } label: {
                        Label(kind.isImplemented ? kind.title : "\(kind.title) (soon)",
                              systemImage: kind.symbol)
                    }
                }
            } label: {
                Label("Add Panel", systemImage: "plus")
                    .font(.system(size: 16, weight: .semibold))
            }

            Divider().frame(height: 22).overlay(Theme.panelStroke)

            Button {
                withAnimation(.spring(response: 0.3)) { store.isEditing = false }
            } label: {
                Label("Done", systemImage: "checkmark")
                    .font(.system(size: 16, weight: .bold))
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.panelStroke))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 4)
    }
}
