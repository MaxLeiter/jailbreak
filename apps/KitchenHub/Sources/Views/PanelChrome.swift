import SwiftUI

/// Positions a single panel on the grid and, in edit mode, adds drag-to-move,
/// a resize handle, and a delete button. In view mode it's just the content.
struct PanelChrome: View {
    let panel: PanelLayout
    let cellW: CGFloat
    let cellH: CGFloat
    @EnvironmentObject var store: BoardStore

    @State private var moveBy: CGSize = .zero
    @State private var resizeBy: CGSize = .zero

    private var baseX: CGFloat { CGFloat(panel.col) * cellW }
    private var baseY: CGFloat { CGFloat(panel.row) * cellH }
    private var baseW: CGFloat { CGFloat(panel.cols) * cellW }
    private var baseH: CGFloat { CGFloat(panel.rows) * cellH }

    var body: some View {
        let w = max(cellW * CGFloat(Board.minCols), baseW + resizeBy.width)
        let h = max(cellH * CGFloat(Board.minRows), baseH + resizeBy.height)

        let card = ZStack(alignment: .bottomTrailing) {
            PanelContent(panel: panel)
                .allowsHitTesting(!store.isEditing)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.panelBg,
                            in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .stroke(store.isEditing ? Theme.accent.opacity(0.85) : Theme.panelStroke,
                                lineWidth: store.isEditing ? 2 : 1)
                )

            if store.isEditing { resizeHandle }
        }
        .frame(width: w, height: h)
        .overlay(alignment: .topLeading) {
            if store.isEditing { deleteButton }
        }
        .padding(Theme.gap / 2)
        .offset(x: baseX + moveBy.width, y: baseY + moveBy.height)
        .zIndex(store.isEditing ? 1 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: panel)

        if store.isEditing {
            card.gesture(moveGesture)
        } else {
            card
        }
    }

    // MARK: Gestures

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { moveBy = $0.translation }
            .onEnded { value in
                var p = panel
                p.col = Int(((baseX + value.translation.width) / cellW).rounded())
                p.row = Int(((baseY + value.translation.height) / cellH).rounded())
                store.replace(p)
                moveBy = .zero
            }
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 30, height: 30)
            .background(Theme.accent, in: Circle())
            .padding(6)
            .highPriorityGesture(
                DragGesture()
                    .onChanged { resizeBy = $0.translation }
                    .onEnded { value in
                        var p = panel
                        p.cols = Int(((baseW + value.translation.width) / cellW).rounded())
                        p.rows = Int(((baseH + value.translation.height) / cellH).rounded())
                        store.replace(p)
                        resizeBy = .zero
                    }
            )
    }

    private var deleteButton: some View {
        Button {
            withAnimation { store.remove(panel.id) }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.red.opacity(0.92), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(6)
    }
}
