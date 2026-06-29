import SwiftUI

/// Root view: lays the panels onto the grid and hosts edit mode.
struct BoardView: View {
    @EnvironmentObject var store: BoardStore

    var body: some View {
        GeometryReader { geo in
            let cellW = geo.size.width / CGFloat(Board.columns)
            let cellH = geo.size.height / CGFloat(Board.rows)

            ZStack(alignment: .topLeading) {
                Theme.bg.ignoresSafeArea()

                if store.isEditing {
                    GridGuides(cellW: cellW, cellH: cellH)
                }

                ForEach(store.panels) { panel in
                    PanelChrome(panel: panel, cellW: cellW, cellH: cellH)
                }

                if store.isEditing {
                    EditToolbar()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 28)
                } else {
                    EditHandle()
                }
            }
        }
        .ignoresSafeArea()
        .environmentObject(store)
    }
}
