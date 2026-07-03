import SwiftUI

/// A short, pleasant setup: welcome → pick the app → choose how to escape →
/// arm it. Choices live in a draft and are only written on the final step, so
/// backing out never arms the kiosk.
struct OnboardingFlow: View {
    @Environment(KioskConfig.self) private var config

    @State private var step = 0
    @State private var pick: InstalledApp?
    @State private var escape: EscapeMethod = .volumeUpTriple

    private let lastStep = 3

    var body: some View {
        VStack(spacing: 0) {
            ProgressDots(count: lastStep + 1, index: step)
                .padding(.top, 24)

            ZStack {
                switch step {
                case 0: WelcomePage()
                case 1: PickAppPage(pick: $pick)
                case 2: EscapeStepPage(escape: $escape)
                default: FinishPage(app: pick, escape: escape)
                }
            }
            .frame(maxWidth: 620, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)

            actionBar
                .frame(maxWidth: 620)
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BackdropGlow())
    }

    private var canAdvance: Bool {
        switch step {
        case 1:  return pick != nil
        default: return true
        }
    }

    @ViewBuilder private var actionBar: some View {
        HStack(spacing: 14) {
            if step > 0 {
                Button {
                    withAnimation(.smooth) { step -= 1 }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 52, height: 52)
                        .background(.regularMaterial, in: Circle())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }

            if step < lastStep {
                PrimaryButton(title: "Continue", systemImage: "arrow.right") {
                    withAnimation(.smooth) { step += 1 }
                }
                .opacity(canAdvance ? 1 : 0.4)
                .disabled(!canAdvance)
            } else {
                PrimaryButton(title: "Enable Kiosk Mode", systemImage: "lock.fill") {
                    arm()
                }
            }
        }
    }

    private func arm() {
        guard let pick else { return }
        config.targetBundleID = pick.bundleID
        config.targetName = pick.name
        config.escapeMethod = escape
        config.paused = false
        config.enabled = true
        config.configured = true
        config.save()
    }
}

// MARK: - Pages

private struct WelcomePage: View {
    @State private var shown = false
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "ipad.landscape.and.arrow.forward")
                .font(.system(size: 78, weight: .light))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.pulse, options: .repeating)
                .opacity(shown ? 1 : 0)
                .scaleEffect(shown ? 1 : 0.9)
            VStack(spacing: 12) {
                Text("Kiosk Mode")
                    .font(.display(40, .bold))
                Text("Lock this iPad to a single app.\nIt keeps that app front and centre, and relaunches it if anyone leaves.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            Spacer()
            Text("The iPad still sleeps and auto-locks normally.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .onAppear { withAnimation(.smooth(duration: 0.6)) { shown = true } }
    }
}

private struct PickAppPage: View {
    @Binding var pick: InstalledApp?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StepHeader(title: "Choose the app", subtitle: "Which app should this iPad be locked to?")
                .padding(.horizontal, 28)
            AppPickerView(selectedBundleID: pick?.bundleID ?? "") { pick = $0 }
        }
        .padding(.top, 10)
    }
}

private struct EscapeStepPage: View {
    @Binding var escape: EscapeMethod
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                StepHeader(title: "How do you get out?",
                           subtitle: "A hardware shortcut pauses the lock so you can use the iPad normally. Do it again to re-lock.")
                EscapePicker(method: $escape)
            }
            .padding(28)
        }
    }
}

private struct FinishPage: View {
    let app: InstalledApp?
    let escape: EscapeMethod
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 68))
                .foregroundStyle(Theme.paused)
            Text("Ready to lock")
                .font(.display(30, .bold))
            Card {
                VStack(spacing: 16) {
                    if let app {
                        summaryRow(icon: nil, monogram: app,
                                   label: "Locked to", value: app.name)
                        Divider().opacity(0.2)
                    }
                    summaryRow(icon: escape.symbol, monogram: nil,
                               label: "Escape", value: escape.title)
                }
            }
            Text("Enabling now will bring \(app?.name ?? "the app") to the front.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(28)
    }

    private func summaryRow(icon: String?, monogram: InstalledApp?, label: String, value: String) -> some View {
        HStack(spacing: 14) {
            if let monogram {
                Monogram(text: monogram.monogram, seed: monogram.bundleID, size: 40)
            } else if let icon {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 40, height: 40)
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.semibold))
            }
            Spacer()
        }
    }
}

// MARK: - Small shared bits

private struct StepHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.display(28, .bold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProgressDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Theme.accent : Color.secondary.opacity(0.3))
                    .frame(width: i == index ? 22 : 8, height: 8)
                    .animation(.snappy, value: index)
            }
        }
    }
}

/// Soft amber radial glow behind onboarding to add depth without clutter.
struct BackdropGlow: View {
    var body: some View {
        RadialGradient(
            colors: [Theme.accent.opacity(0.18), .clear],
            center: .top, startRadius: 10, endRadius: 520)
        .ignoresSafeArea()
        .background(Color(.systemBackground))
    }
}
