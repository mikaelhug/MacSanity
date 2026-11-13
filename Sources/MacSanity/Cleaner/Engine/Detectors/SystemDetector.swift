import Foundation
import MacSanityCore
import Synchronization

/// System-wide items that need the admin password: installer receipts of apps
/// that are gone, and Time Machine local snapshots.
struct SystemDetector: Detector {
    let category = CleanerCategory.system

    func scan(_ ctx: ScanContext) async -> [Finding] {
        async let receipts = DiskIO.run { Self.orphanedReceipts() }
        async let snapshots = DiskIO.run { Self.localSnapshots() }
        var findings: [Finding] = []

        for (id, app) in await receipts {
            findings.append(Finding(
                id: Finding.makeID(category, "pkg:" + id), category: category, title: id,
                reason: "\(app) removed",
                afterRemoval: "macOS forgets the package; installing it again works normally.",
                safety: .safe, items: [], group: "Installer receipts", lastUsed: nil,
                action: .forgetReceipt(packageID: id), needsAdmin: true))
        }
        for snapshot in await snapshots {
            findings.append(Finding(
                id: Finding.makeID(category, "tm:" + snapshot), category: category, title: snapshot,
                reason: "Local snapshot",
                afterRemoval: "You can't restore from this snapshot any more; backups on your backup disk aren't affected.",
                safety: .review, items: [], group: "Time Machine local snapshots", lastUsed: nil,
                action: .command(["tmutil", "deletelocalsnapshots", Self.snapshotDate(snapshot)], fallbackToTrash: false),
                needsAdmin: true))
        }
        return findings
    }

    /// Non-Apple packages whose installed apps are all gone.
    static func orphanedReceipts() -> [(String, String)] {
        let list = Command.run("pkgutil", ["--pkgs"], timeout: 20)
        guard list.ok else { return [] }
        let ids = list.output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("com.apple.") }
        let results = Mutex<[(String, String)]>([])
        DispatchQueue.concurrentPerform(iterations: ids.count) { i in
            if let r = check(ids[i]) { results.withLock { $0.append(r) } }
        }
        return results.withLock { $0 }.sorted { $0.0 < $1.0 }
    }

    /// (package id, app name) when the package installed an app that's gone.
    private static func check(_ id: String) -> (String, String)? {
        do {
            let info = Command.run("pkgutil", ["--pkg-info-plist", id], timeout: 10)
            guard info.ok, let data = info.output.data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            // "install-location" is relative to the volume ("Applications"), or absolute.
            let volume = (plist["volume"] as? String) ?? "/"
            let rawLocation = (plist["install-location"] as? String) ?? ""
            let location = rawLocation.hasPrefix("/") ? rawLocation : volume + rawLocation
            let files = Command.run("pkgutil", ["--only-dirs", "--files", id], timeout: 20)
            let apps = files.output.split(separator: "\n").map(String.init).filter {
                $0.hasSuffix(".app") && !$0.dropLast(4).contains(".app/")
            }
            guard !apps.isEmpty else { return nil }   // only judge packages that installed an app
            let base = location.hasSuffix("/") ? location : location + "/"
            let paths = apps.map { (base + $0).replacingOccurrences(of: "//", with: "/") }
            return paths.allSatisfy({ !DiskIO.exists($0) }) ? (id, (paths[0] as NSString).lastPathComponent) : nil
        }
    }

    static func localSnapshots() -> [String] {
        let r = Command.run("tmutil", ["listlocalsnapshots", "/"], timeout: 20)
        return r.output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("com.apple.TimeMachine.") }
    }

    /// "com.apple.TimeMachine.2026-11-12-101500.local" → "2026-11-12-101500".
    static func snapshotDate(_ name: String) -> String {
        name.replacingOccurrences(of: "com.apple.TimeMachine.", with: "").replacingOccurrences(of: ".local", with: "")
    }
}
