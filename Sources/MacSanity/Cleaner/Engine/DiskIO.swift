import CMacSanityFS
import Foundation
import Synchronization

/// A cancellation flag the C walker can poll without locks.
final class CancelFlag: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Bool>
    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: false)
    }
    deinit { pointer.deallocate() }
    func cancel() { pointer.pointee = true }
    var isCancelled: Bool { pointer.pointee }
}

/// Size of one walked path.
struct TreeSize: Sendable {
    var allocated: Int64 = 0
    var files: Int64 = 0
    var newest: Date?
    var unreadable: Int = 0

    init() {}
    init(_ s: MSTreeSize) {
        allocated = Int64(clamping: s.allocated)
        files = Int64(clamping: s.files)
        newest = s.newestModification > 0 ? Date(timeIntervalSince1970: TimeInterval(s.newestModification)) : nil
        unreadable = Int(clamping: s.unreadable)
    }
}

/// Runs blocking file-system work off the Swift cooperative pool, on a bounded
/// set of threads, so a scan never starves the app's async work.
enum DiskIO {
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "MacSanity.Cleaner.DiskIO"
        q.maxConcurrentOperationCount = max(4, min(10, ProcessInfo.processInfo.activeProcessorCount - 2))
        q.qualityOfService = .utility
        return q
    }()

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.addOperation { continuation.resume(returning: work()) }
        }
    }

    /// Sizes already measured by this scan's Disk Map walk (every node of 50 MB
    /// or more), so detectors don't walk the same big trees a second time.
    /// Set by the scanner for the duration of a scan, then cleared.
    private static let sizeCache = Mutex<(owner: UUID?, sizes: [String: TreeSize])>((nil, [:]))

    /// Install a scan's sizes. The newest scan owns the cache; an older scan
    /// that finishes late can't overwrite or clear it.
    static func setSizeCache(_ map: DiskNode?, owner: UUID) {
        var index: [String: TreeSize] = [:]
        func visit(_ n: DiskNode) {
            var s = TreeSize()
            s.allocated = n.size
            s.newest = n.newest
            s.unreadable = n.unreadable
            index[n.path] = s
            n.children.forEach(visit)
        }
        if let map { visit(map) }
        sizeCache.withLock { $0 = (owner, index) }
    }

    /// Claim the cache for a new scan (drops whatever an older scan left).
    static func beginSizeCache(owner: UUID) {
        sizeCache.withLock { $0 = (owner, [:]) }
    }

    static func clearSizeCache(owner: UUID) {
        sizeCache.withLock { if $0.owner == owner { $0 = (nil, [:]) } }
    }

    private static func cachedSize(_ path: String) -> TreeSize? {
        sizeCache.withLock { $0.sizes[path] }
    }

    /// Total size of a file or folder (allocated bytes, like `du`). Never follows
    /// symlinks or crosses volumes.
    static func size(_ path: String, cancel: CancelFlag? = nil) async -> TreeSize {
        if let cached = cachedSize(path) { return cached }
        return await run {
            var out = MSTreeSize()
            _ = MSWalkTree(path, .max, nil, nil, cancel?.pointer, &out)
            return TreeSize(out)
        }
    }

    /// Size several paths concurrently; results keyed by path.
    static func sizes(_ paths: [String], cancel: CancelFlag? = nil) async -> [String: TreeSize] {
        await withTaskGroup(of: (String, TreeSize).self) { group in
            for p in paths { group.addTask { (p, await size(p, cancel: cancel)) } }
            var result: [String: TreeSize] = [:]
            for await (p, s) in group { result[p] = s }
            return result
        }
    }

    // MARK: Small helpers (cheap, metadata only)

    /// Real path of the per-user `/private/var/folders/xx/…/0` directory (parent
    /// of `$TMPDIR`), or nil if it can't be determined.
    static func userVarFolder() -> String? {
        let tmp = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath
        guard tmp.hasSuffix("/T") else { return nil }
        let v = (tmp as NSString).deletingLastPathComponent
        return v.hasPrefix("/var/") ? "/private" + v : v
    }

    static func children(of path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).map { path + "/" + $0 }
    }

    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    static func modified(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    static func ownerUID(_ path: String) -> uid_t? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_uid : nil
    }

    /// Expand `~` and `*` wildcards (one `*` per component, matched against
    /// directory listings). Never follows symlinked directories while expanding.
    static func expand(_ pattern: String, home: String) -> [String] {
        let full = pattern.hasPrefix("~") ? home + pattern.dropFirst() : pattern
        var results = ["/"]
        for component in full.split(separator: "/") {
            var next: [String] = []
            for base in results {
                let prefix = base == "/" ? "" : base
                if component.contains("*") {
                    guard isDirectory(base) else { continue }
                    let regex = "^" + NSRegularExpression.escapedPattern(for: String(component))
                        .replacingOccurrences(of: "\\*", with: ".*") + "$"
                    for name in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
                    where name.range(of: regex, options: .regularExpression) != nil {
                        next.append(prefix + "/" + name)
                    }
                } else {
                    let candidate = prefix + "/" + component
                    if exists(candidate) { next.append(candidate) }
                }
            }
            results = next
            if results.isEmpty { break }
        }
        return results.filter { $0 != "/" }
    }
}
