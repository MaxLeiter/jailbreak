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
    /// Natural direction when first selected: names read A→Z, metrics highest-first.
    var defaultAscending: Bool { self == .name }
}

/// The app's single screen: a fixed dashboard header over a live, scrolling
/// process table. Filtering and sorting are derived here from the engine's raw
/// rows so the engine stays a pure data source.
struct ProcessListView: View {
    @EnvironmentObject private var engine: MonitorEngine
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var scope: ListScope = .apps
    @State private var sort: SortField = .cpu
    @State private var ascending = false        // CPU/Memory default high→low; Name A→Z
    @State private var searchText = ""
    @State private var selectedPID: pid_t?

    private var trimmedQuery: String { searchText.trimmingCharacters(in: .whitespaces) }

    private var visibleRows: [ProcessRow] {
        var rows = engine.rows.filter(scope.includes)
        let query = trimmedQuery
        if !query.isEmpty { rows = rows.filter { $0.matches(query) } }
        // Direction-aware comparator (no reversed-array copy on the default path).
        let asc = ascending
        switch sort {
        case .cpu:    rows.sort { asc ? $0.cpuPercent < $1.cpuPercent : $0.cpuPercent > $1.cpuPercent }
        case .memory: rows.sort { asc ? $0.residentBytes < $1.residentBytes : $0.residentBytes > $1.residentBytes }
        case .name:   rows.sort {
            let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return asc ? order == .orderedAscending : order == .orderedDescending
        }
        }
        return rows
    }

    /// Pick a sort field; re-picking the current field flips direction. A new
    /// field resets to its natural default (names A→Z, metrics highest-first).
    private func selectSort(_ field: SortField) {
        if sort == field { ascending.toggle() }
        else { sort = field; ascending = field.defaultAscending }
    }

    var body: some View {
        NavigationStack {
            // One scrolling list on every size: the dashboard scrolls away as a
            // header while the Apps/System + Sort controls pin to the top. A fixed
            // dashboard would eat the whole screen on iPhone (and on many-core
            // devices), leaving no room for the process list.
            let rows = visibleRows   // compute the filter+sort once per refresh
            List {
                Section {
                    dashboard
                        .listRowInsets(EdgeInsets(top: 4, leading: Theme.gutter,
                                                  bottom: Theme.gutter, trailing: Theme.gutter))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                Section {
                    processRows(rows)
                } header: {
                    controlBar(count: rows.count)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("Task Manager")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Search name or bundle id")
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

    private func controlBar(count: Int) -> some View {
        HStack(spacing: 12) {
            Picker("Scope", selection: $scope) {
                ForEach(ListScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            Spacer()

            Text("\(count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(count) processes")

            Menu {
                ForEach(SortField.allCases) { field in
                    Button { selectSort(field) } label: {
                        if field == sort {
                            Label("\(field.rawValue) · \(ascending ? "ascending" : "descending")",
                                  systemImage: ascending ? "chevron.up" : "chevron.down")
                        } else {
                            Label(field.rawValue, systemImage: field.symbol)
                        }
                    }
                }
            } label: {
                Label(sort.rawValue, systemImage: ascending ? "arrow.up" : "arrow.down")
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

    @ViewBuilder private func processRows(_ rows: [ProcessRow]) -> some View {
        if rows.isEmpty {
            Group {
                if engine.rows.isEmpty {
                    ContentUnavailableCompat()
                } else {
                    let empty = !trimmedQuery.isEmpty
                        ? "No matches for “\(trimmedQuery)”."
                        : (scope == .apps ? "No running apps." : "No system processes.")
                    Text(empty)
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            ForEach(rows) { row in
                Button { selectedPID = row.pid } label: {
                    ProcessRowView(row: row, compact: hSize != .regular).equatable()
                }
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
