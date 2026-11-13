import Foundation
import MacSanityCore
import os
import Synchronization

private let log = Logger(subsystem: "com.macsanity.app", category: "Cleaner")

/// The result of one scan.
struct ScanResult: Sendable {
    var findings: [Finding]
    let diskMap: DiskNode?
    let volume: VolumeSummary
    var resolver: ClaimResolver
    let fullDiskAccess: Bool
    let duration: TimeInterval
    let finishedAt: Date

    /// Claim id for one item of a finding.
    static func claimID(_ findingID: String, _ index: Int) -> String { "\(findingID)|\(index)" }

    /// The items that would actually be removed for a selection (nested items
    /// inside another selected finding are skipped — they go with their container).
    func effectiveItems(for selected: Set<String>) -> [(finding: Finding, item: FindingItem)] {
        var claims = Set<String>()
        for f in findings where selected.contains(f.id) {
            for i in f.items.indices { claims.insert(Self.claimID(f.id, i)) }
        }
        let effective = resolver.effectiveSelection(claims)
        var result: [(Finding, FindingItem)] = []
        for f in findings where selected.contains(f.id) {
            for (i, item) in f.items.enumerated() where effective.contains(Self.claimID(f.id, i)) {
                result.append((f, item))
            }
        }
        return result
    }

    func totalSize(for selected: Set<String>) -> Int64 {
        effectiveItems(for: selected).reduce(0) { $0 + $1.item.size }
    }
}

/// Progress for one category during a scan.
struct CategoryProgress: Sendable, Equatable {
    enum State: Sendable, Equatable { case waiting, scanning, done }
    var state: State = .waiting
    var size: Int64 = 0
    var count: Int = 0
}

/// Runs every detector concurrently, plus the Disk Map walk, then resolves
/// overlapping claims so each byte is counted (and removed) once.
enum Scanner {
    /// Detectors that size things on disk — run after the Disk Map so they reuse its sizes.
    static let detectors: [any Detector] = [
        TemporaryFilesDetector(), InstallersDetector(), GitWorktreesDetector(), DeveloperDetector(),
        ProjectsDetector(), AppCachesDetector(), LeftoversDetector(), BackgroundItemsDetector(),
        UnusedAppsDetector(),
    ]

    static func run(cancel: CancelFlag,
                    onProgress: @escaping @MainActor @Sendable (CleanerCategory, CategoryProgress) -> Void,
                    onStatus: @escaping @MainActor @Sendable (String, Double) -> Void) async -> ScanResult {
        let start = Date()
        let scanID = UUID()
        DiskIO.beginSizeCache(owner: scanID)
        defer { DiskIO.clearSizeCache(owner: scanID) }
        await onStatus("Measuring your disk", 0)
        for c in CleanerCategory.allCases where c != .uninstall {
            await onProgress(c, CategoryProgress(state: .scanning))
        }

        // Phase 1 (concurrently): the whole-disk walk, the app inventory and the
        // project walk. Phase 2: detectors, which reuse the walk's sizes.
        async let volume = DiskMap.volumeSummary()
        // Progress: the disk walk is ~85% of the work, measured in bytes walked.
        let expected = max(1, DiskMap.dataVolumeUsedBytes())
        // Walk progress goes through one ordered stream; updates stop when the walk ends.
        let walked = Mutex<Int64>(0)
        let (walkUpdates, walkContinuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        let forward = Task { @MainActor in
            for await fraction in walkUpdates { onStatus("Measuring your disk", fraction) }
        }
        async let map = DiskMap.build(home: NSHomeDirectory(), cancel: cancel) { bytes in
            let done = walked.withLock { $0 += bytes; return $0 }
            walkContinuation.yield(min(0.85, 0.85 * Double(done) / Double(expected)))
        }
        let running = await MainActor.run { RunningState.current() }
        async let inventory = AppInventory.load(home: NSHomeDirectory())
        // Receipts and snapshots only ask tools, so they run during the walk.
        async let systemFindings = SystemDetector().scan(ScanContext.minimal(cancel: cancel))
        let ctx = await ScanContext.make(inventory: await inventory, running: running, cancel: cancel)
        log.debug("timing: inventory + home walk \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s")
        let diskMap = await map
        walkContinuation.finish()
        await forward.value
        log.debug("timing: disk map \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s")
        // A newer scan may have taken over the cache; then don't touch it.
        if !cancel.isCancelled { DiskIO.setSizeCache(diskMap, owner: scanID) }

        await onStatus("Looking for things to clean", 0.85)
        var findings: [Finding] = await withTaskGroup(of: (CleanerCategory, [Finding]).self) { group in
            for detector in detectors {
                group.addTask {
                    let t = Date()
                    let found = await detector.scan(ctx)
                    log.debug("timing: \(detector.category.rawValue, privacy: .public) \(Date().timeIntervalSince(t), format: .fixed(precision: 1))s")
                    return (detector.category, found)
                }
            }
            var all: [Finding] = []
            var perCategory: [CleanerCategory: [Finding]] = [:]
            var finished = 0
            for await (category, found) in group {
                finished += 1
                await onStatus("Looking for things to clean", 0.85 + 0.15 * Double(finished) / Double(detectors.count))
                perCategory[category, default: []] += found
                all += found
                let list = perCategory[category] ?? []
                await onProgress(category, CategoryProgress(state: .done, size: list.reduce(0) { $0 + $1.size }, count: list.count))
            }
            return all
        }
        let system = await systemFindings
        findings += system
        await onProgress(.system, CategoryProgress(state: .done, size: 0, count: system.count))
        let large = await LargeFilesDetector.findings(map: diskMap, ctx: ctx)
        findings += large
        await onProgress(.largeFiles, CategoryProgress(state: .done, size: large.reduce(0) { $0 + $1.size }, count: large.count))

        let (resolved, resolver) = resolve(findings)
        log.info("Cleaner scan: \(resolved.count) findings in \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s")
        return ScanResult(findings: resolved, diskMap: cancel.isCancelled ? nil : diskMap, volume: await volume,
                          resolver: resolver, fullDiskAccess: ctx.fullDiskAccess,
                          duration: Date().timeIntervalSince(start), finishedAt: Date())
    }

    /// Drop exact-duplicate paths (higher-priority category keeps them), then
    /// rebuild the resolver over the surviving items so containment is exact.
    static func resolve(_ findings: [Finding]) -> ([Finding], ClaimResolver) {
        var claims: [ClaimResolver.Claim] = []
        for f in findings {
            for (i, item) in f.items.enumerated() {
                claims.append(.init(id: ScanResult.claimID(f.id, i), path: item.path, priority: f.category.claimPriority))
            }
        }
        let first = ClaimResolver(claims)
        let kept = Set(first.accepted.map(\.id))
        var result: [Finding] = []
        for var f in findings {
            let hadItems = !f.items.isEmpty
            f.items = f.items.enumerated().filter { kept.contains(ScanResult.claimID(f.id, $0.offset)) }.map(\.element)
            if hadItems && f.items.isEmpty { continue }
            result.append(f)
        }
        var finalClaims: [ClaimResolver.Claim] = []
        for f in result {
            for (i, item) in f.items.enumerated() {
                finalClaims.append(.init(id: ScanResult.claimID(f.id, i), path: item.path, priority: f.category.claimPriority))
            }
        }
        return (result, ClaimResolver(finalClaims))
    }
}
