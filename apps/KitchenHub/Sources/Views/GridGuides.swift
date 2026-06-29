import SwiftUI

/// Faint grid overlay shown only in edit mode so snapping is legible.
struct GridGuides: View {
    let cellW: CGFloat
    let cellH: CGFloat

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            for c in 0...Board.columns {
                let x = CGFloat(c) * cellW
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for r in 0...Board.rows {
                let y = CGFloat(r) * cellH
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(path, with: .color(.white.opacity(0.07)), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
