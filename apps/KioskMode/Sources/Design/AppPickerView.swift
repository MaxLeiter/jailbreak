import SwiftUI

/// Searchable, A–Z sectioned list of installed apps with real Home Screen icons.
/// Reused by onboarding (inline) and settings (in a sheet). While a search is
/// active it collapses to a flat filtered list and hides the index.
struct AppPickerView: View {
    let selectedBundleID: String
    let onSelect: (InstalledApp) -> Void

    @State private var apps: [InstalledApp] = []
    @State private var query = ""
    @State private var loaded = false

    private var filtered: [InstalledApp] {
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(query)
            || $0.bundleID.localizedCaseInsensitiveContains(query) }
    }

    /// Apps grouped by first letter (A–Z, digits/symbols under "#").
    private var sections: [(key: String, apps: [InstalledApp])] {
        let groups = Dictionary(grouping: filtered) { sectionKey($0.name) }
        return groups.keys.sorted().map { (key: $0, apps: groups[$0] ?? []) }
    }

    private func sectionKey(_ name: String) -> String {
        guard let first = name.first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                List {
                    if query.isEmpty {
                        ForEach(sections, id: \.key) { section in
                            Section {
                                ForEach(section.apps) { appRow($0) }
                            } header: {
                                Text(section.key)
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(.secondary)
                                    .id(section.key)
                            }
                        }
                    } else {
                        ForEach(filtered) { appRow($0) }
                    }

                    if loaded && filtered.isEmpty {
                        Text(query.isEmpty ? "No apps found." : "No matches.")
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)

                if query.isEmpty && sections.count > 2 {
                    AZIndexBar(letters: sections.map(\.key)) { letter in
                        proxy.scrollTo(letter, anchor: .top)
                    }
                    .padding(.trailing, 2)
                }
            }
        }
        .searchable(text: $query, prompt: "Search apps")
        .task {
            guard !loaded else { return }
            apps = InstalledApps.userApps()
            loaded = true
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        Button { onSelect(app) } label: {
            HStack(spacing: 14) {
                AppIconView(app: app, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if app.bundleID == selectedBundleID {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                        .font(.title3)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }
}

/// An app's real icon, falling back to a monogram tile while loading or if the
/// private icon API is unavailable.
struct AppIconView: View {
    let app: InstalledApp
    var size: CGFloat = 44
    @State private var icon: UIImage?

    var body: some View {
        Group {
            if let icon {
                Image(uiImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                Monogram(text: app.monogram, seed: app.bundleID, size: size)
            }
        }
        .task(id: app.bundleID) { icon = AppIcon.image(for: app.bundleID) }
    }
}

/// A Contacts-style A–Z scrubber. Tap or drag along it to jump to a section.
struct AZIndexBar: View {
    let letters: [String]
    let onSelect: (String) -> Void
    @State private var lastLetter: String?

    var body: some View {
        GeometryReader { geo in
            let stepH = geo.size.height / CGFloat(max(letters.count, 1))
            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { l in
                    Text(l)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let idx = min(max(Int(value.location.y / stepH), 0), letters.count - 1)
                        let letter = letters[idx]
                        if letter != lastLetter {
                            lastLetter = letter
                            onSelect(letter)
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                    .onEnded { _ in lastLetter = nil }
            )
        }
        .frame(width: 18)
        .padding(.vertical, 6)
    }
}

/// Three escape-method cards, one selectable at a time.
struct EscapePicker: View {
    @Binding var method: EscapeMethod

    var body: some View {
        VStack(spacing: 12) {
            ForEach(EscapeMethod.allCases) { m in
                Button { withAnimation(.snappy) { method = m } } label: { card(m) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func card(_ m: EscapeMethod) -> some View {
        let selected = m == method
        return HStack(spacing: 14) {
            Image(systemName: m.symbol)
                .font(.title2)
                .frame(width: 34)
                .foregroundStyle(selected ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(m.title).font(.display(17, .semibold)).foregroundStyle(.primary)
                Text(m.subtitle).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Theme.accent : .secondary.opacity(0.5))
                .font(.title3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.7) : .white.opacity(0.06),
                              lineWidth: selected ? 2 : 1)
        )
    }
}
