import CoreGraphics

/// The fixed grid the panels snap to. The screen is divided into
/// `columns` × `rows` cells; every panel is placed and sized in whole cells.
enum Board {
    static let columns = 12
    static let rows = 8
    static let minCols = 2
    static let minRows = 2
}
