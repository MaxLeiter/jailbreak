import Foundation

/// One panel's placement on the board, persisted to disk as JSON.
/// `col`/`row` are the top-left cell; `cols`/`rows` are the span in cells.
struct PanelLayout: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: PanelKind
    var col: Int
    var row: Int
    var cols: Int
    var rows: Int
    /// Free-form per-panel settings (e.g. a recipe URL, a default timer length).
    var config: [String: String] = [:]
}
