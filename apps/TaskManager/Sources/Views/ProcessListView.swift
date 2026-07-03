import SwiftUI

enum ListScope: String, CaseIterable, Identifiable {
    case apps = "Apps"
    case system = "System"
    var id: String { rawValue }
    func includes(_ row: ProcessRow) -> Bool { self == .apps ? row.isApp : !row.isApp }
}

enum SortField: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case name = "Name"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .name: return "textformat"
        }
    }
}

/// The app's single screen: a fixed dashboard header over a live, scrolling
/// process table. Filtering and sorting are derived here from the engine's raw
/// rows so the engine stays a pure data source.
struct ProcessListView: View {
    @EnvironmentObject private var engine: MonitorEngine
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var scope: ListScope = .apps
    @State private var sort: SortField = .cpu
    @State private var selectedPID: pid_t?

    private var visibleRows: [ProcessRow] {
        let filtered = engine.rows.filter(scope.includes)
        switch sort {
        case .cpu:    return filtered.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory: return filtered.sorted { $0.residentBytes > $1.residentBytes }
        case .name:   return filtered.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        }
    }

    var body: some View {
        NavigationStack {
            // One scrolling list on every size: the dashboard scrolls away as a
            // header while the Apps/System + Sort controls pin to the top. A fixed
            // dashboard would eat the whole screen on iPhone (and on many-core
            // devices), leaving no room for the process list.
            List {
                Section {
                    dashboard
                        .listRowInsets(EdgeInsets(top: 4, leading: Theme.gutter,
                                                  bottom: Theme.gutter, trailing: Theme.gutter))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                Section {
                    processRows
                } header: {
                    controlBar
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("Task Manager")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedPID) { pid in
                ProcessDetailView(pid: pid)
                    .environmentObject(engine)
                    .presentationDetents([.large, .medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Dashboard

    @ViewBuilder private var dashboard: some View {
        let memory = MemoryRing(memory: engine.memory)
        let cpu = CpuTile(overall: engine.overallCPU, history: engine.overallCPUHistory, cores: engine.coreUsage)
        if hSize == .regular {
            HStack(alignment: .top, spacing: Theme.tileSpacing) {
                memory.frame(maxWidth: .infinity)
                cpu.frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: Theme.tileSpacing) { memory; cpu }
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 12) {
            Picker("Scope", selection: $scope) {
                ForEach(ListScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            Spacer()

            Text("\(visibleRows.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(visibleRows.count) processes")

            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(SortField.allCases) { field in
                        Label(field.rawValue, systemImage: field.symbol).tag(field)
                    }
                }
            } label: {
                Label("Sort: \(sort.rawValue)", systemImage: "arrow.up.arrow.down")
                    .font(.subheadline)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .tint(.secondary)
        }
        .textCase(nil)
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 8)
        .background(Theme.page)   // opaque so rows don't show through when pinned
        .listRowInsets(EdgeInsets())
    }

    // MARK: - Rows

    @ViewBuilder private var processRows: some View {
        if visibleRows.isEmpty {
            Group {
                if engine.rows.isEmpty {
                    ContentUnavailableCompat()
                } else {
                    Text(scope == .apps ? "No running apps." : "No system processes.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            ForEach(visibleRows) { row in
                Button { selectedPID = row.pid } label: { ProcessRowView(row: row) }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.hairline)
                    .listRowInsets(EdgeInsets(top: 0, leading: Theme.gutter, bottom: 0, trailing: Theme.gutter))
            }
        }
    }
}

extension pid_t: @retroactive Identifiable {
    public var id: pid_t { self }
}

/// Minimal empty-state shown before the first sample lands.
private struct ContentUnavailableCompat: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Sampling processes…").font(.callout).foregroundStyle(.secondary)
        }
    }
}
