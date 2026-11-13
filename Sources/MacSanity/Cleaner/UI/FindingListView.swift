import MacSanityCore
import SwiftUI

struct FindingListView: View {
    @Bindable var model: CleanerModel
    let category: CleanerCategory

    var body: some View {
        Group {
            if model.result == nil {
                ScanPlaceholder(model: model)
            } else {
                let groups = model.groupedFindings(in: category)
                List {
                    Section {
                        header
                    }
                    if groups.isEmpty {
                        Text(model.query.isEmpty ? "Nothing found here — nice." : "No matches for “\(model.query)”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(groups, id: \.group) { group in
                        Section {
                            ForEach(group.findings) { finding in
                                FindingRow(model: model, finding: finding)
                            }
                        } header: {
                            HStack {
                                Text(group.group)
                                Spacer()
                                Text(Bytes.format(group.findings.reduce(0) { $0 + $1.size })).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(category.title)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(category.blurb).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Menu("Select") {
                    Button("All Safe") { model.selectAll(in: category, safety: .safe) }
                    Button("All") { model.selectAll(in: category, safety: nil) }
                    Divider()
                    Button("None") { model.selectNone(in: category) }
                }
                .fixedSize()
                if category == .leftovers {
                    Toggle("Show uncertain", isOn: $model.showUncertain).toggleStyle(.checkbox)
                }
                Spacer()
                Text("\(Bytes.text(model.selectedSize(in: category))) of \(Bytes.text(model.totalSize(in: category)))")
                    .foregroundStyle(.secondary).monospacedDigit()
                Picker("Sort", selection: $model.sort) {
                    ForEach(FindingSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}

struct FindingRow: View {
    let model: CleanerModel
    let finding: Finding

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if finding.isRemovable {
                Toggle("", isOn: Binding(get: { model.isSelected(finding) },
                                         set: { model.setSelected(finding, $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Select \(finding.title)")
            } else {
                Image(systemName: "info.circle").foregroundStyle(.secondary).frame(width: 14)
            }
            icon.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(finding.title).lineLimit(1).truncationMode(.middle)
                    SafetyBadge(safety: finding.safety)
                    if finding.needsAdmin {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                            .help("Needs your admin password")
                    }
                }
                if !finding.reason.isEmpty {
                    Text(finding.reason).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                if case .reportOnly(let hint) = finding.action {
                    Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Bytes.format(finding.size)).monospacedDigit().fontWeight(.medium)
                if let used = finding.lastUsed {
                    Text(used.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                model.reveal(finding.items.map(\.path))
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help(finding.items.count == 1 ? "Show in Finder: \(finding.items[0].path)"
                  : "Show \(finding.items.count) items in Finder")
            .accessibilityLabel("Show \(finding.title) in Finder")
            .disabled(finding.items.isEmpty)
        }
        .padding(.vertical, 6)
        // Details on hover instead of extra lines of text.
        .help([finding.details.isEmpty ? nil : finding.details,
               finding.afterRemoval.isEmpty ? nil : "After removal: \(finding.afterRemoval)"]
            .compactMap { $0 }.joined(separator: "\n\n"))
    }

    @ViewBuilder private var icon: some View {
        if let path = finding.iconPath {
            Image(nsImage: model.icon(for: path)).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: finding.category.symbol).font(.title3).foregroundStyle(.secondary)
        }
    }
}
