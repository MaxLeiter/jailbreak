import SwiftUI
import Foundation

/// Full-screen Timers detail: a responsive grid of timers — each with its label,
/// a streamlined countdown, progress, and inline controls — beside a Quick-Add
/// panel. Orange is the timer accent throughout (`KH.orange`).
struct TimersScreen: View {
    @EnvironmentObject var timers: TimersModel
    @EnvironmentObject var app: KHModel

    @State private var showNewTimer = false
    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Timers",
                         trailing: runningSummary,
                         trailingColor: timers.runningCount == 0 ? KH.textFaint : KH.orange) {
                app.backToDashboard()
            }

            GeometryReader { geo in
                HStack(alignment: .top, spacing: KH.gap) {
                    timersArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    rightColumn
                        .frame(width: max(260, geo.size.width * 0.32))
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .sheet(isPresented: $showNewTimer) {
            NewTimerSheet()
                .environmentObject(timers)
        }
    }

    private var runningSummary: String {
        switch timers.runningCount {
        case 0:  return "NO TIMERS"
        case 1:  return "1 TIMER RUNNING"
        default: return "\(timers.runningCount) TIMERS RUNNING"
        }
    }

    // MARK: Timers grid (all timers, each with its label)

    @ViewBuilder private var timersArea: some View {
        if timers.items.isEmpty {
            emptyState
        } else {
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: KH.gap)],
                          alignment: .leading, spacing: KH.gap) {
                    ForEach(timers.items) { item in
                        TimerTile(item: item)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "timer")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(KH.orange.opacity(0.85))
            VStack(spacing: 6) {
                Text("No timers running")
                    .font(KH.text(22, .semibold))
                    .foregroundStyle(KH.textPrimary)
                Text("Tap New Timer or pick a Quick Add preset.")
                    .font(KH.text(15))
                    .foregroundStyle(KH.textSecondary)
                    .multilineTextAlignment(.center)
            }
            PrimaryButton(title: "New Timer", icon: "plus") { showNewTimer = true }
                .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Right column — Quick Add

    private var rightColumn: some View {
        VStack(spacing: KH.gap) {
            quickAddCard
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var quickAddCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                MonoLabel("QUICK ADD")
                Spacer(minLength: 8)
                Button { showNewTimer = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                        Text("New").font(KH.text(14, .semibold))
                    }
                    .foregroundStyle(KH.orange)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(KH.orange.opacity(0.14), in: Capsule(style: .continuous))
                    .overlay(Capsule(style: .continuous).strokeBorder(KH.orange.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            ForEach(timers.quickAdd.indices, id: \.self) { i in
                let q = timers.quickAdd[i]
                Button {
                    withAnimation(spring) { _ = timers.add(name: q.name, minutes: q.minutes) }
                } label: {
                    HStack(spacing: 8) {
                        Text(q.name)
                            .font(KH.text(17, .bold))
                            .foregroundStyle(KH.textPrimary)
                            .khFit()
                        Spacer(minLength: 6)
                        Text("\(q.minutes):00")
                            .font(KH.mono(15))
                            .foregroundStyle(KH.textFaint)
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 56)
                    .frame(maxWidth: .infinity)
                    .background(KH.fill, in: RoundedRectangle(cornerRadius: KH.cornerSmall, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .khCard()
    }
}

// MARK: - Timer tile: label + streamlined countdown + progress + inline controls

private struct TimerTile: View {
    @EnvironmentObject var timers: TimersModel
    let item: TimersModel.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MonoLabel(item.name, color: item.finished ? KH.orange : KH.textFaint)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(statusText)
                    .font(KH.mono(10, .medium))
                    .foregroundStyle(item.finished ? KH.orange : KH.textFaint)
            }

            Text(TimersModel.clock(item.remaining))
                .font(KH.display(56, .light))
                .monospacedDigit()
                .foregroundStyle(item.finished ? KH.orange : KH.textPrimary)
                .khFit()

            TrackBar(fraction: CGFloat(item.progress), fill: KH.timerGradient(), height: 6)
                .animation(.linear(duration: 1), value: item.progress)

            HStack(spacing: 8) {
                control(item.running ? "pause.fill" : "play.fill", tinted: true) { timers.toggle(item.id) }
                control("plus") { timers.addTime(item.id, seconds: 60) }
                control("arrow.counterclockwise") { timers.reset(item.id) }
                Spacer(minLength: 0)
                control("xmark") { timers.remove(item.id) }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .khCard()
        .overlay(
            RoundedRectangle(cornerRadius: KH.corner, style: .continuous)
                .strokeBorder(item.finished ? KH.orange : Color.clear, lineWidth: 1.5)
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: item.finished)
    }

    private var statusText: String {
        if item.finished { return "DONE" }
        return item.running ? "RUNNING" : "PAUSED"
    }

    private func control(_ symbol: String, tinted: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tinted ? KH.onAccent : KH.textPrimary)
                .frame(width: 44, height: 40)
                .background(tinted ? KH.orange : KH.fill,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Primary button (empty state)

private struct PrimaryButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                Text(title)
                    .font(KH.text(18, .bold))
            }
            .foregroundStyle(KH.onAccent)
            .padding(.horizontal, 34)
            .frame(height: 56)
            .background(KH.orange, in: Capsule(style: .continuous))
            .shadow(color: KH.orange.opacity(0.45), radius: 16, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }
}
