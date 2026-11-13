import Foundation
import MacSanityCore

/// Apps you haven't opened in six months or more, shown with everything they
/// keep on disk — removing one is a complete uninstall.
struct UnusedAppsDetector: Detector {
    let category = CleanerCategory.unusedApps

    func scan(_ ctx: ScanContext) async -> [Finding] {
        let selfID = Bundle.main.bundleIdentifier ?? "com.macsanity.app"
        let candidates = ctx.inventory.apps.filter { app in
            !app.isApple && app.bundleID != selfID
                && (app.path.hasPrefix("/Applications/") || app.path.hasPrefix(ctx.home + "/Applications/"))
                && !(app.path as NSString).lastPathComponent.hasPrefix("Install macOS")
                && ctx.isRemovable(app.path)
                && ctx.days(since: app.lastUsed ?? DiskIO.modified(app.path)) >= Policies.unusedAppDays
        }
        var findings: [Finding] = []
        for app in candidates {
            let related = await DiskIO.run {
                RelatedFiles.find(bundleIDs: [app.bundleID], names: [app.name], home: ctx.home)
            }.filter(ctx.isRemovable)
            let paths = [app.path] + related
            let sizes = await DiskIO.sizes(paths, cancel: ctx.cancel)
            let items = paths.compactMap { p in sizes[p].map { FindingItem(path: p, size: $0.allocated, modified: $0.newest) } }
            let days = ctx.days(since: app.lastUsed)
            let usage = app.lastUsed == nil ? "Never opened" : "Not opened in \(RelativeTime.describe(days: days))"
            findings.append(Finding(
                id: Finding.makeID(category, app.bundleID), category: category, title: app.name,
                reason: related.isEmpty ? usage : "\(usage) · \(related.count + 1) items",
                afterRemoval: "The app and its settings and data are removed. Reinstall it to use it again.",
                safety: .review, items: items, group: "Applications", lastUsed: app.lastUsed,
                iconPath: app.path, action: .trash, quitFirst: [app.bundleID],
                needsAdmin: !FileManager.default.isWritableFile(atPath: (app.path as NSString).deletingLastPathComponent)
                    || DiskIO.ownerUID(app.path) != ctx.uid))
        }
        return findings
    }
}
