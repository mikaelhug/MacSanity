import MacSanityCore
import SwiftUI

struct HistoryView: View {
    let model: CleanerModel

    var body: some View {
        let sessions = Dictionary(grouping: model.historyEntries, by: \.session)
            .map { (id: $0.key, entries: $0.value) }
            .sorted { ($0.entries.first?.date ?? .distantPast) > ($1.entries.first?.date ?? .distantPast) }
        Group {
            if sessions.isEmpty {
                Text("Nothing cleaned yet. Everything MacSanity moves to the Trash is listed here so you can put it back.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sessions, id: \.id) { session in
                        Section {
                            ForEach(session.entries) { entry in HistoryRow(model: model, entry: entry) }
                        } header: {
                            sessionHeader(session.entries)
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
        .onAppear { model.refreshHistory() }
    }

    private func sessionHeader(_ entries: [HistoryEntry]) -> some View {
        let inTrash = entries.filter { $0.state == .inTrash }
        return HStack {
            Text(entries.first?.date.formatted(date: .abbreviated, time: .shortened) ?? "")
            Text("· \(Bytes.format(entries.reduce(0) { $0 + $1.size }))").monospacedDigit()
            Spacer()
            if !inTrash.isEmpty {
                Button("Put All Back") { Task { _ = await model.restore(inTrash) } }
                Button("Empty from Trash") { Task { await model.emptyFromTrash(inTrash) } }
            }
        }
        .controlSize(.small)
    }
}

struct HistoryRow: View {
    let model: CleanerModel
    let entry: HistoryEntry

    var body: some View {
        HStack {
            Image(systemName: entry.category.symbol).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                Text(entry.command ?? entry.originalPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(Bytes.format(entry.size)).monospacedDigit().foregroundStyle(.secondary)
            switch entry.state {
            case .inTrash:
                Button("Put Back") { Task { _ = await model.restore([entry]) } }.controlSize(.small)
            case .restored: Text("Put back").font(.caption).foregroundStyle(.secondary)
            case .emptied: Text("Deleted").font(.caption).foregroundStyle(.secondary)
            case .ran: Text("Command ran").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
