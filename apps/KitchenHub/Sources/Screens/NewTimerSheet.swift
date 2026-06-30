import SwiftUI

/// Sheet for creating a custom timer: a name field plus an hours/minutes/seconds
/// countdown picker. Presented from the Timers screen. Orange is the timer accent.
struct NewTimerSheet: View {
    @EnvironmentObject var timers: TimersModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Timer"
    @State private var hours = 0
    @State private var minutes = 5
    @State private var seconds = 0

    private var total: Int { hours * 3600 + minutes * 60 + seconds }
    private var trimmedName: String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Timer" : t
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                nameField
                durationPicker
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(KH.bg.ignoresSafeArea())
            .navigationTitle("New Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(KH.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start() }
                        .font(KH.text(17, .bold))
                        .foregroundStyle(total == 0 ? KH.textFaint : KH.orange)
                        .disabled(total == 0)
                }
            }
        }
        .presentationDetents([.medium])
        .tint(KH.orange)
    }

    // MARK: Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel("NAME")
            TextField("Timer", text: $name)
                .font(KH.text(20, .semibold))
                .foregroundStyle(KH.textPrimary)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .padding(.horizontal, 18)
                .frame(height: 56)
                .background(KH.fill, in: RoundedRectangle(cornerRadius: KH.cornerSmall, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Duration

    private var durationPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel("DURATION")
            HStack(spacing: 0) {
                wheel($hours, range: 0...23, unit: "hr")
                wheel($minutes, range: 0...59, unit: "min")
                wheel($seconds, range: 0...59, unit: "sec")
            }
            .frame(maxWidth: .infinity)
            .frame(height: 168)
            .background(KH.fill, in: RoundedRectangle(cornerRadius: KH.cornerSmall, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func wheel(_ value: Binding<Int>, range: ClosedRange<Int>, unit: String) -> some View {
        HStack(spacing: 4) {
            Picker("", selection: value) {
                ForEach(Array(range), id: \.self) { n in
                    Text("\(n)")
                        .font(KH.mono(22, .medium))
                        .monospacedDigit()
                        .tag(n)
                }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            .clipped()

            Text(unit)
                .font(KH.mono(13, .medium))
                .foregroundStyle(KH.textFaint)
        }
    }

    // MARK: Actions

    private func start() {
        guard total > 0 else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            _ = timers.add(name: trimmedName, seconds: TimeInterval(total))
        }
        dismiss()
    }
}
