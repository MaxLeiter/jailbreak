import SwiftUI
import Charts

/// Per-process detail sheet. Reads the live row from the engine by pid each
/// render, so its charts and numbers keep updating while open. Quit / Force Kill
/// are offered only for app processes (system processes are read-only), and both
/// sit behind a confirmation dialog.
struct ProcessDetailView: View {
    let pid: pid_t
    @EnvironmentObject private var engine: MonitorEngine
    @Environment(\.dismiss) private var dismiss

    @State private var pendingSignal: ProcessKiller.Signal?
    @State private var failureMessage: String?

    private var row: ProcessRow? { engine.rows.first { $0.pid == pid } }

    var body: some View {
        NavigationStack {
            Group {
                if let row {
                    content(row)
                } else {
                    processEnded
                }
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func content(_ row: ProcessRow) -> some View {
        ScrollView {
            VStack(spacing: Theme.gutter) {
                header(row)

                TimeChart(title: "CPU", unit: "%", values: row.cpuHistory,
                          color: Theme.cpu, ceiling: max(100, row.cpuHistory.max() ?? 0))
                    .card()
                TimeChart(title: "Memory", unit: "MB", values: row.memoryHistory,
                          color: Theme.memory, ceiling: nil)
                    .card()

                metadata(row)

                if row.isApp { killButtons(row) }
            }
            .padding(Theme.gutter)
        }
        .confirmationDialog(
            pendingSignal.map { "\($0.label) \(row.displayName)?" } ?? "",
            isPresented: Binding(get: { pendingSignal != nil }, set: { if !$0 { pendingSignal = nil } }),
            titleVisibility: .visible
        ) {
            if let signal = pendingSignal {
                Button(signal.label, role: .destructive) { perform(signal, on: row) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingSignal == .forceKill
                 ? "Force Kill sends SIGKILL — the app is terminated immediately with no chance to save."
                 : "Quit sends SIGTERM, asking the app to close.")
        }
        .alert("Couldn’t signal process", isPresented: Binding(
            get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } })) {
            Button("OK") {}
        } message: { Text(failureMessage ?? "") }
    }

    // MARK: - Sections

    private func header(_ row: ProcessRow) -> some View {
        HStack(spacing: 14) {
            ProcessIcon(row: row, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.displayName).font(.title2.weight(.semibold)).lineLimit(2)
                Text(row.isApp ? "Application" : "System process")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.percent(row.cpuPercent)).font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                Text("CPU").tileLabel()
            }
        }
    }

    private func metadata(_ row: ProcessRow) -> some View {
        VStack(spacing: 0) {
            metaRow("Process ID", "\(row.pid)")
            divider
            metaRow("Parent PID", "\(row.ppid)")
            divider
            metaRow("User ID", "\(row.uid)")
            divider
            metaRow("Threads", "\(row.threadCount)")
            divider
            metaRow("Memory", Fmt.memory(row.residentBytes))
            divider
            metaRow("Uptime", Fmt.uptime(row.uptime))
            if let path = row.executablePath {
                divider
                metaRow("Path", path, mono: true)
            }
        }
        .card(padding: 0)
    }

    private var divider: some View { Divider().overlay(Theme.hairline).padding(.leading, 16) }

    private func metaRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .font(mono ? .caption.monospaced() : .callout.monospacedDigit())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func killButtons(_ row: ProcessRow) -> some View {
        VStack(spacing: 10) {
            Button { pendingSignal = .quit } label: {
                Label("Quit", systemImage: "power").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)

            Button { pendingSignal = .forceKill } label: {
                Label("Force Kill", systemImage: "xmark.octagon.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .controlSize(.large)
        .padding(.top, 4)
    }

    private var processEnded: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
            Text("Process ended").font(.title3.weight(.medium))
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }
        .padding(40)
    }

    // MARK: - Actions

    private func perform(_ signal: ProcessKiller.Signal, on row: ProcessRow) {
        switch ProcessKiller.send(signal, to: row.pid) {
        case .ok, .noSuchProcess:
            dismiss()
        case .refusedOwnProcess:
            failureMessage = "Task Manager won’t signal itself."
        case .notPermitted:
            failureMessage = "The system denied the signal to \(row.displayName) (pid \(row.pid))."
        case .failed(let code):
            failureMessage = "Signal failed (errno \(code))."
        }
    }
}

/// Larger time-series chart for the detail sheet: keeps the sparkline mark spec
/// (2px round line, ~12% area wash) but adds recessive gridlines and a y-axis so
/// absolute values are readable.
private struct TimeChart: View {
    let title: String
    let unit: String
    let values: [Double]
    let color: Color
    let ceiling: Double?

    private var domainMax: Double {
        let dataMax = values.max() ?? 1
        return max(ceiling ?? dataMax, 1)
    }
    private var current: Double { values.last ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).tileLabel()
                Spacer()
                Text(unit == "%" ? Fmt.percent(current) : "\(Int(current)) \(unit)")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
            }

            Chart(Array(values.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("t", index), yStart: .value("min", 0), yEnd: .value("v", value))
                    .foregroundStyle(.linearGradient(
                        colors: [color.opacity(0.26), color.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", index), y: .value("v", value))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...domainMax)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel().font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(height: 150)
            .accessibilityLabel("\(title) over time")
            .accessibilityValue(unit == "%" ? Fmt.percent(current) : "\(Int(current)) \(unit)")
        }
    }
}
