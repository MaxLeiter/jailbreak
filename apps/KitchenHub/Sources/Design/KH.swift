import SwiftUI
import UIKit

/// KitchenHub design system (redesign). Light + dark adapt automatically via
/// dynamic UIColors, so views just use `KH.bg`, `KH.textPrimary`, etc. and the
/// whole UI flips when the root sets `.preferredColorScheme`.
enum KH {
    // MARK: Surfaces (light, dark)
    static let bg          = dyn(0xF0EFEA, 0x0A0A0B)
    static let card        = dyn(0xFFFFFF, 0x161719)   // neutral card (clock / recipe)
    static let cardRaised  = dyn(0xFFFFFF, 0x1D1E21)   // insets within a screen
    static let textPrimary   = dyn(0x141414, 0xFFFFFF)
    static let textSecondary = dynA(0x141414, 0.55, 0xFFFFFF, 0.60)
    static let textFaint     = dynA(0x141414, 0.35, 0xFFFFFF, 0.38)
    static let hairline      = dynA(0x000000, 0.08, 0xFFFFFF, 0.10)
    static let fill          = dynA(0x000000, 0.05, 0xFFFFFF, 0.08)   // subtle button/track fill

    // MARK: Accents (vibrant; same in both themes). `*On` = text/icon on the accent.
    static let amber  = Color(hex: 0xE2A32B)   // weather
    static let orange = Color(hex: 0xE05A38)   // timer
    static let green  = Color(hex: 0x4E9E5F)   // music
    static let onAccent      = Color.white
    static let onAccentDim   = Color.white.opacity(0.72)
    /// On the amber weather card the big text reads dark in the mock.
    static let onAmber       = Color.black.opacity(0.82)

    static func weatherGradient() -> LinearGradient {
        LinearGradient(colors: [Color(hex: 0xE7AE33), Color(hex: 0xD8951F)], startPoint: .top, endPoint: .bottom)
    }
    static func timerGradient() -> LinearGradient {
        LinearGradient(colors: [Color(hex: 0xE76A45), Color(hex: 0xD64E2E)], startPoint: .top, endPoint: .bottom)
    }
    static func musicGradient() -> LinearGradient {
        LinearGradient(colors: [Color(hex: 0x57A968), Color(hex: 0x458C54)], startPoint: .top, endPoint: .bottom)
    }

    // MARK: Type
    /// Letter-spaced monospaced caps label ("GOOD MORNING", "QUICK ADD"…).
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Thin grotesk display numerals (the big time / temperature).
    static func display(_ size: CGFloat, _ weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight)
    }
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // MARK: Metrics
    static let corner: CGFloat = 28
    static let cornerSmall: CGFloat = 18
    static let gap: CGFloat = 16

    /// Time-of-day greeting ("Good Morning" / "Good Afternoon" / "Good Evening").
    static func greeting(at date: Date) -> String {
        let h = Calendar.current.component(.hour, from: date)
        return h < 12 ? "Good Morning" : (h < 18 ? "Good Afternoon" : "Good Evening")
    }

    // MARK: Color helpers
    static func dyn(_ light: UInt, _ dark: UInt) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
    static func dynA(_ light: UInt, _ la: CGFloat, _ dark: UInt, _ da: CGFloat) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(hex: dark).withAlphaComponent(da)
            : UIColor(hex: light).withAlphaComponent(la) })
    }
}

extension Color {
    init(hex: UInt) { self = Color(uiColor: UIColor(hex: hex)) }
}

// MARK: - Atmosphere: grain texture + layered background

/// A tiny tileable monochrome-noise image, generated once. Tiling it at low
/// opacity gives surfaces a fine film-grain — tactile depth and, usefully, it
/// breaks up gradient banding on the OLED panel.
enum KHTexture {
    static let grain: UIImage = make(160)
    private static func make(_ size: Int) -> UIImage {
        // Let CoreGraphics own the pixel buffer. Passing `&array` here instead
        // would hand the context a pointer that's only valid for the duration of
        // this initializer call — it dangles by the time makeImage() reads it,
        // which segfaults on-device (the simulator just happens to survive it).
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return UIImage() }
        let row = ctx.bytesPerRow
        let px = data.bindMemory(to: UInt8.self, capacity: row * size)
        for y in 0..<size {
            for x in 0..<size {
                let o = y * row + x * 4
                let v = UInt8.random(in: 0...255)
                px[o] = v; px[o+1] = v; px[o+2] = v; px[o+3] = 255
            }
        }
        guard let img = ctx.makeImage() else { return UIImage() }
        return UIImage(cgImage: img)
    }
}

/// The app's backdrop: near-black (or warm paper in light) lifted out of dead-flat
/// by two soft corner glows and a whisper of grain. Fully static — composited once,
/// no per-frame cost on the A10.
struct KHBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            KH.bg
            if scheme == .dark {
                RadialGradient(colors: [Color(hex: 0x222633).opacity(0.85), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 820)
                    .blendMode(.plusLighter)
                RadialGradient(colors: [Color(hex: 0x231A12).opacity(0.7), .clear],
                               center: .bottomTrailing, startRadius: 0, endRadius: 760)
                    .blendMode(.plusLighter)
            }
            Image(uiImage: KHTexture.grain)
                .resizable(resizingMode: .tile)
                .opacity(scheme == .dark ? 0.05 : 0.035)
                .blendMode(scheme == .dark ? .plusLighter : .multiply)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Staggered entrance

/// A one-shot rise-and-fade used to orchestrate dashboard cards assembling on
/// appear (and re-assembling on layout switch). `index` staggers the start.
private struct EntranceModifier: ViewModifier {
    let index: Int
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.975, anchor: .bottom)
            .offset(y: shown ? 0 : 22)
            .onAppear {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.86)
                    .delay(Double(index) * 0.06)) { shown = true }
            }
    }
}
extension View {
    /// Stagger this element into view; `index` orders the cascade.
    func entrance(_ index: Int) -> some View { modifier(EntranceModifier(index: index)) }
}

extension UIColor {
    convenience init(hex: UInt) {
        self.init(red:   CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue:  CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Shared view helpers (used across screens)

extension View {
    /// Fit one line without wrapping.
    func khFit() -> some View { lineLimit(1).minimumScaleFactor(0.2) }

    /// Neutral liquid-glass surface: material + a soft top specular sheen, a rim
    /// highlight, and depth. Used by clock/recipe cards, sheets, the top bar.
    func khCard(corner: CGFloat = KH.corner) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return background(KH.card.opacity(0.5), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .clipShape(shape)
            .overlay(
                shape.fill(LinearGradient(colors: [.white.opacity(0.18), .clear],
                                          startPoint: .top, endPoint: .center))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.28), KH.hairline],
                                   startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 10)
    }

    /// Vibrant "coloured glass" surface for accent cards (weather/timer/music):
    /// the gradient + a diagonal specular sheen + rim light + depth.
    func accentGlass(_ gradient: LinearGradient, art: URL? = nil, tintOpacity: Double = 0.80,
                     corner: CGFloat = KH.corner) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return background {
            ZStack {
                if let art {
                    AsyncImage(url: art) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                        .blur(radius: 22)   // lighter than before (A10-friendly)
                }
                gradient.opacity(art != nil ? tintOpacity : 1)
            }
        }
            .clipShape(shape)
            .overlay(
                shape.fill(LinearGradient(colors: [.white.opacity(0.30), .clear, .black.opacity(0.12)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                    .allowsHitTesting(false)
            )
            .overlay(shape.strokeBorder(.white.opacity(0.20), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
    }
}

/// Letter-spaced monospaced caps label, e.g. `MonoLabel("QUICK ADD")`.
struct MonoLabel: View {
    let text: String
    var size: CGFloat = 12
    var color: Color = KH.textFaint
    init(_ text: String, size: CGFloat = 12, color: Color = KH.textFaint) {
        self.text = text; self.size = size; self.color = color
    }
    var body: some View {
        Text(text.uppercased())
            .font(KH.mono(size, .medium))
            .tracking(2)
            .foregroundStyle(color)
    }
}

/// Standard detail-screen header: ← back, title, optional trailing meta.
struct ScreenHeader: View {
    let title: String
    var trailing: String? = nil
    var trailingColor: Color = KH.textFaint
    let onBack: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Button(action: onBack) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(KH.textPrimary)
                    .frame(width: 48, height: 48)
                    .background(KH.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            Text(title)
                .font(KH.text(30, .bold))
                .foregroundStyle(KH.textPrimary)
                .padding(.leading, 6)
            Spacer()
            if let trailing { MonoLabel(trailing, size: 13, color: trailingColor) }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }
}

/// A simple capsule progress track: a faint background with a filled portion.
/// Shared by the timer tiles and the music card. (The Music *screen* keeps its
/// own richer draggable scrubber.) The caller applies any value animation.
struct TrackBar: View {
    var fraction: CGFloat
    var track: Color = KH.fill
    var fill: AnyShapeStyle
    var height: CGFloat = 6

    init(fraction: CGFloat, track: Color = KH.fill,
         fill: some ShapeStyle, height: CGFloat = 6) {
        self.fraction = fraction
        self.track = track
        self.fill = AnyShapeStyle(fill)
        self.height = height
    }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: max(0, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

