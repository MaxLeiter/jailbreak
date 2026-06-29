import SwiftUI

/// Owns the board: the list of panels, edit mode, and JSON persistence.
@MainActor
final class BoardStore: ObservableObject {
    @Published var panels: [PanelLayout] = []
    @Published var isEditing = false

    private let saveURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        saveURL = docs.appendingPathComponent("layout.json")
        load()
    }

    // MARK: Persistence

    func load() {
        if let data = try? Data(contentsOf: saveURL),
           let decoded = try? JSONDecoder().decode([PanelLayout].self, from: data),
           !decoded.isEmpty {
            panels = decoded
        } else {
            panels = Self.defaultLayout()
            save()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(panels) {
            try? data.write(to: saveURL, options: .atomic)
        }
    }

    // MARK: Mutations

    func replace(_ panel: PanelLayout) {
        guard let idx = panels.firstIndex(where: { $0.id == panel.id }) else { return }
        panels[idx] = clamped(panel)
        save()
    }

    func add(_ kind: PanelKind) {
        let size = kind.defaultSize
        let spot = firstFreeSpot(cols: size.cols, rows: size.rows)
        panels.append(PanelLayout(kind: kind, col: spot.col, row: spot.row,
                                  cols: size.cols, rows: size.rows))
        save()
    }

    func remove(_ id: UUID) {
        panels.removeAll { $0.id == id }
        save()
    }

    /// Merge key/value settings into a panel's config and persist.
    func setConfig(_ id: UUID, _ updates: [String: String]) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        for (k, v) in updates { panels[idx].config[k] = v }
        save()
    }

    /// Keep a panel inside the board and no smaller than the minimum size.
    func clamped(_ panel: PanelLayout) -> PanelLayout {
        var p = panel
        p.cols = min(max(p.cols, Board.minCols), Board.columns)
        p.rows = min(max(p.rows, Board.minRows), Board.rows)
        p.col  = min(max(p.col, 0), Board.columns - p.cols)
        p.row  = min(max(p.row, 0), Board.rows - p.rows)
        return p
    }

    // MARK: Placement helpers

    /// First top-left cell where a `cols`×`rows` panel doesn't overlap an existing one.
    private func firstFreeSpot(cols: Int, rows: Int) -> (col: Int, row: Int) {
        let maxRow = max(0, Board.rows - rows)
        let maxCol = max(0, Board.columns - cols)
        for r in 0...maxRow {
            for c in 0...maxCol where !overlapsAny(col: c, row: r, cols: cols, rows: rows) {
                return (c, r)
            }
        }
        return (0, 0)   // board full — drop it at the origin, user can move it
    }

    private func overlapsAny(col: Int, row: Int, cols: Int, rows: Int) -> Bool {
        panels.contains { p in
            col < p.col + p.cols && col + cols > p.col &&
            row < p.row + p.rows && row + rows > p.row
        }
    }

    // MARK: Default board

    static func defaultLayout() -> [PanelLayout] {
        [
            PanelLayout(kind: .clock,   col: 0, row: 0, cols: 4, rows: 3),
            PanelLayout(kind: .weather, col: 4, row: 0, cols: 4, rows: 3),
            PanelLayout(kind: .timer,   col: 8, row: 0, cols: 4, rows: 3),
            PanelLayout(kind: .recipe,  col: 0, row: 3, cols: 12, rows: 5),
        ]
    }
}
