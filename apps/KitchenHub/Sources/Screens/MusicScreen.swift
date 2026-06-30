import SwiftUI

/// Full-screen Music detail (Spotify · Sonos). Green-accented two-column layout:
/// big album art + transport on the left, glass control cards (rooms, volume,
/// up-next) on the right. Drives a `SonosController`; light/dark via KH tokens.
struct MusicScreen: View {
    @EnvironmentObject var sonos: SonosController
    @EnvironmentObject var app: KHModel

    /// Local mirror of `sonos.volume` so the Slider stays smooth while dragging.
    @State private var vol: Double = 0
    @State private var editingVol = false

    /// Local mirror of `sonos.position` (seconds) so the scrubber stays smooth
    /// while dragging; synced from `sonos.position` only when not scrubbing.
    @State private var scrub: Double = 0
    @State private var scrubbing = false
    @State private var showBrowse = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Music", trailing: "SPOTIFY · SONOS", trailingColor: KH.green) {
                app.backToDashboard()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            ZStack {
                KH.bg
                if let u = sonos.now?.artURL {
                    AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                        .blur(radius: 90)
                        .opacity(0.38)
                }
            }
            .ignoresSafeArea()
        }
        .onAppear {
            if sonos.rooms.isEmpty { sonos.start(manualIP: "") }
            vol = Double(sonos.volume)
            scrub = sonos.position
            if sonos.status == .connected { Task { await sonos.loadQueue() } }
        }
        .onChange(of: sonos.volume) { newValue in
            // Don't fight the user's drag; sync only when idle.
            if !editingVol { vol = Double(newValue) }
        }
        .onChange(of: sonos.position) { newValue in
            // Don't fight the user's drag; sync only when idle.
            if !scrubbing { scrub = newValue }
        }
        .sheet(isPresented: $showBrowse) { SonosBrowseSheet(sonos: sonos) }
    }

    // MARK: - Status routing

    @ViewBuilder private var content: some View {
        switch sonos.status {
        case .connected:
            player
        case .searching:
            stateView(icon: nil, text: "Searching for Sonos…", showProgress: true)
        case .noSpeaker:
            stateView(icon: "hifispeaker.2", text: "No Sonos found", showProgress: false)
        case .error:
            stateView(icon: "wifi.exclamationmark", text: "Can't reach Sonos", showProgress: false)
        }
    }

    private func stateView(icon: String?, text: String, showProgress: Bool) -> some View {
        VStack(spacing: 18) {
            if showProgress {
                ProgressView()
                    .controlSize(.large)
                    .tint(KH.green)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(KH.textFaint)
            }
            Text(text)
                .font(KH.text(18, .medium))
                .foregroundStyle(KH.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Connected player

    private var player: some View {
        GeometryReader { geo in
            let inset: CGFloat = 22
            let avail = geo.size.width - inset * 2 - KH.gap
            let leftW = max(0, avail * 0.46)
            let artSize = min(leftW, geo.size.height * 0.56)

            HStack(alignment: .top, spacing: KH.gap) {
                leftColumn(artSize: artSize)
                    .frame(width: leftW, alignment: .leading)
                rightColumn
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .padding(.horizontal, inset)
            .padding(.bottom, inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: Left column — art, track, progress, transport

    private func leftColumn(artSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            albumArt(size: artSize)

            VStack(alignment: .leading, spacing: 6) {
                Text(sonos.now?.title ?? "Not playing")
                    .font(KH.display(34, .bold))
                    .foregroundStyle(KH.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if let now = sonos.now {
                    HStack(spacing: 8) {
                        if !now.artist.isEmpty {
                            Text(now.artist).foregroundStyle(KH.textSecondary)
                        }
                        if !now.album.isEmpty {
                            Text(now.album).foregroundStyle(KH.textFaint)
                        }
                    }
                    .font(KH.text(18))
                    .lineLimit(1)
                }
            }

            progressBar

            transportRow

            Spacer(minLength: 0)
        }
    }

    private func albumArt(size: CGFloat) -> some View {
        AsyncImage(url: sonos.now?.artURL) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                artPlaceholder(size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 26, x: 0, y: 16)
    }

    private func artPlaceholder(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(KH.green.opacity(0.16))
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.26, weight: .light))
                    .foregroundStyle(KH.green.opacity(0.75))
            )
    }

    /// Live scrubber bound to `sonos.position` / `sonos.duration`. Draggable when
    /// a real duration is known (queued tracks); streams (duration 0) show a flat
    /// non-interactive bar and 0:00 times.
    private var progressBar: some View {
        let dur = sonos.duration
        let seekable = dur > 0
        let value = min(max(scrub, 0), seekable ? dur : 0)
        let fraction = seekable ? value / dur : 0

        return VStack(spacing: 8) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(KH.fill)
                    Capsule().fill(KH.green).frame(width: max(0, w * fraction))
                    Circle()
                        .fill(KH.green)
                        .frame(width: 14, height: 14)
                        .shadow(color: KH.green.opacity(0.5), radius: 4, x: 0, y: 1)
                        .offset(x: max(0, min(w - 14, w * fraction - 7)))
                        .opacity(seekable ? 1 : 0)
                }
                .frame(height: 14)
                .contentShape(Rectangle())
                .animation(scrubbing ? nil : .linear(duration: 0.25), value: fraction)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g2 in
                            guard seekable, w > 0 else { return }
                            scrubbing = true
                            scrub = Double(min(max(0, g2.location.x / w), 1)) * dur
                        }
                        .onEnded { _ in
                            guard seekable else { return }
                            sonos.seek(to: scrub)
                            scrubbing = false
                        }
                )
            }
            .frame(height: 14)

            HStack {
                Text(timeLabel(seekable ? value : 0))
                Spacer()
                Text(timeLabel(seekable ? dur : 0))
            }
            .font(KH.mono(12, .medium))
            .monospacedDigit()
            .foregroundStyle(KH.textFaint)
        }
    }

    /// Seconds → "M:SS" (or "H:MM:SS" past an hour).
    private func timeLabel(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    private var transportRow: some View {
        HStack(spacing: 28) {
            roundButton("backward.fill", size: 24, diameter: 56) { sonos.previous() }

            Button { sonos.toggle() } label: {
                Image(systemName: sonos.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(KH.onAccent)
                    .frame(width: 78, height: 78)
                    .background(KH.musicGradient(), in: Circle())
                    .shadow(color: KH.green.opacity(0.45), radius: 18, x: 0, y: 8)
            }
            .buttonStyle(.plain)

            roundButton("forward.fill", size: 24, diameter: 56) { sonos.next() }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func roundButton(_ symbol: String, size: CGFloat, diameter: CGFloat,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(KH.textPrimary)
                .frame(width: diameter, height: diameter)
                .background(KH.fill, in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Right column — control cards

    private var rightColumn: some View {
        VStack(spacing: KH.gap) {
            browseButton
            roomsCard
            volumeCard
            upNextCard
            Spacer(minLength: 0)
        }
    }

    /// Prominent entry to pick something to play (Sonos favourites + search).
    private var browseButton: some View {
        Button { showBrowse = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "music.note.list").font(.system(size: 18, weight: .semibold))
                Text("Browse music").font(KH.text(17, .semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(KH.onAccentDim)
            }
            .foregroundStyle(KH.onAccent)
            .padding(.horizontal, 18).frame(height: 56).frame(maxWidth: .infinity)
            .background(KH.musicGradient(), in: RoundedRectangle(cornerRadius: KH.cornerSmall, style: .continuous))
            .shadow(color: KH.green.opacity(0.35), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
    }

    // MARK: Rooms

    private var roomsSummary: String { sonos.groupedRoomName ?? "" }

    private var roomsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                MonoLabel("ROOMS")
                Spacer()
                if !roomsSummary.isEmpty {
                    Text(roomsSummary)
                        .font(KH.mono(12, .medium))
                        .tracking(1)
                        .foregroundStyle(KH.green)
                        .lineLimit(1)
                }
            }
            Text("Tap a room to control it · + to play in sync")
                .font(KH.text(12)).foregroundStyle(KH.textFaint)
            VStack(spacing: 8) {
                ForEach(sonos.rooms) { room in
                    roomRow(room)
                }
            }
        }
        .padding(18)
        .khCard()
    }

    private func roomRow(_ room: SonosRoom) -> some View {
        let sel = sonos.selectedUUID ?? ""
        let inGroup = sonos.coordinator(of: room.uuid) == sonos.coordinator(of: sel)
        let isSelected = room.uuid == sonos.selectedUUID
        let playing = inGroup && sonos.isPlaying

        return HStack(spacing: 12) {
            Image(systemName: playing ? "speaker.wave.2.fill" : "speaker.fill")
                .font(.system(size: 13))
                .foregroundStyle(playing ? KH.green : KH.textFaint)
                .opacity(playing ? 1 : (inGroup ? 0.6 : 0.3))
                .frame(width: 18)

            Text(room.name)
                .font(KH.text(17, isSelected ? .semibold : .regular))
                .foregroundStyle(KH.textPrimary)
                .lineLimit(1)

            if isSelected {
                Text("CONTROLLING")
                    .font(KH.mono(9, .bold)).tracking(1)
                    .foregroundStyle(KH.green)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(KH.green.opacity(0.15), in: Capsule())
            }

            Spacer(minLength: 8)

            // The controlling room is the group's base; others get a + / ✓ to join it.
            if !isSelected {
                Button {
                    sonos.setGrouped(room.uuid, !inGroup)
                } label: {
                    Image(systemName: inGroup ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(inGroup ? KH.green : KH.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: KH.cornerSmall, style: .continuous)
                .fill(isSelected ? KH.green.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                sonos.select(room.uuid)
            }
        }
    }

    // MARK: Volume

    private var volumeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            MonoLabel("VOLUME · \(sonos.selectedRoom?.name ?? "—")")
            HStack(spacing: 14) {
                stepButton("minus") { adjustVolume(-5) }

                Slider(value: $vol, in: 0...100) { editing in
                    editingVol = editing
                    if !editing { sonos.setVolume(Int(vol)) }
                }
                .tint(KH.green)

                stepButton("plus") { adjustVolume(5) }

                Text("\(Int(vol))")
                    .font(KH.text(17, .semibold))
                    .foregroundStyle(KH.textPrimary)
                    .monospacedDigit()
                    .frame(minWidth: 34, alignment: .trailing)
            }
        }
        .padding(18)
        .khCard()
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(KH.textPrimary)
                .frame(width: 38, height: 38)
                .background(KH.fill, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func adjustVolume(_ delta: Int) {
        let v = max(0, min(100, Int(vol) + delta))
        vol = Double(v)
        sonos.setVolume(v)
    }

    // MARK: Up next — live Sonos queue (Q:0), current track highlighted

    private var upNextCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                MonoLabel("UP NEXT")
                Spacer()
                if !sonos.queue.isEmpty {
                    Text("Tap to play")
                        .font(KH.text(12)).foregroundStyle(KH.textFaint)
                }
            }
            if sonos.queue.isEmpty {
                Text("Nothing queued")
                    .font(KH.text(16))
                    .foregroundStyle(KH.textFaint)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(Array(sonos.queue.enumerated()), id: \.offset) { idx, item in
                            queueRow(item, index: idx, isCurrent: idx == sonos.trackNo - 1)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
        .padding(18)
        .khCard()
    }

    private func queueRow(_ item: SonosItem, index: Int, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                AsyncImage(url: item.artURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(KH.green.opacity(0.16))
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 14, weight: .light))
                                    .foregroundStyle(KH.green.opacity(0.75))
                            )
                    }
                }
                // Play affordance on the artwork for tracks you can jump to.
                if !isCurrent {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.black.opacity(0.32))
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        )
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(KH.text(15, isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? KH.green : KH.textPrimary)
                    .lineLimit(1)
                if !item.artist.isEmpty {
                    Text(item.artist)
                        .font(KH.text(13))
                        .foregroundStyle(isCurrent ? KH.green.opacity(0.8) : KH.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            if isCurrent {
                Image(systemName: sonos.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KH.green)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { sonos.playFromQueue(index + 1) }
    }
}

// MARK: - Helpers

/// Optionally attaches a long-press that toggles a room's grouping. Used so the
/// modifier is only active for rows that aren't the currently selected room.
private struct GroupLongPress: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onLongPressGesture(minimumDuration: 0.4, perform: action)
        } else {
            content
        }
    }
}

/// Browse Sonos favourites (stations, playlists, albums — incl. saved Spotify
/// content) with search, and tap to play on the selected room.
struct SonosBrowseSheet: View {
    @ObservedObject var sonos: SonosController
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [SonosItem] {
        search.isEmpty ? sonos.favorites
            : sonos.favorites.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }
    private let cols = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    var body: some View {
        NavigationStack {
            Group {
                if sonos.browseLoading && sonos.favorites.isEmpty {
                    ProgressView().tint(KH.green)
                } else if sonos.favorites.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note.list").font(.system(size: 40, weight: .light))
                            .foregroundStyle(KH.textFaint)
                        Text("No Sonos favourites").font(KH.text(18, .semibold)).foregroundStyle(KH.textPrimary)
                        Text("Save favourites in the Sonos app to play them here.")
                            .font(KH.text(14)).foregroundStyle(KH.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(40)
                } else {
                    ScrollView {
                        LazyVGrid(columns: cols, spacing: 16) {
                            ForEach(filtered) { item in
                                Button { sonos.play(item); dismiss() } label: { tile(item) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Play to \(sonos.selectedRoom?.name ?? "Sonos")")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .task { await sonos.loadFavorites() }
    }

    private func tile(_ item: SonosItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(KH.green.opacity(0.12))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let url = item.artURL {
                        AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { note }
                    } else { note }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(item.title).font(KH.text(14, .medium)).foregroundStyle(KH.textPrimary).lineLimit(2)
        }
    }
    private var note: some View {
        Image(systemName: "music.note").font(.system(size: 26)).foregroundStyle(KH.green.opacity(0.7))
    }
}
