import CMacSanityFS
import Foundation

/// One folder or file in the Disk Map. Only nodes above the map's threshold are
/// kept; everything smaller is folded into `otherSize` of its parent.
struct DiskNode: Sendable, Identifiable, Hashable {
    var id: String { path }
    let name: String
    /// User-facing path ("/Users/…", "/private/tmp"), not the Data-volume path.
    let path: String
    let size: Int64
    let isDirectory: Bool
    let newest: Date?
    var children: [DiskNode]
    /// Folders below this node that couldn't be read (no Full Disk Access).
    let unreadable: Int

    /// Bytes not represented by listed children (small items).
    var otherSize: Int64 { max(0, size - children.reduce(0) { $0 + $1.size }) }

    func node(at path: String) -> DiskNode? {
        if path == self.path { return self }
        guard path.hasPrefix(self.path == "/" ? "/" : self.path + "/") else { return nil }
        for c in children { if let n = c.node(at: path) { return n } }
        return nil
    }

    /// Every file node at or above `minSize` in this subtree.
    func largeFiles(minSize: Int64) -> [DiskNode] {
        if !isDirectory { return size >= minSize ? [self] : [] }
        return children.flatMap { $0.largeFiles(minSize: minSize) }
    }
}

/// How the whole disk is used, so the numbers add up to what Finder shows.
struct VolumeSummary: Sendable {
    struct Part: Sendable, Identifiable {
        var id: String { name }
        let name: String
        let bytes: Int64
        let explanation: String
    }
    let total: Int64
    let available: Int64
    /// Free space including what macOS can purge on demand.
    let availableForImportantUsage: Int64
    /// Other APFS volumes in the same container (System, Preboot, VM, Recovery…).
    let otherVolumes: [Part]
    let dataVolumeUsed: Int64
}

enum DiskMap {
    /// Nodes smaller than this are folded into their parent.
    static let threshold: Int64 = 50_000_000
    static let dataRoot = "/System/Volumes/Data"

    /// Walk the Data volume. Big levels are split into parallel walks
    /// (top level, /Users, your home folder) for speed.
    /// `progress` receives the bytes of each finished part of the walk.
    static func build(home: String, cancel: CancelFlag, progress: @escaping @Sendable (Int64) -> Void) async -> DiskNode {
        let homeOnData = dataRoot + home
        // Split big levels into parallel walks: the top of the volume, your home
        // folder and its folders, and the temp areas that hold big trees.
        var split: Set<String> = [dataRoot, dataRoot + "/Users", homeOnData, dataRoot + "/private",
                                  dataRoot + "/private/var", dataRoot + "/private/tmp", dataRoot + "/private/var/folders",
                                  homeOnData + "/Library"]
        for child in DiskIO.children(of: homeOnData) where DiskIO.isDirectory(child) && !DiskIO.isSymlink(child) {
            split.insert(child)
        }
        return await walk(dataRoot, name: "Macintosh HD", split: split, cancel: cancel, progress: progress)
    }

    private static func walk(_ path: String, name: String, split: Set<String>, cancel: CancelFlag,
                             progress: @escaping @Sendable (Int64) -> Void) async -> DiskNode {
        if split.contains(path) {
            let children = DiskIO.children(of: path)
            let nodes = await withTaskGroup(of: DiskNode.self) { group in
                for child in children {
                    group.addTask { await walk(child, name: (child as NSString).lastPathComponent, split: split,
                                               cancel: cancel, progress: progress) }
                }
                var all: [DiskNode] = []
                for await n in group { all.append(n) }
                return all
            }
            let size = nodes.reduce(0) { $0 + $1.size }
            return DiskNode(name: name, path: displayPath(path), size: size, isDirectory: true,
                            newest: nodes.compactMap(\.newest).max(),
                            children: nodes.filter { $0.size >= threshold }.sorted { $0.size > $1.size },
                            unreadable: nodes.reduce(0) { $0 + $1.unreadable })
        }
        let node = await DiskIO.run { walkTree(path, cancel: cancel) }
        progress(node.size)
        return node
    }

    /// One recursive C walk, rebuilding the tree from post-order callbacks.
    private static func walkTree(_ path: String, cancel: CancelFlag) -> DiskNode {
        let builder = TreeBuilder()
        var out = MSTreeSize()
        let context = Unmanaged.passUnretained(builder).toOpaque()
        _ = MSWalkTree(path, UInt64(threshold), { ctx, depth, name, isDir, size in
            guard let ctx else { return }
            Unmanaged<TreeBuilder>.fromOpaque(ctx).takeUnretainedValue()
                .add(depth: Int(depth), name: String(cString: name), isDirectory: isDir, size: size.pointee)
        }, context, cancel.pointer, &out)
        guard let root = builder.root else {
            // Unreadable or below threshold: a leaf with its totals.
            let s = TreeSize(out)
            return DiskNode(name: (path as NSString).lastPathComponent, path: displayPath(path), size: s.allocated,
                            isDirectory: DiskIO.isDirectory(path), newest: s.newest, children: [], unreadable: s.unreadable)
        }
        return root.resolve(parentPath: (displayPath(path) as NSString).deletingLastPathComponent)
    }

    /// Bytes in use on the Data volume (what the walk will roughly add up to).
    static func dataVolumeUsedBytes() -> Int64 {
        var fs = statfs()
        guard statfs(dataRoot, &fs) == 0 else { return 0 }
        return Int64(fs.f_blocks - fs.f_bfree) * Int64(fs.f_bsize)
    }

    static func displayPath(_ dataPath: String) -> String {
        if dataPath == dataRoot { return "/" }
        return dataPath.hasPrefix(dataRoot + "/") ? String(dataPath.dropFirst(dataRoot.count)) : dataPath
    }

    // MARK: Volume summary

    static func volumeSummary() async -> VolumeSummary {
        await DiskIO.run {
            let url = URL(fileURLWithPath: "/")
            let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                           .volumeAvailableCapacityForImportantUsageKey])
            let total = Int64(values?.volumeTotalCapacity ?? 0)
            let available = Int64(values?.volumeAvailableCapacity ?? 0)
            let important = values?.volumeAvailableCapacityForImportantUsage ?? available

            var parts: [VolumeSummary.Part] = []
            var dataUsed: Int64 = 0
            let info = Command.run("diskutil", ["info", "-plist", "/"], timeout: 15)
            let list = Command.run("diskutil", ["apfs", "list", "-plist"], timeout: 15)
            if let infoPlist = plist(info.output), let container = infoPlist["APFSContainerReference"] as? String,
               let listPlist = plist(list.output), let containers = listPlist["Containers"] as? [[String: Any]],
               let mine = containers.first(where: { ($0["ContainerReference"] as? String) == container }),
               let volumes = mine["Volumes"] as? [[String: Any]] {
                for v in volumes {
                    let roles = v["Roles"] as? [String] ?? []
                    let used = (v["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
                    if roles.contains("Data") { dataUsed = used; continue }
                    let name = roles.first ?? (v["Name"] as? String ?? "Volume")
                    parts.append(.init(name: name, bytes: used, explanation: explanation(forRole: name)))
                }
            }
            return VolumeSummary(total: total, available: available, availableForImportantUsage: important,
                                 otherVolumes: parts.sorted { $0.bytes > $1.bytes }, dataVolumeUsed: dataUsed)
        }
    }

    private static func plist(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func explanation(forRole role: String) -> String {
        switch role {
        case "System": "macOS itself (read-only, sealed)"
        case "Preboot": "Boot files and staged updates"
        case "Recovery": "macOS Recovery"
        case "VM": "Virtual memory swap"
        case "Update": "Software update staging"
        default: "Other volume"
        }
    }
}

/// Rebuilds a tree from (depth, node) pairs reported children-first.
private final class TreeBuilder {
    final class Raw {
        let name: String
        let isDirectory: Bool
        let size: MSTreeSize
        var children: [Raw] = []
        init(name: String, isDirectory: Bool, size: MSTreeSize) {
            self.name = name; self.isDirectory = isDirectory; self.size = size
        }

        func resolve(parentPath: String) -> DiskNode {
            let path = parentPath == "/" ? "/" + name : parentPath + "/" + name
            let s = TreeSize(size)
            // Packages (apps, libraries, bundles) are shown as one item, like Finder does.
            let isPackage = [".app", ".photoslibrary", ".musiclibrary", ".bundle", ".framework", ".xcarchive", ".utm"]
                .contains { name.hasSuffix($0) }
            return DiskNode(name: name, path: path, size: s.allocated, isDirectory: isDirectory, newest: s.newest,
                            children: isPackage ? [] : children.map { $0.resolve(parentPath: path) }.sorted { $0.size > $1.size },
                            unreadable: s.unreadable)
        }
    }

    private var pending: [[Raw]] = []
    var root: Raw?

    func add(depth: Int, name: String, isDirectory: Bool, size: MSTreeSize) {
        while pending.count <= depth + 1 { pending.append([]) }
        let node = Raw(name: name, isDirectory: isDirectory, size: size)
        node.children = pending[depth + 1]
        pending[depth + 1] = []
        if depth == 0 { root = node } else { pending[depth].append(node) }
    }
}
