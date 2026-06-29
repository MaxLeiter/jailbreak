import SwiftUI

/// Wheel picker (hours / minutes / seconds) for setting a custom timer length.
struct TimePickerSheet: View {
    let initial: TimeInterval
    let onSet: (TimeInterval) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var hours: Int
    @State private var minutes: Int
    @State private var seconds: Int

    init(initial: TimeInterval, onSet: @escaping (TimeInterval) -> Void) {
        self.initial = initial
        self.onSet = onSet
        let s = max(0, Int(initial))
        _hours = State(initialValue: s / 3600)
        _minutes = State(initialValue: (s % 3600) / 60)
        _seconds = State(initialValue: s % 60)
    }

    private var total: Int { hours * 3600 + minutes * 60 + seconds }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                wheel("hours", value: $hours, range: 0..<24)
                wheel("min", value: $minutes, range: 0..<60)
                wheel("sec", value: $seconds, range: 0..<60)
            }
            .padding(.horizontal)
            .navigationTitle("Custom Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        if total > 0 { onSet(TimeInterval(total)) }
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .disabled(total == 0)
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }

    private func wheel(_ label: String, value: Binding<Int>, range: Range<Int>) -> some View {
        HStack(spacing: 2) {
            Picker(label, selection: value) {
                ForEach(range, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}
