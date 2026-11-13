import AppKit
import MacSanityCore
import os

private let log = Logger(subsystem: "com.macsanity.app", category: "Cleaner")

/// Carries out a cleanup. Everything ends in the Trash (with Finder's Put Back
/// for your own files) or in a tool's own cleanup command — nothing is deleted
/// directly. Every path is re-checked against the safety policy right before it
/// moves, and every action is recorded in `CleanerHistory`.
@MainActor
enum Remover {
    struct Outcome {
        var movedBytes: Int64 = 0
        var entries: [HistoryEntry] = []
        var failures: [String] = []
        var skipped: [String] = []
    }

    /// `MACSANITY_CLEANER_DRYRUN=1`: log what would happen, move nothing.
    static var isDryRun: Bool { ProcessInfo.processInfo.environment["MACSANITY_CLEANER_DRYRUN"] == "1" }

    static func perform(_ work: [(finding: Finding, item: FindingItem)], allSelected: [Finding],
                        history: CleanerHistory) async -> Outcome {
        var outcome = Outcome()
        let session = UUID()
        let home = NSHomeDirectory()
        let policy = SafetyPolicy(home: home, userVarFolder: userVarFolder())
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let uid = getuid(), gid = getgid()

        var adminOps: [AdminRunner.Operation] = []
        var adminEntries: [HistoryEntry] = []
        var worktreeRepos = Set<String>()
        var attemptedCommands = Set<String>()

        // Findings without items (receipts, snapshots) still have an action.
        let itemless = allSelected.filter { $0.items.isEmpty }.map { ($0, FindingItem(path: "", size: 0, modified: nil)) }

        for (finding, item) in work + itemless {
            if let app = finding.quitFirst.first(where: running.contains) {
                outcome.skipped.append("\(finding.title): \(appName(app)) is still running")
                continue
            }
            if !item.path.isEmpty {
                guard policy.check(item.path) == .allowed, DiskIO.exists(item.path) else {
                    outcome.skipped.append("\(item.path): no longer there or not allowed")
                    continue
                }
            }
            switch finding.action {
            case .reportOnly:
                continue

            case .trash, .gitWorktree:
                if case .gitWorktree(let repo) = finding.action { worktreeRepos.insert(repo) }
                if canMoveWithoutAdmin(item.path) {
                    if let entry = await recycle(item, finding: finding, session: session) {
                        outcome.entries.append(entry); outcome.movedBytes += item.size
                    } else {
                        outcome.failures.append("Couldn't move \(item.path) to the Trash")
                    }
                } else {
                    let dest = uniqueTrashPath(for: item.path, home: home)
                    var st = stat(); lstat(item.path, &st)
                    adminOps.append(.moveToTrash(source: item.path, destination: dest, uid: uid, gid: gid))
                    adminEntries.append(entry(finding, item, session: session, trash: dest, admin: true,
                                              owner: (st.st_uid, st.st_gid)))
                }

            case .command(let argv, let fallback):
                if finding.needsAdmin, argv.first == "tmutil", argv.count == 3 {
                    adminOps.append(.deleteLocalSnapshot(date: argv[2]))
                    adminEntries.append(commandEntry(finding, argv, session: session))
                    continue
                }
                // Run each tool command once, not once per item (even if it failed).
                guard attemptedCommands.insert(argv.joined(separator: " ")).inserted else { continue }
                if Command.locate(argv[0]) != nil {
                    if isDryRun { log.info("DRY RUN: would run \(argv.joined(separator: " "))"); continue }
                    let result = await DiskIO.run { Command.run(argv[0], Array(argv.dropFirst()), timeout: 900) }
                    if result.ok {
                        outcome.entries.append(commandEntry(finding, argv, session: session))
                        outcome.movedBytes += finding.size
                    } else {
                        outcome.failures.append("\(argv.joined(separator: " ")) failed: \(result.output.prefix(200))")
                    }
                } else if fallback, let entry = await recycle(item, finding: finding, session: session) {
                    outcome.entries.append(entry); outcome.movedBytes += item.size
                }

            case .launchItem(let label, let domain):
                if domain == "system" {
                    adminOps.append(.bootoutSystem(label: label))
                } else if !isDryRun {
                    _ = await DiskIO.run { Command.run("launchctl", ["bootout", "\(domain)/\(label)"], timeout: 20) }
                }
                if canMoveWithoutAdmin(item.path) {
                    if let e = await recycle(item, finding: finding, session: session) { outcome.entries.append(e) }
                } else {
                    let dest = uniqueTrashPath(for: item.path, home: home)
                    var st = stat(); lstat(item.path, &st)
                    adminOps.append(.moveToTrash(source: item.path, destination: dest, uid: uid, gid: gid))
                    adminEntries.append(entry(finding, item, session: session, trash: dest, admin: true,
                                              owner: (st.st_uid, st.st_gid)))
                }

            case .forgetReceipt(let id):
                adminOps.append(.forgetReceipt(packageID: id))
                adminEntries.append(commandEntry(finding, ["pkgutil", "--forget", id], session: session))
            }
        }

        // One password prompt for every system item.
        if !adminOps.isEmpty {
            if isDryRun {
                log.info("DRY RUN: would run \(adminOps.count) admin operation(s)")
            } else if let failure = await DiskIO.run({ [adminOps] in AdminRunner.run(adminOps) }) {
                outcome.failures.append("System items: \(failure.message)")
                // Keep the entries that did make it (moved items exist in the Trash).
                adminEntries = adminEntries.filter { $0.trashPath.map(DiskIO.exists) ?? false }
            }
            if !isDryRun {
                outcome.entries += adminEntries
                outcome.movedBytes += adminEntries.reduce(0) { $0 + $1.size }
            }
        }

        // Moving a worktree folder leaves stale metadata in its repository.
        if !isDryRun {
            for repo in worktreeRepos where DiskIO.isDirectory(repo) {
                _ = await DiskIO.run { Command.run("git", ["-C", repo, "worktree", "prune"], timeout: 30) }
            }
        }

        history.append(outcome.entries)
        log.info("Cleaner: moved \(outcome.movedBytes) bytes, \(outcome.failures.count) failure(s), \(outcome.skipped.count) skipped")
        return outcome
    }

    // MARK: Undo

    /// Move items back from the Trash to where they were.
    static func restore(_ entries: [HistoryEntry], history: CleanerHistory) async -> [String] {
        var failures: [String] = []
        var adminOps: [AdminRunner.Operation] = []
        var adminEntries: [HistoryEntry] = []
        for var e in entries where e.state == .inTrash {
            guard let trash = e.trashPath, DiskIO.exists(trash) else { failures.append("\(e.title): no longer in the Trash"); continue }
            guard !DiskIO.exists(e.originalPath) else { failures.append("\(e.originalPath) already exists"); continue }
            if e.needsAdmin {
                adminOps.append(.restore(trashPath: trash, original: e.originalPath,
                                         uid: e.originalOwner ?? 0, gid: e.originalGroup ?? 0))
                adminEntries.append(e)
                continue
            }
            do {
                try FileManager.default.createDirectory(atPath: (e.originalPath as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                try FileManager.default.moveItem(atPath: trash, toPath: e.originalPath)
                e.state = .restored
                history.update(e)
            } catch {
                failures.append("\(e.title): \(error.localizedDescription)")
            }
        }
        if !adminOps.isEmpty && confirmSystemRestore(adminEntries) {
            if let failure = await DiskIO.run({ [adminOps] in AdminRunner.run(adminOps) }) { failures.append(failure.message) }
            for var e in adminEntries where DiskIO.exists(e.originalPath) { e.state = .restored; history.update(e) }
        }
        return failures
    }

    /// Permanently delete only the given items, and only if they are still in
    /// the Trash — the rest of your Trash is never touched.
    static func emptyFromTrash(_ entries: [HistoryEntry], history: CleanerHistory) async -> Int64 {
        let trashRoot = NSHomeDirectory() + "/.Trash"
        var freed: Int64 = 0
        for var e in entries where e.state == .inTrash {
            guard let t = e.trashPath, SafetyPolicy.isInside(t, trashRoot), DiskIO.exists(t) else { continue }
            if isDryRun { log.info("DRY RUN: would delete \(t)"); continue }
            let ok = await DiskIO.run { (try? FileManager.default.removeItem(atPath: t)) != nil }
            if ok { e.state = .emptied; history.update(e); freed += e.size }
        }
        return freed
    }

    /// Putting items back into system folders runs as root, so show exactly
    /// where each one goes before macOS asks for the password.
    private static func confirmSystemRestore(_ entries: [HistoryEntry]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Put back \(entries.count) system item(s)?"
        alert.informativeText = "These go back into system folders and need your admin password:\n\n"
            + entries.prefix(8).map(\.originalPath).joined(separator: "\n")
            + (entries.count > 8 ? "\n…and \(entries.count - 8) more" : "")
        alert.addButton(withTitle: "Put Back")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Helpers

    private static func recycle(_ item: FindingItem, finding: Finding, session: UUID) async -> HistoryEntry? {
        if isDryRun {
            log.info("DRY RUN: would move \(item.path) to the Trash")
            return nil
        }
        let url = URL(fileURLWithPath: item.path)
        do {
            let moved = try await NSWorkspace.shared.recycle([url])
            let trashURL = moved[url] ?? moved.values.first
            return entry(finding, item, session: session, trash: trashURL?.path, admin: false, owner: nil)
        } catch {
            log.error("recycle failed for \(item.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Renaming needs write access to the parent (and to a folder itself, to
    /// update its ".." entry).
    private static func canMoveWithoutAdmin(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        guard access(parent, W_OK) == 0 else { return false }
        return !DiskIO.isDirectory(path) || access(path, W_OK) == 0
    }

    private static func uniqueTrashPath(for path: String, home: String) -> String {
        let name = (path as NSString).lastPathComponent
        var dest = home + "/.Trash/" + name
        if DiskIO.exists(dest) {
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: ".")
            dest = home + "/.Trash/\(name) \(stamp)"
        }
        return dest
    }

    private static func entry(_ f: Finding, _ item: FindingItem, session: UUID, trash: String?, admin: Bool,
                              owner: (uid_t, gid_t)?) -> HistoryEntry {
        HistoryEntry(id: UUID(), session: session, date: Date(), title: f.title, category: f.category,
                     originalPath: item.path, trashPath: trash, size: item.size, needsAdmin: admin,
                     originalOwner: owner.map { UInt32($0.0) }, originalGroup: owner.map { UInt32($0.1) },
                     command: nil, state: .inTrash)
    }

    private static func commandEntry(_ f: Finding, _ argv: [String], session: UUID) -> HistoryEntry {
        HistoryEntry(id: UUID(), session: session, date: Date(), title: f.title, category: f.category,
                     originalPath: f.items.first?.path ?? "", trashPath: nil, size: f.size, needsAdmin: f.needsAdmin,
                     originalOwner: nil, originalGroup: nil, command: argv.joined(separator: " "), state: .ran)
    }

    private static func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.localizedName ?? bundleID
    }

    nonisolated static func userVarFolder() -> String? { DiskIO.userVarFolder() }
}

/// Quits apps politely before their files are moved.
@MainActor
enum RunningApps {
    static func isRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Ask the apps to quit (they can save documents) and wait up to 10 s.
    /// Returns the bundle IDs still running.
    static func quit(_ bundleIDs: [String]) async -> [String] {
        for app in NSWorkspace.shared.runningApplications where bundleIDs.contains(app.bundleIdentifier ?? "") {
            app.terminate()
        }
        for _ in 0..<50 {
            if !bundleIDs.contains(where: isRunning) { return [] }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return bundleIDs.filter(isRunning)
    }
}
