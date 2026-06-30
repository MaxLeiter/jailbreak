import SwiftUI

/// Apple TV remote: a glass trackpad (swipe to move focus, tap to select) plus
/// menu / home / play-pause and a volume rocker. Talks to the TV over the
/// Companion protocol via `AppleTVController`.
struct AppleTVScreen: View {
    @EnvironmentObject var app: KHModel
    @EnvironmentObject var atv: AppleTVController

    // Trackpad gesture state
    @State private var dragStart: CGPoint?
    @State private var lastSent: CGPoint?
    @State private var touchPoint: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: atv.deviceName, trailing: statusText, trailingColor: statusColor) {
                app.backToDashboard()
            }

            if atv.isConfigured {
                Spacer(minLength: 0)
                trackpad
                    .padding(.horizontal, 24)
                    .padding(.bottom, 26)
                buttonRow
                    .padding(.bottom, 16)
                volumeRocker
                Spacer(minLength: 0)
            } else {
                notConfigured
            }
        }
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .background(KHBackground())
        .task { await atv.connect() }
    }

    // MARK: Trackpad

    private var trackpad: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(KH.card)
                    .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(KH.hairline, lineWidth: 1))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(KH.hairline, lineWidth: 1).padding(22))
                    .shadow(color: .black.opacity(0.32), radius: 24, x: 0, y: 14)

                // Hint (fades out while touching)
                VStack(spacing: 10) {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(KH.textFaint)
                    MonoLabel("Swipe to move · Tap to select", size: 11, color: KH.textFaint)
                }
                .opacity(touchPoint == nil ? 0.7 : 0)
                .animation(.easeOut(duration: 0.15), value: touchPoint == nil)

                // Touch indicator
                if let p = touchPoint {
                    Circle()
                        .fill(KH.green.opacity(0.55))
                        .frame(width: 64, height: 64)
                        .blur(radius: 4)
                        .position(p)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { g in onDrag(g.location, size: geo.size) }
                    .onEnded { g in onDragEnd(g.location, size: geo.size) }
            )
        }
        .frame(height: 360)
    }

    private func onDrag(_ point: CGPoint, size: CGSize) {
        touchPoint = point
        if dragStart == nil {
            dragStart = point
            lastSent = point
            let (x, y) = mapped(point, size)
            atv.touch(x: x, y: y, phase: 1)   // press
        } else if let last = lastSent, hypot(point.x - last.x, point.y - last.y) >= 7 {
            lastSent = point
            let (x, y) = mapped(point, size)
            atv.touch(x: x, y: y, phase: 3)   // move
        }
    }

    private func onDragEnd(_ point: CGPoint, size: CGSize) {
        let (x, y) = mapped(point, size)
        atv.touch(x: x, y: y, phase: 4)       // release
        if let start = dragStart, hypot(point.x - start.x, point.y - start.y) < 11 {
            atv.select()                       // negligible movement → tap = select
        }
        dragStart = nil
        lastSent = nil
        withAnimation(.easeOut(duration: 0.2)) { touchPoint = nil }
    }

    private func mapped(_ p: CGPoint, _ size: CGSize) -> (Int, Int) {
        let x = Int((p.x / max(size.width, 1)) * 1000)
        let y = Int((p.y / max(size.height, 1)) * 1000)
        return (min(max(x, 0), 1000), min(max(y, 0), 1000))
    }

    // MARK: Button row

    private var buttonRow: some View {
        HStack(spacing: 14) {
            iconPill("chevron.backward", "Menu") { atv.menu() }
            iconPill("tv", "TV") { atv.home() }
            iconPill("playpause.fill", "Play") { atv.playPause() }
        }
    }

    private func iconPill(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 22, weight: .medium))
                MonoLabel(label, size: 10, color: KH.textFaint)
            }
            .foregroundStyle(KH.textPrimary)
            .frame(width: 100, height: 76)
            .background(KH.card, in: RoundedRectangle(cornerRadius: KH.cornerSmall, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: KH.cornerSmall, style: .continuous).strokeBorder(KH.hairline, lineWidth: 1))
        }
        .buttonStyle(PressScale())
    }

    // MARK: Volume

    private var volumeRocker: some View {
        HStack(spacing: 0) {
            volButton("minus", .volumeDown)
            Rectangle().fill(KH.hairline).frame(width: 1, height: 34)
            volButton("plus", .volumeUp)
        }
        .frame(width: 240, height: 60)
        .background(KH.card, in: Capsule())
        .overlay(Capsule().strokeBorder(KH.hairline, lineWidth: 1))
    }

    private func volButton(_ symbol: String, _ cmd: HidCommand) -> some View {
        Button { atv.send(cmd) } label: {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isPulsing(cmd) ? KH.green : KH.textPrimary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }

    // MARK: States

    private var notConfigured: some View {
        VStack(spacing: 14) {
            Image(systemName: "appletv")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(KH.textFaint)
            Text("Apple TV not paired")
                .font(KH.text(18)).foregroundStyle(KH.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isPulsing(_ cmd: HidCommand) -> Bool { atv.pulse == cmd }

    private var statusText: String {
        switch atv.status {
        case .idle: return "—"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .failed(let m): return m
        }
    }
    private var statusColor: Color {
        switch atv.status {
        case .connected: return KH.green
        case .failed: return KH.orange
        default: return KH.textFaint
        }
    }
}

/// Press-down scale used across the remote controls.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
