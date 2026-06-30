import SwiftUI

/// Lock / standby screen: huge time over an ambient album-art glow, with a
/// centered now-playing bar, weather, and a running-timer pill.
/// Tap anywhere to unlock into the dashboard.
struct LockView: View {
    @EnvironmentObject var app: KHModel
    @EnvironmentObject var weather: WeatherModel
    @EnvironmentObject var timers: TimersModel
    @EnvironmentObject var sonos: SonosController

    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                MonoLabel("\(greeting) · \(weather.place)", size: 13, color: KH.textSecondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 14) {
                    weatherChip
                    timerPill
                }
            }

            Spacer()

            Text(now, format: .dateTime.hour().minute())
                .font(KH.display(200, .thin)).monospacedDigit().tracking(-5)
                .foregroundStyle(KH.textPrimary).khFit()
            Text(now, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(KH.text(28)).foregroundStyle(KH.textSecondary)

            Spacer()

            VStack(spacing: 16) {
                nowPlaying
                MonoLabel("Tap to unlock ↑", size: 13, color: KH.textFaint)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AmbientArtBackground(url: sonos.now?.artURL).equatable().ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { app.unlock() }
        .onReceive(tick) { now = $0 }
    }

    private var greeting: String { KH.greeting(at: now) }

    private var weatherChip: some View {
        HStack(spacing: 10) {
            Image(systemName: weather.symbol).symbolRenderingMode(.multicolor)
                .font(.system(size: 22))
            Text(weather.temp.map { "\(Int($0.rounded()))°" } ?? "—")
                .font(KH.text(26)).foregroundStyle(KH.textPrimary)
        }
    }

    // MARK: Centered now-playing bar

    @ViewBuilder private var nowPlaying: some View {
        if let track = sonos.now {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KH.green.opacity(0.5))
                    .frame(width: 54, height: 54)
                    .overlay {
                        if let u = track.artURL {
                            AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { EmptyView() }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(KH.text(17, .bold)).foregroundStyle(KH.textPrimary).lineLimit(1)
                    if !track.artist.isEmpty {
                        Text(track.artist).font(KH.text(14)).foregroundStyle(KH.textSecondary).lineLimit(1)
                    }
                    MonoLabel("▶ \(sonos.selectedRoom?.name ?? "Sonos")", size: 11, color: KH.green)
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1))
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder private var timerPill: some View {
        if let t = timers.items.first(where: { $0.running }) {
            VStack(spacing: 2) {
                MonoLabel(t.name, size: 11, color: KH.onAccentDim)
                Text(TimersModel.clock(t.remaining)).font(KH.text(22, .bold)).monospacedDigit()
                    .foregroundStyle(KH.onAccent)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(KH.timerGradient(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// Full-bleed, heavily-blurred album art used as the lock screen's ambient
/// backdrop. Isolated into an `Equatable` subview keyed on `url` and rasterized
/// with `drawingGroup()`, so the expensive blur runs only when the artwork
/// changes — not on every 1 Hz clock tick that re-renders `LockView`.
private struct AmbientArtBackground: View, Equatable {
    let url: URL?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear     // let the app's KHBackground atmosphere show through
                if let url {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 110)          // blur the overflow, then clip → no faded edges
                        .opacity(0.6)
                        .clipped()
                    // Keep the white time legible over bright artwork.
                    LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.20), .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .drawingGroup()
        }
    }
}
