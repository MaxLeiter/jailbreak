import SwiftUI

/// One process in the list: identity on the left, live metrics on the right,
/// with an inline memory sparkline. The two metric columns are fixed-width and
/// tabular so numbers align down the list.
///
/// `Equatable` (compact passed in, not read from the environment, so it's part
/// of the comparison) + `.equatable()` at the call site lets unchanged rows skip
/// re-rendering during the 1 Hz refresh. `==` compares ONLY the fields this row
/// actually draws — so it doesn't scan the unshown `cpuHistory` ring or metadata
/// like uid/threadCount that never appear here.
struct ProcessRowView: View, Equatable {
    let row: ProcessRow
    /// Compact (iPhone) width — hides the inline sparkline for name room.
    let compact: Bool

    static func == (lhs: ProcessRowView, rhs: ProcessRowView) -> Bool {
        let a = lhs.row, b = rhs.row
        return lhs.compact == rhs.compact
            && a.pid == b.pid
            && a.displayName == b.displayName
            && a.bundleID == b.bundleID          // drives the icon + App/System label
            && a.residentBytes == b.residentBytes
            && a.cpuPercent == b.cpuPercent
            && a.memoryHistory == b.memoryHistory  // the only history the row draws
    }

    var body: some View {
        HStack(spacing: 12) {
            ProcessIcon(row: row)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(row.isApp ? "App · pid \(row.pid)" : "System · pid \(row.pid)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // The inline sparkline is a nice-to-have; drop it at compact (iPhone)
            // width so the name/pid isn't squeezed. The detail sheet still charts it.
            if !compact {
                Sparkline(values: row.memoryHistory, color: Theme.memory)
                    .frame(width: 56, height: 26)
                    .opacity(row.memoryHistory.count > 1 ? 1 : 0)
            }

            metric(Fmt.memory(row.residentBytes), tint: Theme.memory, width: 68)
            metric(Fmt.percent(row.cpuPercent), tint: Theme.cpu, width: 56)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.displayName)
        .accessibilityValue("\(row.isApp ? "App" : "System process"), memory \(Fmt.memory(row.residentBytes)), CPU \(Fmt.percent(row.cpuPercent))")
        .accessibilityAddTraits(.isButton)
    }

    private func metric(_ text: String, tint: Color, width: CGFloat) -> some View {
        Text(text)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.primary)
            .frame(width: width, alignment: .trailing)
    }
}

/// App icon when the process matches an installed bundle, else a glyph tile.
/// The icon lookup is cached (`AppIcon`), so this is cheap during scroll.
struct ProcessIcon: View {
    let row: ProcessRow
    var size: CGFloat = 34

    var body: some View {
        Group {
            if let bundleID = row.bundleID, let image = AppIcon.image(for: bundleID) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        Image(systemName: row.isApp ? "app.dashed" : "gearshape")
                            .font(.system(size: size * 0.44))
                            .foregroundStyle(.secondary))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .strokeBorder(Theme.cardStroke, lineWidth: 1))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}
