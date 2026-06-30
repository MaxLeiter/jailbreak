import SwiftUI

/// The five dashboard summary cards. Each reads its model and (except the clock)
/// taps through to its detail screen via KHModel.route.

// MARK: Clock (neutral glass; no detail)

struct ClockCard: View {
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoLabel(greeting)
            Spacer(minLength: 0)
            Text(now, format: .dateTime.hour().minute())
                .font(KH.display(96, .light)).monospacedDigit().tracking(-2)
                .foregroundStyle(KH.textPrimary).khFit()
            Text(now, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(KH.text(20)).foregroundStyle(KH.textSecondary).khFit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(26)
        .background {
            ZStack {
                timeTint
                BubbleField(tint: tintColor)
            }
        }
        .khCard()
        .onReceive(tick) { now = $0 }
    }

    private var greeting: String { KH.greeting(at: now) }

    /// A soft time-of-day glow over the neutral glass.
    private var timeTint: LinearGradient {
        LinearGradient(colors: [tintColor.opacity(0.30), .clear],
                       startPoint: .topTrailing, endPoint: .bottomLeading)
    }
    private var tintColor: Color {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<9:   return Color(hex: 0xE8A06A)   // dawn
        case 9..<17:  return Color(hex: 0x5B8DEF)   // midday
        case 17..<21: return Color(hex: 0xE2772B)   // sunset
        default:      return Color(hex: 0x3A4A8A)   // night
        }
    }
}

// MARK: Weather (amber)

struct WeatherCard: View {
    @EnvironmentObject var weather: WeatherModel
    @EnvironmentObject var app: KHModel

    var body: some View {
        Button { app.open(.weather) } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: WMO.symbol(weather.code))
                    .font(.system(size: 150, weight: .thin))
                    .foregroundStyle(.white.opacity(0.18))
                    .offset(x: 28, y: -8)
                VStack(alignment: .leading, spacing: 0) {
                    MonoLabel(weather.condition.uppercased(), color: KH.onAmber.opacity(0.7))
                    Spacer(minLength: 0)
                    Text(weather.temp.map { "\(Int($0.rounded()))°" } ?? "—")
                        .font(KH.display(80, .light)).tracking(-2).foregroundStyle(KH.onAmber).khFit()
                    Text("H \(Int(weather.hi))°  ·  L \(Int(weather.lo))°")
                        .font(KH.text(15, .semibold)).foregroundStyle(KH.onAmber.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            }
            .accentGlass(KH.weatherGradient())
        }
        .buttonStyle(CardPress())
    }
}

// MARK: Timer (orange)

struct TimerCard: View {
    @EnvironmentObject var timers: TimersModel
    @EnvironmentObject var app: KHModel

    var body: some View {
        Button { app.open(.timers) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(KH.onAccent).frame(width: 8, height: 8)
                    MonoLabel(timers.selected?.name ?? "Timers", color: KH.onAccentDim)
                }
                Spacer(minLength: 0)
                if let sel = timers.selected {
                    Text(TimersModel.clock(sel.remaining))
                        .font(KH.display(80, .light)).monospacedDigit().tracking(-2)
                        .foregroundStyle(KH.onAccent).khFit()
                    Text(timers.runningCount == 1 ? "1 timer running"
                         : timers.runningCount == 0 ? "Tap to start"
                         : "\(timers.runningCount) timers running")
                        .font(KH.text(15)).foregroundStyle(KH.onAccentDim)
                } else {
                    Text("No timers")
                        .font(KH.display(60, .light)).foregroundStyle(KH.onAccent).khFit()
                    Text("Tap to add one")
                        .font(KH.text(15)).foregroundStyle(KH.onAccentDim)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            .accentGlass(KH.timerGradient())
        }
        .buttonStyle(CardPress())
    }
}

// MARK: Music (green)

struct MusicCard: View {
    @EnvironmentObject var sonos: SonosController
    @EnvironmentObject var app: KHModel
    @State private var vol: Double = 0
    @State private var editingVol = false

    private var roomLabel: String { sonos.groupedRoomName ?? "Sonos" }

    var body: some View {
        GeometryReader { geo in
            // Taller-than-wide (e.g. the Mosaic left tile) → column + inline controls.
            let tall = geo.size.height > geo.size.width
            Group {
                if tall { tallCard } else { wideCard }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: tall ? .topLeading : .leading)
            .padding(tall ? 20 : 24)
            .accentGlass(KH.musicGradient(), art: sonos.now?.artURL, tintOpacity: 0.66)
        }
        .onAppear { vol = Double(sonos.volume) }
        .onChange(of: sonos.volume) { v in if !editingVol { vol = Double(v) } }
    }

    // Wide/short: a summary that taps through to the full Music screen.
    private var wideCard: some View {
        Button { app.open(.music) } label: {
            HStack(spacing: 18) {
                art(96)
                VStack(alignment: .leading, spacing: 6) {
                    info
                    progressBar.padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPress())
    }

    // Tall: art + info (tap to open), then live transport + volume.
    private var tallCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { app.open(.music) } label: {
                VStack(alignment: .leading, spacing: 14) {
                    art(120)
                    info
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            progressBar
            Spacer(minLength: 0)
            transportRow
            volumeRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            MonoLabel("Playing · \(roomLabel)", color: KH.onAccentDim)
            Text(sonos.now?.title ?? "Not playing")
                .font(KH.text(28, .bold)).foregroundStyle(KH.onAccent).khFit()
            Text(sonos.now?.artist ?? " ")
                .font(KH.text(16)).foregroundStyle(KH.onAccentDim).khFit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Inline controls (tall card)

    private var progressFraction: CGFloat {
        guard sonos.duration > 0 else { return 0 }
        return CGFloat(min(max(sonos.position / sonos.duration, 0), 1))
    }
    private var progressBar: some View {
        TrackBar(fraction: progressFraction, track: .white.opacity(0.25), fill: KH.onAccent, height: 4)
    }

    private var transportRow: some View {
        HStack {
            transportButton("backward.fill", size: 20) { sonos.previous() }
            Spacer()
            transportButton(sonos.isPlaying ? "pause.fill" : "play.fill", size: 30) { sonos.toggle() }
            Spacer()
            transportButton("forward.fill", size: 20) { sonos.next() }
        }
        .frame(maxWidth: .infinity)
    }
    private func transportButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(KH.onAccent)
                .frame(width: 54, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(KH.onAccentDim)
            Slider(value: $vol, in: 0...100) { editing in
                editingVol = editing
                if !editing { sonos.setVolume(Int(vol)) }
            }
            .tint(KH.onAccent)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)).foregroundStyle(KH.onAccentDim)
        }
    }

    private func art(_ size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(0.18))
            .frame(width: size, height: size)
            .overlay {
                if let u = sonos.now?.artURL {
                    AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { note }
                } else { note }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    private var note: some View {
        Image(systemName: "music.note").font(.system(size: 30)).foregroundStyle(KH.onAccentDim)
    }
}

// MARK: Recipe (neutral)

struct RecipeCard: View {
    @EnvironmentObject var recipe: RecipeModel
    @EnvironmentObject var app: KHModel

    var body: some View {
        Button { app.open(.recipe) } label: {
            HStack(spacing: 0) {
                ZStack {
                    KH.fill
                    Image(systemName: "fork.knife").font(.system(size: 34, weight: .light))
                        .foregroundStyle(KH.textFaint)
                }
                .frame(width: 190)
                .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    MonoLabel(recipe.current == nil ? "Recipes" : "Cooking Now")
                    Spacer(minLength: 0)
                    if let r = recipe.current {
                        Text(r.title)
                            .font(KH.text(28, .bold)).foregroundStyle(KH.textPrimary)
                            .lineLimit(2).minimumScaleFactor(0.6)
                        Text("Step \(recipe.stepIndex + 1) of \(r.steps.count) · \(r.minutes) min")
                            .font(KH.text(15)).foregroundStyle(KH.textSecondary)
                    } else {
                        Text("No recipes yet")
                            .font(KH.text(28, .bold)).foregroundStyle(KH.textPrimary)
                        Text("Tap to add one")
                            .font(KH.text(15)).foregroundStyle(KH.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .khCard()
        }
        .buttonStyle(CardPress())
    }
}

// MARK: Press style

struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Soft, slowly-drifting bokeh circles — an iOS 7/8 dynamic-wallpaper feel.
/// Canvas radial-gradient fills (no per-frame blur) keep it light on the A10.
struct BubbleField: View {
    var tint: Color
    // x, y (0…1), radius (fraction of width), opacity, speedX, speedY, phase
    private static let specs: [(CGFloat, CGFloat, CGFloat, Double, Double, Double, Double)] = [
        (0.22, 0.30, 0.55, 0.45, 0.13, 0.10, 0.0),
        (0.72, 0.22, 0.62, 0.38, 0.10, 0.14, 1.2),
        (0.50, 0.72, 0.70, 0.40, 0.08, 0.12, 2.4),
        (0.86, 0.66, 0.46, 0.35, 0.15, 0.09, 3.1),
        (0.12, 0.80, 0.52, 0.32, 0.11, 0.13, 4.0),
        (0.56, 0.46, 0.58, 0.28, 0.09, 0.11, 5.2),
    ]
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                for s in Self.specs {
                    let cx = (s.0 + 0.05 * CGFloat(sin(t * s.4 + s.6))) * size.width
                    let cy = (s.1 + 0.05 * CGFloat(cos(t * s.5 + s.6))) * size.height
                    let r = s.2 * size.width * 0.5
                    let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                    gc.fill(Path(ellipseIn: rect),
                            with: .radialGradient(Gradient(colors: [tint.opacity(s.3), tint.opacity(0)]),
                                                  center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r))
                }
            }
            .blendMode(.plusLighter)
        }
    }
}
