import SwiftUI
import Foundation

/// Full-screen weather detail (amber accent). Reads published values from
/// `WeatherModel`; the root is responsible for calling `weather.start()`.
/// Layout: a fixed `ScreenHeader` over a vertical scroll of three sections —
/// a gradient HERO card, an HOURLY glass card, and a 7-DAY glass card.
struct WeatherScreen: View {
    @EnvironmentObject var weather: WeatherModel
    @EnvironmentObject var app: KHModel

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: weather.place,
                         trailing: trailingText,
                         trailingColor: KH.amber) {
                app.backToDashboard()
            }
            content
        }
        .background(KHBackground())
    }

    // MARK: - Top-level state

    @ViewBuilder private var content: some View {
        if weather.denied {
            stateView("Location off — enable location for weather",
                      systemImage: "location.slash")
        } else if weather.temp == nil {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading weather…")
                    .font(KH.text(17))
                    .foregroundStyle(KH.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: KH.gap) {
                    hero
                    hourly
                    sevenDay
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 28)
            }
        }
    }

    private func stateView(_ message: String, systemImage: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(KH.textFaint)
            Text(message)
                .font(KH.text(18))
                .foregroundStyle(KH.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - HERO

    private var hero: some View {
        HStack(alignment: .top, spacing: KH.gap) {
            VStack(alignment: .leading, spacing: 2) {
                if let temp = weather.temp {
                    Text("\(Int(temp.rounded()))°")
                        .font(KH.display(120))
                        .tracking(-4)
                        .foregroundStyle(KH.onAmber)
                        .khFit()
                    Text(weather.condition)
                        .font(KH.text(26, .semibold))
                        .foregroundStyle(KH.onAmber)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(KH.onAmber)
                        .padding(.vertical, 40)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 18) {
                heroStat("FEELS", "\(Int(weather.apparent.rounded()))°")
                heroStat("HUMIDITY", "\(weather.humidity)%")
                heroStat("WIND", "\(Int(weather.wind.rounded()))mph")
            }
            .padding(.top, 8)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topTrailing) {
                KH.weatherGradient()
                // Current-condition watermark, partially clipped by the card corner.
                Image(systemName: weather.symbol)
                    .font(.system(size: 210, weight: .thin))
                    .foregroundStyle(.white.opacity(0.22))
                    .offset(x: 56, y: -36)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: KH.corner, style: .continuous))
        .shadow(color: KH.amber.opacity(0.28), radius: 18, x: 0, y: 10)
    }

    private func heroStat(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            MonoLabel(caption, size: 11, color: Color.black.opacity(0.45))
            Text(value)
                .font(KH.text(22, .semibold))
                .foregroundStyle(KH.onAmber)
        }
    }

    // MARK: - HOURLY

    private var hourly: some View {
        VStack(alignment: .leading, spacing: KH.gap) {
            MonoLabel("HOURLY")
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(weather.hours) { h in
                    hourColumn(h)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(20)
        .khCard()
        .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 6)
    }

    private func hourColumn(_ h: WeatherHour) -> some View {
        let (minT, maxT) = hourRange
        return VStack(spacing: 10) {
            Text("\(Int(h.temp.rounded()))°")
                .font(KH.text(16, .bold))
                .foregroundStyle(KH.textPrimary)
                .khFit()
            Capsule()
                .fill(KH.amber)
                .frame(width: 8, height: barHeight(for: h.temp, min: minT, max: maxT))
                .frame(height: 80, alignment: .bottom)
            Text(h.label)
                .font(KH.mono(11, .medium))
                .foregroundStyle(KH.textFaint)
                .khFit()
        }
    }

    private var hourRange: (Double, Double) {
        let temps = weather.hours.map(\.temp)
        return (temps.min() ?? 0, temps.max() ?? 1)
    }

    private func barHeight(for temp: Double, min lo: Double, max hi: Double) -> CGFloat {
        let minH: CGFloat = 16, maxH: CGFloat = 80
        guard hi > lo else { return (minH + maxH) / 2 }
        let t = (temp - lo) / (hi - lo)
        return minH + CGFloat(t) * (maxH - minH)
    }

    // MARK: - 7-DAY

    private var sevenDay: some View {
        VStack(alignment: .leading, spacing: KH.gap) {
            MonoLabel("7-DAY")
            VStack(spacing: 14) {
                ForEach(weather.days) { d in
                    dayRow(d)
                }
            }
        }
        .padding(20)
        .khCard()
        .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 6)
    }

    private func dayRow(_ d: WeatherDay) -> some View {
        let (wMin, wMax) = weekRange
        return HStack(spacing: 12) {
            Text(d.name)
                .font(KH.text(16, .semibold))
                .foregroundStyle(KH.textPrimary)
                .frame(width: 96, alignment: .leading)
                .khFit()
            Circle()
                .fill(dotColor(d.code))
                .frame(width: 10, height: 10)
            Text("\(Int(d.lo.rounded()))°")
                .font(KH.text(15))
                .foregroundStyle(KH.textFaint)
                .frame(width: 42, alignment: .trailing)
            rangeBar(lo: d.lo, hi: d.hi, min: wMin, max: wMax)
                .frame(height: 8)
                .frame(maxWidth: .infinity)
            Text("\(Int(d.hi.rounded()))°")
                .font(KH.text(15, .semibold))
                .foregroundStyle(KH.textPrimary)
                .frame(width: 42, alignment: .leading)
        }
    }

    /// Track + gradient fill sized/positioned to map d.lo…d.hi across the
    /// week's overall min…max.
    private func rangeBar(lo: Double, hi: Double, min wMin: Double, max wMax: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = Swift.max(wMax - wMin, 1)
            let x = CGFloat((lo - wMin) / span) * w
            let width = Swift.max(CGFloat((hi - lo) / span) * w, 14)
            ZStack(alignment: .leading) {
                Capsule().fill(KH.fill)
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: 0x5B8DEF), KH.amber],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: Swift.min(width, w))
                    .offset(x: Swift.min(x, Swift.max(0, w - width)))
            }
        }
    }

    private var weekRange: (Double, Double) {
        let los = weather.days.map(\.lo)
        let his = weather.days.map(\.hi)
        return (los.min() ?? 0, his.max() ?? 1)
    }

    /// Condition dot colour from a few WMO code ranges.
    private func dotColor(_ code: Int) -> Color {
        switch code {
        case 0, 1:                       return KH.amber                 // clear / sunny
        case 2, 3, 45, 48:               return .gray                    // cloud / fog
        case 51...67, 80...82, 95...99:  return Color(hex: 0x5B8DEF)     // rain / storm
        case 71...77, 85, 86:            return Color(hex: 0xCBD5E1)     // snow (light)
        default:                         return .gray
        }
    }

    // MARK: - Header meta

    private var trailingText: String? {
        guard let updated = weather.updated else { return nil }
        return "UPDATED \(Self.timeFmt.string(from: updated))"
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f
    }()
}
