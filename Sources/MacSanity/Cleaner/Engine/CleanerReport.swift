import AppKit
import MacSanityCore

/// Developer aid: `MACSANITY_CLEANER_REPORT=1 MacSanity` scans, prints every
/// finding and the Disk Map top level to stdout, and exits. Read-only — nothing
/// is moved. Used to verify detectors on a real Mac.
@MainActor
enum CleanerReport {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["MACSANITY_CLEANER_REPORT"] == "1" }

    static func runAndExit() {
        Task {
            let cancel = CancelFlag()
            let result = await Scanner.run(cancel: cancel, onProgress: { _, _ in }, onStatus: { _, _ in })
            let fmt = ByteCountFormatter()
            fmt.countStyle = .file
            func b(_ n: Int64) -> String { fmt.string(fromByteCount: n) }

            print("=== Volume ===")
            print("total \(b(result.volume.total)), available \(b(result.volume.available)), important \(b(result.volume.availableForImportantUsage)), data used \(b(result.volume.dataVolumeUsed))")
            for p in result.volume.otherVolumes { print("  \(p.name): \(b(p.bytes))") }
            if let map = result.diskMap {
                print("=== Disk Map (\(b(map.size)), unreadable folders: \(map.unreadable)) ===")
                func show(_ n: DiskNode, _ depth: Int, _ maxDepth: Int) {
                    print(String(repeating: "  ", count: depth) + "\(b(n.size))  \(n.path)")
                    if depth < maxDepth { for c in n.children.prefix(8) { show(c, depth + 1, maxDepth) } }
                }
                show(map, 0, 3)
            }
            print("=== Findings (scan \(String(format: "%.1f", result.duration))s, FDA \(result.fullDiskAccess)) ===")
            for category in CleanerCategory.allCases {
                let fs = result.findings.filter { $0.category == category }.sorted { $0.size > $1.size }
                guard !fs.isEmpty else { continue }
                let preselected = Set(fs.filter { $0.safety == .safe && $0.isRemovable }.map(\.id))
                print("\n## \(category.rawValue): \(fs.count) findings, \(b(fs.reduce(0) { $0 + $1.size })) (safe preselected: \(b(result.totalSize(for: preselected))))")
                for f in fs.prefix(25) {
                    print("  [\(f.safety)] \(b(f.size))  \(f.group ?? "-") › \(f.title) — \(f.reason)\(f.needsAdmin ? " [admin]" : "")")
                    for item in f.items.prefix(3) { print("        \(item.path)") }
                }
            }
            let allSafe = Set(result.findings.filter { $0.safety == .safe && $0.isRemovable }.map(\.id))
            print("\nTOTAL safe (deduplicated): \(b(result.totalSize(for: allSafe)))")
            fflush(stdout)
            exit(0)
        }
    }
}
