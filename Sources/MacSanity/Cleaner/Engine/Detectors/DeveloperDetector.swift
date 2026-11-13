import Foundation
import MacSanityCore

/// Caches of developer tools and package managers, from the declarative
/// `Catalog.developer` — every entry explains what it is and what happens after.
struct DeveloperDetector: Detector {
    let category = CleanerCategory.developer

    func scan(_ ctx: ScanContext) async -> [Finding] {
        var expanded: [(entry: CatalogEntry, paths: [String])] = []
        for entry in Catalog.developer {
            var paths = entry.paths.flatMap { DiskIO.expand($0, home: ctx.home) }.filter { !DiskIO.isSymlink($0) }
            if entry.onlyOldVersions {
                // Group per parent folder so "iOS DeviceSupport" and "watchOS DeviceSupport" don't mix.
                let byParent = Dictionary(grouping: paths) { ($0 as NSString).deletingLastPathComponent }
                paths = byParent.flatMap { _, siblings in
                    let old = VersionedSiblings.superseded(siblings.map { ($0 as NSString).lastPathComponent })
                    return siblings.filter { old.contains(($0 as NSString).lastPathComponent) }
                }
            }
            if entry.id == "simulator.unavailable" {
                paths = await DiskIO.run { Self.unavailableSimulators(home: ctx.home) }
            }
            if case .reportOnly = entry.action {} else { paths = paths.filter(ctx.isRemovable) }
            if !paths.isEmpty { expanded.append((entry, paths.sorted())) }
        }

        let sizes = await DiskIO.sizes(expanded.flatMap(\.paths), cancel: ctx.cancel)
        return expanded.compactMap { entry, paths in
            let items = paths.compactMap { p -> FindingItem? in
                guard let s = sizes[p], s.allocated > 0 else { return nil }
                return FindingItem(path: p, size: s.allocated, modified: s.newest)
            }
            let total = items.reduce(0) { $0 + $1.size }
            guard total >= 1_000_000 else { return nil }
            let action: RemovalAction
            var reason = ""
            switch entry.action {
            case .trash: action = .trash
            case .command(let argv, let fallback): action = .command(argv, fallbackToTrash: fallback)
            case .reportOnly(let hint): action = .reportOnly(hint: hint)
            }
            if entry.onlyOldVersions {
                reason = "Older versions"
            }
            return Finding(
                id: Finding.makeID(category, entry.id), category: category, title: entry.title,
                reason: reason, afterRemoval: entry.afterRemoval, safety: entry.safety, items: items,
                group: Self.group(for: entry.id), lastUsed: items.compactMap(\.modified).max(),
                action: action, quitFirst: entry.quitFirst, blockingProcesses: entry.blockingProcesses,
                details: entry.explanation)
        }
    }

    static func group(for id: String) -> String {
        switch id.split(separator: ".").first.map(String.init) ?? id {
        case "xcode", "simulator", "swiftpm", "cocoapods", "carthage": "Apple development"
        case "go": "Go"
        case "npm", "yarn", "pnpm", "bun", "node-gyp", "typescript", "playwright": "JavaScript"
        case "pip", "uv", "poetry", "conda", "huggingface", "pre-commit": "Python"
        case "cargo", "rustup": "Rust"
        case "gradle", "maven": "Java"
        default: "Other tools"
        }
    }

    /// Device folders of simulators whose runtime is gone (`simctl` JSON).
    static func unavailableSimulators(home: String) -> [String] {
        let r = Command.run("xcrun", ["simctl", "list", "devices", "unavailable", "-j"], timeout: 20)
        guard r.ok, let data = r.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else { return [] }
        let root = home + "/Library/Developer/CoreSimulator/Devices/"
        return devices.values.flatMap { $0 }.compactMap { $0["udid"] as? String }.map { root + $0 }.filter(DiskIO.exists)
    }
}
