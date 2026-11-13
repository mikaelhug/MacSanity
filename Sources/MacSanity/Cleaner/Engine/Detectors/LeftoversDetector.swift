import Foundation
import MacSanityCore

/// Files left behind by apps that are no longer installed, grouped per removed
/// app ("OpenCode — not installed: 207 MB in 4 places"). Uses `OrphanMatcher`,
/// which errs on the side of "owned": internal names, name variants, vendor
/// folders, helpers, Apple's and tools' folders, and anything recently written
/// are never suggested.
struct LeftoversDetector: Detector {
    let category = CleanerCategory.leftovers

    private struct Hit {
        let path: String
        let hint: String
        let confidence: Ownership.Confidence
        let location: LibraryLocation
    }

    func scan(_ ctx: ScanContext) async -> [Finding] {
        let lib = ctx.home + "/Library"
        var roots: [(String, LibraryLocation)] = [
            (lib + "/Application Support", .named), (lib + "/Caches", .named), (lib + "/Logs", .named),
            (lib + "/HTTPStorages", .named), (lib + "/WebKit", .named), (lib + "/Cookies", .named),
            (lib + "/Application Scripts", .named), (lib + "/Containers", .container),
            (lib + "/Group Containers", .groupContainer), (lib + "/Preferences", .preferences),
            (lib + "/Saved Application State", .savedState),
            ("/Library/Application Support", .named), ("/Library/Caches", .named),
        ]
        if let v = ctx.userVarFolder { roots.append((v + "/C", .named)) }

        // Candidates first (cheap), then size them all at once.
        var candidates: [(path: String, name: String, location: LibraryLocation, identifier: String?)] = []
        for (root, location) in roots {
            for path in DiskIO.children(of: root) where !DiskIO.isSymlink(path) && ctx.isRemovable(path) {
                let name = (path as NSString).lastPathComponent
                if name.hasPrefix(".") { continue }
                let identifier = location == .container ? RelatedFiles.containerIdentifier(path) : nil
                candidates.append((path, name, location, identifier))
            }
        }
        // Hidden folders in the home folder belonging to removed apps.
        for path in DiskIO.children(of: ctx.home) where DiskIO.isDirectory(path) && !DiskIO.isSymlink(path) {
            let name = (path as NSString).lastPathComponent
            guard name.hasPrefix("."), name.count > 2, ctx.isRemovable(path) else { continue }
            candidates.append((path, name, .homeDotFolder, nil))
        }

        // Quick ownership pass using the folder's own mtime; only possible
        // orphans get the (expensive) deep size and newest-change walk.
        let possible = candidates.filter { c in
            let quick = OrphanMatcher.classify(name: c.name, location: c.location, identifier: c.identifier,
                                               modifiedDaysAgo: 365, index: ctx.inventory.index)
            if case .orphan = quick { return true }
            return false
        }
        let sizes = await DiskIO.sizes(possible.map(\.path), cancel: ctx.cancel)

        var hits: [Hit] = []
        for c in possible {
            guard let size = sizes[c.path] else { continue }
            let days = ctx.days(since: size.newest ?? DiskIO.modified(c.path))
            let verdict = OrphanMatcher.classify(name: c.name, location: c.location, identifier: c.identifier,
                                                 modifiedDaysAgo: days, index: ctx.inventory.index)
            if case .orphan(let confidence, let hint) = verdict {
                // Tiny uncertain matches are noise; exact-identifier ones (prefs,
                // saved state) are small by nature but certain, so keep them.
                if confidence < .high && size.allocated < 100_000 { continue }
                hits.append(Hit(path: c.path, hint: hint, confidence: confidence, location: c.location))
            }
        }

        // Group per removed app (normalized hint).
        let grouped = Dictionary(grouping: hits) { OrphanMatcher.normalize($0.hint) }
        return grouped.compactMap { key, hits in
            let items = hits.compactMap { h in sizes[h.path].map { FindingItem(path: h.path, size: $0.allocated, modified: $0.newest) } }
            guard !items.isEmpty else { return nil }
            let best = hits.map(\.confidence).max() ?? .low
            let safety: Safety = best == .high ? .safe : best == .medium ? .review : .careful
            let display = Self.displayName(hits.map(\.hint))
            let places = items.count == 1 ? "1 place" : "\(items.count) places"
            let lastUsed = items.compactMap(\.modified).max()
            let identifiers = Set(items.map { Self.identifier(($0.path as NSString).lastPathComponent) }).sorted()
            let identifierText = identifiers.prefix(2).joined(separator: ", ") + (identifiers.count > 2 ? "…" : "")
            return Finding(
                id: Finding.makeID(category, key), category: category,
                title: display,
                reason: (best == .low ? "Possibly from a removed app" : "App removed") + " · \(places)",
                afterRemoval: "The app's settings and data are gone. Reinstalling it starts fresh.",
                safety: safety, items: items.sorted { $0.size > $1.size },
                group: best == .low ? "Uncertain matches" : "Removed apps",
                lastUsed: lastUsed, action: .trash,
                needsAdmin: items.contains { DiskIO.ownerUID($0.path) != ctx.uid },
                details: (best == .high ? "No installed app has this identifier: "
                          : best == .medium ? "No installed app matches: " : "Name match only (uncertain): ") + identifierText)
        }
    }

    static func identifier(_ name: String) -> String {
        var n = name
        for suffix in [".plist", ".savedState", ".binarycookies"] where n.hasSuffix(suffix) { n.removeLast(suffix.count) }
        return n
    }

    static func displayName(_ hints: [String]) -> String {
        let name = hints.min { $0.count < $1.count } ?? "Unknown app"
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
