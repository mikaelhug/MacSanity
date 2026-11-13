import Foundation
import MacSanityCore

/// One item MacSanity moved to the Trash (or a command it ran).
struct HistoryEntry: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let session: UUID
    let date: Date
    let title: String
    let category: CleanerCategory
    let originalPath: String
    /// Where it is in the Trash now (nil for commands).
    var trashPath: String?
    let size: Int64
    /// Root-owned items need the admin password to restore, and get their
    /// original owner back.
    let needsAdmin: Bool
    let originalOwner: UInt32?
    let originalGroup: UInt32?
    /// A tool command that ran instead of a move ("brew cleanup --prune=all").
    let command: String?
    var state: State

    enum State: String, Codable, Sendable { case inTrash, restored, emptied, ran }
}

/// The cleaner's undo log, at ~/Library/Application Support/MacSanity/CleanerHistory.json.
@MainActor
final class CleanerHistory {
    private(set) var entries: [HistoryEntry] = []
    private let url: URL

    init(fileName: String = "CleanerHistory.json") {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacSanity", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(fileName)
        load()
    }

    /// Remove this history's file (self-test cleanup only).
    func deleteFile() { try? FileManager.default.removeItem(at: url) }

    func append(_ new: [HistoryEntry]) {
        entries.append(contentsOf: new)
        save()
    }

    func update(_ entry: HistoryEntry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i] = entry; save() }
    }

    /// Re-check which items are still in the Trash (the user may have emptied it
    /// or used Put Back in Finder).
    func refreshStates() {
        var changed = false
        for i in entries.indices where entries[i].state == .inTrash {
            if let t = entries[i].trashPath, !DiskIO.exists(t) {
                entries[i].state = DiskIO.exists(entries[i].originalPath) ? .restored : .emptied
                changed = true
            }
        }
        if changed { save() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
