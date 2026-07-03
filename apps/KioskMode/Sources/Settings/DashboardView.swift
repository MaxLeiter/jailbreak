import SwiftUI

/// The home screen once set up: a big status card plus the two settings that
/// matter (target app, escape method) and the master switch.
struct DashboardView: View {
    @Environment(KioskConfig.self) private var config
    @State private var showAppPicker = false

    var body: some View {
        @Bindable var config = config
        ScrollView {
            VStack(spacing: 18) {
                StatusCard()

                Card {
                    VStack(spacing: 0) {
                        SettingRow(icon: "app.badge.fill", label: "Locked app",
                                   value: config.targetName.isEmpty ? "None" : config.targetName) {
                            showAppPicker = true
                        }
                        Divider().opacity(0.15).padding(.vertical, 4)
                        NavigationLinkRow(icon: config.escapeMethod.symbol,
                                          label: "Escape", value: config.escapeMethod.title) {
                            EscapeSettingsView()
                        }
                    }
                }

                Card {
                    Toggle(isOn: Binding(
                        get: { config.enabled },
                        set: { config.enabled = $0; config.paused = false; config.save() })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Kiosk lock").font(.display(17, .semibold))
                            Text("Master switch. Turn off to use the iPad freely.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .tint(Theme.accent)
                }

                HowItWorks()
            }
            .padding(20)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Kiosk Mode")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAppPicker) {
            NavigationStack {
                AppPickerView(selectedBundleID: config.targetBundleID) { app in
                    config.targetBundleID = app.bundleID
                    config.targetName = app.name
                    config.save()
                    showAppPicker = false
                }
                .navigationTitle("Locked App")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showAppPicker = false }
                    }
                }
            }
            .presentationDetents([.large])
        }
    }
}

/// The hero: a glowing indicator light + one-tap arm/pause.
private struct StatusCard: View {
    @Environment(KioskConfig.self) private var config

    private var color: Color {
        switch config.runState {
        case .off:    return Theme.idle
        case .locked: return Theme.accent
        case .paused: return Theme.paused
        }
    }
    private var title: String {
        switch config.runState {
        case .off:    return "Off"
        case .locked: return "Locked"
        case .paused: return "Paused"
        }
    }
    private var detail: String {
        switch config.runState {
        case .off:    return "The iPad works normally."
        case .locked: return "Locked to \(config.targetName). Use your escape shortcut to pause."
        case .paused: return "Lock is paused. Tap to re-lock, or use your escape shortcut."
        }
    }

    var body: some View {
        Card {
            VStack(spacing: 18) {
                IndicatorLight(color: color, active: config.runState != .off)
                VStack(spacing: 6) {
                    Text(title).font(.display(30, .bold)).foregroundStyle(color)
                    Text(detail)
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if config.runState != .off {
                    Button {
                        config.paused.toggle()
                        config.save()
                    } label: {
                        Text(config.paused ? "Re-lock now" : "Pause lock")
                            .font(.display(16, .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(color.opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .foregroundStyle(color)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

private struct IndicatorLight: View {
    let color: Color
    let active: Bool
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.18)).frame(width: 96, height: 96)
                .blur(radius: active ? 6 : 0)
            Circle().fill(color.gradient).frame(width: 52, height: 52)
                .shadow(color: color.opacity(active ? 0.6 : 0), radius: 16)
        }
        .symbolEffect(.pulse, isActive: active)
        .animation(.smooth, value: color)
    }
}

// MARK: - Rows

private struct SettingRow: View {
    let icon: String
    let label: String
    let value: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            rowBody(icon: icon, label: label, value: value)
        }
        .buttonStyle(.plain)
    }
}

private struct NavigationLinkRow<Destination: View>: View {
    let icon: String
    let label: String
    let value: String
    @ViewBuilder let destination: () -> Destination
    var body: some View {
        NavigationLink { destination() } label: {
            rowBody(icon: icon, label: label, value: value)
        }
        .buttonStyle(.plain)
    }
}

private func rowBody(icon: String, label: String, value: String) -> some View {
    HStack(spacing: 14) {
        Image(systemName: icon).font(.title3).frame(width: 28).foregroundStyle(Theme.accent)
        Text(label).font(.body.weight(.medium))
        Spacer()
        Text(value).font(.body).foregroundStyle(.secondary).lineLimit(1)
        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
    }
    .padding(.vertical, 8)
    .contentShape(Rectangle())
}

private struct HowItWorks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How it works").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            Text("While locked, leaving the app brings it right back. The iPad still sleeps and auto-locks on its own — kiosk enforcement pauses on the Lock Screen so it never wakes the panel.")
                .font(.footnote).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

/// Standalone escape-method screen (settings variant of the onboarding step).
struct EscapeSettingsView: View {
    @Environment(KioskConfig.self) private var config
    var body: some View {
        @Bindable var config = config
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pick the hardware shortcut that pauses and resumes the lock.")
                    .font(.callout).foregroundStyle(.secondary)
                EscapePicker(method: Binding(
                    get: { config.escapeMethod },
                    set: { config.escapeMethod = $0; config.save() }))
            }
            .padding(20)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Escape")
        .navigationBarTitleDisplayMode(.inline)
    }
}
