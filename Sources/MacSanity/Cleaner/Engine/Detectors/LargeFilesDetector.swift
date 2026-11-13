import Foundation
import MacSanityCore

/// Your own big files (database dumps, VM and disk images, videos), old
/// downloads, and iOS backups. Built from the Disk Map walk, so files in hidden
/// folders are included. These are user files: never preselected.
enum LargeFilesDetector {
    static let category = CleanerCategory.largeFiles

    static func findings(map: DiskNode, ctx: ScanContext) async -> [Finding] {
        var findings: [Finding] = []
        let homeNode = map.node(at: ctx.home)

        // 1. Large files anywhere in your home folder.
        for file in homeNode?.largeFiles(minSize: Policies.largeFileBytes) ?? []
        where ctx.isRemovable(file.path) && !file.path.contains(".app/") {
            let days = ctx.days(since: file.newest)
            let folder = (file.path as NSString).deletingLastPathComponent
            findings.append(Finding(
                id: Finding.makeID(category, file.path), category: category, title: file.name,
                reason: abbreviate(folder, home: ctx.home),
                afterRemoval: "The file goes to the Trash. Make sure you don't need it (or have a copy).",
                safety: days < 30 ? .careful : .review,
                items: [FindingItem(path: file.path, size: file.size, modified: file.newest)],
                group: "Large files", lastUsed: file.newest, action: .trash))
        }

        // 2. Old items in Downloads.
        let downloads = DiskIO.children(of: ctx.home + "/Downloads").filter {
            ctx.days(since: DiskIO.modified($0)) >= Policies.oldDownloadDays && ctx.isRemovable($0)
        }
        let sizes = await DiskIO.sizes(downloads, cancel: ctx.cancel)
        for path in downloads {
            guard let s = sizes[path], s.allocated >= 10_000_000 else { continue }
            let days = ctx.days(since: DiskIO.modified(path))
            findings.append(Finding(
                id: Finding.makeID(category, path), category: category, title: (path as NSString).lastPathComponent,
                reason: "\(RelativeTime.describe(days: days)) old",
                afterRemoval: "The download goes to the Trash.", safety: .review,
                items: [FindingItem(path: path, size: s.allocated, modified: s.newest)],
                group: "Old downloads", lastUsed: DiskIO.modified(path), action: .trash))
        }

        // 3. iOS / iPadOS device backups (Full Disk Access required).
        let backups = DiskIO.children(of: ctx.home + "/Library/Application Support/MobileSync/Backup").filter(ctx.isRemovable)
        let backupSizes = await DiskIO.sizes(backups, cancel: ctx.cancel)
        for path in backups {
            guard let s = backupSizes[path] else { continue }
            let info = NSDictionary(contentsOfFile: path + "/Info.plist") as? [String: Any]
            let device = info?["Device Name"] as? String ?? "Device"
            let date = info?["Last Backup Date"] as? Date ?? s.newest
            findings.append(Finding(
                id: Finding.makeID(category, path), category: category, title: "\(device) backup",
                reason: date.map { "Backup from \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Device backup",
                afterRemoval: "You can't restore the device from this backup any more.", safety: .careful,
                items: [FindingItem(path: path, size: s.allocated, modified: s.newest)],
                group: "Device backups", lastUsed: date, action: .trash))
        }

        // 4. The Trash itself (report only — emptying it is your call).
        let trash = await DiskIO.size(ctx.home + "/.Trash")
        if trash.allocated >= 50_000_000 {
            findings.append(Finding(
                id: Finding.makeID(category, "trash"), category: category, title: "Trash",
                reason: "Still uses disk space",
                afterRemoval: "", safety: .review,
                items: [FindingItem(path: ctx.home + "/.Trash", size: trash.allocated, modified: trash.newest)],
                group: "Trash", lastUsed: trash.newest, action: .reportOnly(hint: "Empty the Trash in Finder to free it.")))
        }
        return findings
    }

    static func abbreviate(_ path: String, home: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
