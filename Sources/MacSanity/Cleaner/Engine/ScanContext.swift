import Foundation
import MacSanityCore

/// Everything a detector needs, captured once per scan.
struct ScanContext: Sendable {
    let home: String
    let uid: uid_t
    /// Real path of the per-user `/private/var/folders/xx/…/0` directory.
    let userVarFolder: String?
    let policy: SafetyPolicy
    let inventory: AppInventory
    let running: RunningState
    let osVersion: [Int]
    let now: Date
    let fullDiskAccess: Bool
    let cancel: CancelFlag
    let homeWalk: HomeWalk

    func days(since date: Date?) -> Double {
        guard let date else { return .infinity }
        return max(0, now.timeIntervalSince(date) / 86_400)
    }

    /// Passes the safety policy and isn't a symlink pretending to be a folder.
    func isRemovable(_ path: String) -> Bool {
        policy.check(path) == .allowed
    }

    /// The installed app that owns a bundle ID or name, for icons and titles.
    func app(forBundleID id: String) -> AppRecord? {
        let lower = id.lowercased()
        return inventory.apps.first { $0.bundleID.lowercased() == lower }
            ?? inventory.apps.first { lower.hasPrefix($0.bundleID.lowercased() + ".") }
    }

    /// The app a folder name belongs to: exact match on any of its names
    /// (VS Code's data folder is "Code"), then name variants ("Claude-3p").
    func app(named name: String) -> AppRecord? {
        let n = OrphanMatcher.normalize(name)
        guard !n.isEmpty else { return nil }
        let apps = inventory.apps.filter { !$0.path.hasPrefix("/System/") }
        if let exact = apps.first(where: { $0.names.contains { OrphanMatcher.normalize($0) == n } }) { return exact }
        return apps.first { app in
            app.names.map(OrphanMatcher.normalize).contains { an in
                an.count >= 4 && n.count >= 4 && (n.hasPrefix(an) || an.hasPrefix(n))
            }
        }
    }

    /// A context without inventory or walks, for detectors that only query tools.
    static func minimal(cancel: CancelFlag) -> ScanContext {
        let home = NSHomeDirectory()
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return ScanContext(home: home, uid: getuid(), userVarFolder: DiskIO.userVarFolder(),
                           policy: SafetyPolicy(home: home, userVarFolder: DiskIO.userVarFolder()),
                           inventory: AppInventory(apps: [], index: AppIndex([]), allBundleIDs: []),
                           running: RunningState(bundleIDs: [], executables: []),
                           osVersion: [v.majorVersion, v.minorVersion, v.patchVersion], now: Date(),
                           fullDiskAccess: FullDiskAccess.isGranted, cancel: cancel, homeWalk: HomeWalk())
    }

    static func make(inventory: AppInventory, running: RunningState, cancel: CancelFlag) async -> ScanContext {
        let home = NSHomeDirectory()
        let realVar = DiskIO.userVarFolder()
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let policy = SafetyPolicy(home: home, userVarFolder: realVar)
        let walk = await HomeWalk.run(home: home, cancel: cancel)
        return ScanContext(home: home, uid: getuid(), userVarFolder: realVar, policy: policy,
                           inventory: inventory, running: running,
                           osVersion: [v.majorVersion, v.minorVersion, v.patchVersion],
                           now: Date(), fullDiskAccess: FullDiskAccess.isGranted, cancel: cancel, homeWalk: walk)
    }
}

/// Detectors are independent, run concurrently, and only read.
protocol Detector: Sendable {
    var category: CleanerCategory { get }
    func scan(_ context: ScanContext) async -> [Finding]
}

/// One metadata-only pass over the home folder (hidden folders included —
/// Spotlight skips those) that finds project roots and linked git worktrees.
/// Never descends into Library, the Trash, or known artifact/cache folders.
struct HomeWalk: Sendable {
    struct Project: Sendable, Hashable {
        let path: String
        let kinds: [String]   // Catalog.ProjectKind names
        let hasGit: Bool
    }

    var projects: [Project] = []
    /// Folders containing a `.git` *file* (linked worktrees).
    var worktrees: [String] = []

    static let maxDepth = 8

    static func run(home: String, cancel: CancelFlag) async -> HomeWalk {
        await DiskIO.run {
            var walk = HomeWalk()
            let markers: [String: [String]] = Catalog.projectKinds.reduce(into: [:]) { map, kind in
                for m in kind.markers { map[m, default: []].append(kind.name) }
            }
            let fm = FileManager.default
            var stack: [(String, Int)] = [(home, 0)]
            while let (dir, depth) = stack.popLast(), !cancel.isCancelled {
                guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                var kinds: [String] = []
                var gitIsFile = false, gitIsDir = false
                var subdirs: [String] = []
                for name in names {
                    let path = dir + "/" + name
                    if name == ".git" {
                        if DiskIO.isDirectory(path) { gitIsDir = true } else { gitIsFile = true }
                        continue
                    }
                    if let k = markers[name] { kinds.append(contentsOf: k) }
                    if name.hasSuffix(".xcodeproj") { kinds.append("Xcode") }
                    if depth < maxDepth, !Catalog.projectWalkSkips.contains(name),
                       !(depth == 0 && name == "Library"), DiskIO.isDirectory(path) {
                        subdirs.append(path)
                    }
                }
                if gitIsFile { walk.worktrees.append(dir) }
                if !kinds.isEmpty {
                    walk.projects.append(Project(path: dir, kinds: Array(Set(kinds)).sorted(), hasGit: gitIsDir || gitIsFile))
                }
                for s in subdirs { stack.append((s, depth + 1)) }
            }
            return walk
        }
    }
}

/// Finds every file an app keeps outside its bundle — used by Unused Apps, the
/// uninstaller and the leftover search. Matches by bundle ID (exact or as a
/// prefix of helper IDs) and, for name-named folders, by exact app name.
enum RelatedFiles {
    static func libraryRoots(home: String) -> [String] {
        let lib = home + "/Library"
        return [lib + "/Application Support", lib + "/Caches", lib + "/Containers", lib + "/Group Containers",
                lib + "/Preferences", lib + "/Saved Application State", lib + "/HTTPStorages", lib + "/WebKit",
                lib + "/Logs", lib + "/Cookies", lib + "/LaunchAgents", lib + "/Application Scripts",
                "/Library/Application Support", "/Library/Caches", "/Library/Logs", "/Library/LaunchAgents",
                "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools"]
    }

    /// Paths related to an app. `terms` are bundle IDs and names; matching is
    /// case-insensitive on the entry name with plist/savedState suffixes stripped.
    /// `containing`: also match any entry whose normalized name contains this
    /// term (for the free-text leftover search: "spotify" finds "com.spotify.client").
    static func find(bundleIDs: [String], names: [String], teamID: String? = nil, containing: String? = nil,
                     home: String) -> [String] {
        let term = containing.map(OrphanMatcher.normalize).flatMap { $0.count >= 3 ? $0 : nil }
        let ids = bundleIDs.map { $0.lowercased() }
        let normNames = Set(names.map(OrphanMatcher.normalize).filter { $0.count >= 3 })
        var result: [String] = []
        for root in libraryRoots(home: home) {
            for path in DiskIO.children(of: root) {
                let raw = (path as NSString).lastPathComponent
                var name = raw.lowercased()
                for suffix in [".plist", ".savedstate", ".binarycookies"] where name.hasSuffix(suffix) {
                    name.removeLast(suffix.count)
                }
                let byID = ids.contains { name == $0 || name.hasPrefix($0 + ".") || name.hasSuffix("." + $0) }
                let byName = normNames.contains(OrphanMatcher.normalize(name))
                var byContainer = false
                if root.hasSuffix("/Containers"), let meta = containerIdentifier(path)?.lowercased() {
                    byContainer = ids.contains { meta == $0 || meta.hasPrefix($0 + ".") }
                }
                let byTerm = term.map { OrphanMatcher.normalize(name).contains($0) } ?? false
                if byID || byName || byContainer || byTerm { result.append(path) }
            }
        }
        return result
    }

    /// The bundle ID a sandbox container belongs to.
    static func containerIdentifier(_ containerPath: String) -> String? {
        let meta = containerPath + "/.com.apple.containermanagerd.metadata.plist"
        guard let dict = NSDictionary(contentsOfFile: meta) as? [String: Any] else { return nil }
        return dict["MCMMetadataIdentifier"] as? String
    }
}
