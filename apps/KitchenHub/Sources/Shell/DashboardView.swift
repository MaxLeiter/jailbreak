import SwiftUI

/// The unlocked dashboard: a top control bar + the active layout of the 5 cards.
struct DashboardView: View {
    @EnvironmentObject var app: KHModel
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: KH.gap) {
            topBar
            Group {
                switch app.layout {
                case .grid:   GridLayout()
                case .hero:   HeroLayout()
                case .mosaic: MosaicLayout()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(KH.gap)
        .onReceive(tick) { now = $0 }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Text(now, format: .dateTime.hour().minute())
                    .font(KH.text(22, .bold)).monospacedDigit().foregroundStyle(KH.textPrimary)
                Text(now, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(KH.text(15)).foregroundStyle(KH.textSecondary)
            }
            Spacer()
            segmented
            iconButton("appletv") { app.open(.appletv) }
            iconButton(app.isDark ? "moon.fill" : "sun.max.fill") { app.toggleTheme() }
            Button { app.lock() } label: {
                MonoLabel("Lock", size: 12, color: KH.textSecondary)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(KH.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
    }

    private var segmented: some View {
        HStack(spacing: 4) {
            ForEach(KHModel.Layout.allCases) { l in
                Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { app.layout = l } } label: {
                    Text(l.rawValue)
                        .font(KH.text(15, .medium))
                        .foregroundStyle(app.layout == l ? KH.textPrimary : KH.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background {
                            if app.layout == l {
                                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(KH.card)
                                    .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(KH.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func iconButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(KH.textPrimary)
                .frame(width: 44, height: 44)
                .background(KH.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Layouts

struct GridLayout: View {
    var body: some View {
        GeometryReader { g in
            let gap = KH.gap
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    ClockCard().frame(width: (g.size.width - 2 * gap) * 0.40).entrance(0)
                    WeatherCard().entrance(1)
                    TimerCard().entrance(2)
                }
                .frame(height: (g.size.height - gap) * 0.46)
                HStack(spacing: gap) {
                    MusicCard().entrance(3)
                    RecipeCard().entrance(4)
                }
            }
        }
    }
}

struct HeroLayout: View {
    var body: some View {
        GeometryReader { g in
            let gap = KH.gap
            HStack(spacing: gap) {
                ClockCard().frame(width: (g.size.width - gap) * 0.46).entrance(0)
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        WeatherCard().entrance(1)
                        TimerCard().entrance(2)
                    }
                    MusicCard().entrance(3)
                    RecipeCard().entrance(4)
                }
            }
        }
    }
}

struct MosaicLayout: View {
    var body: some View {
        GeometryReader { g in
            let gap = KH.gap
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    MusicCard().frame(width: (g.size.width - gap) * 0.42).entrance(0)
                    VStack(spacing: gap) {
                        WeatherCard().frame(height: (g.size.height * 0.66 - gap) * 0.5).entrance(1)
                        HStack(spacing: gap) {
                            TimerCard().entrance(2)
                            RecipeCard().entrance(3)
                        }
                    }
                }
                .frame(height: g.size.height * 0.66)
                ClockCard().entrance(4)
            }
        }
    }
}
