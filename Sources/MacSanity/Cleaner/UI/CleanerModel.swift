import AppKit
import MacSanityCore
import Observation

// UI RULE: the cleaner UI keeps all state in this @Observable model and never
// uses SwiftUI's @State. The Command Line Tools on this Mac don't ship the
// SwiftUI macro plugin that @State needs (Observation's plugin is present).

/// Sidebar sections.
enum CleanerSection: Hashable {
    case overview, diskMap, category(CleanerCategory), uninstall, history
}

/// Presentation metadata for each category.
extension CleanerCategory {
    static let displayOrder: [CleanerCategory] = [
        .temporary, .installers, .worktrees, .appCaches, .developer, .projects,
        .leftovers, .backgroundItems, .unusedApps, .largeFiles, .system,
    ]

    var title: String {
        switch self {
        case .uninstall: "Uninstall"
        case .leftovers: "App Leftovers"
        case .worktrees: "Git Worktrees"
        case .temporary: "Temporary Files"
        case .installers: "Installers & Updates"
        case .backgroundItems: "Background Items"
        case .developer: "Developer"
        case .projects: "Projects"
        case .appCaches: "App Caches"
        case .unusedApps: "Unused Apps"
        case .largeFiles: "Large & Old Files"
        case .system: "System"
        }
    }

    var symbol: String {
        switch self {
        case .uninstall: "trash"
        case .leftovers: "shippingbox"
        case .worktrees: "arrow.triangle.branch"
        case .temporary: "clock.arrow.circlepath"
        case .installers: "arrow.down.circle"
        case .backgroundItems: "gearshape.2"
        case .developer: "hammer"
        case .projects: "folder.badge.gearshape"
        case .appCaches: "square.stack.3d.up"
        case .unusedApps: "app.dashed"
        case .largeFiles: "doc.richtext"
        case .system: "lock.shield"
        }
    }

    var blurb: String {
        switch self {
        case .uninstall: "Remove an app and everything it keeps."
        case .leftovers: "Data left behind by apps you removed."
        case .worktrees: "Extra git working copies. Uncommitted work is never preselected."
        case .temporary: "Old temporary files and finished agent sessions."
        case .installers: "Restore images, update downloads and installers you no longer need."
        case .backgroundItems: "Startup items whose app is gone."
        case .developer: "Developer tool and package caches, rebuilt when needed."
        case .projects: "Build output in your projects. Idle projects are preselected."
        case .appCaches: "Caches apps rebuild on their own."
        case .unusedApps: "Apps you haven't opened in six months."
        case .largeFiles: "Your biggest and oldest files. Nothing is preselected."
        case .system: "System-wide items. Asks for your password."
        }
    }
}

enum FindingSort: String, CaseIterable { case size = "Size", date = "Last Used", name = "Name" }

@MainActor
@Observable
final class CleanerModel {
    enum Phase: Equatable { case idle, scanning, ready, cleaning }

    // Scan
    private(set) var phase: Phase = .idle
    private(set) var status = ""
    /// 0…1 while scanning.
    private(set) var scanFraction: Double = 0
    private(set) var progress: [CleanerCategory: CategoryProgress] = [:]
    private(set) var result: ScanResult?
    @ObservationIgnored private var cancel: CancelFlag?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    // Navigation & presentation
    var section: CleanerSection? = .overview
    var query = ""
    var sort: FindingSort = .size
    var showUncertain = false
    var diskMapPath: String = "/"
    var showConfirm = false
    var showFullDiskAccessHelp = false
    var lastOutcome: Remover.Outcome?
    var showOutcome = false
    var lastSessionFreed: Int64?

    // Selection — totals are recomputed once per change, not on every render.
    var selection: Set<String> = [] { didSet { recomputeSelectionTotals() } }
    private(set) var selectedTotal: Int64 = 0
    private(set) var selectedByCategory: [CleanerCategory: Int64] = [:]
    private(set) var totalsByCategory: [CleanerCategory: Int64] = [:]
    private(set) var countsByCategory: [CleanerCategory: Int] = [:]
    /// Build tools running when the confirm sheet was opened.
    private(set) var busyTools: [String] = []

    // Environment
    private(set) var fullDiskAccess = FullDiskAccess.isGranted
    let history = CleanerHistory()
    private(set) var historyEntries: [HistoryEntry] = []
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]

    // Uninstall
    var uninstallApp: AppRecord?
    var uninstallItems: [FindingItem] = []
    var uninstallSearch = ""
    private(set) var uninstallBusy = false

    init() {
        history.refreshStates()
        historyEntries = history.entries
    }

    // MARK: Scanning

    func startScan() {
        guard phase != .scanning else { return }
        let flag = CancelFlag()
        cancel = flag
        phase = .scanning
        progress = [:]
        scanFraction = 0
        status = "Getting ready"
        fullDiskAccess = FullDiskAccess.isGranted
        scanTask = Task { [weak self] in
            let result = await Scanner.run(cancel: flag, onProgress: { category, p in
                guard let self, self.cancel === flag, !flag.isCancelled else { return }
                self.progress[category] = p
            }, onStatus: { text, fraction in
                guard let self, self.cancel === flag, !flag.isCancelled else { return }
                self.status = text
                self.scanFraction = max(self.scanFraction, fraction)
            })
            guard let self, !flag.isCancelled else { return }
            self.apply(result)
        }
    }

    func cancelScan() {
        cancel?.cancel()
        scanTask?.cancel()
        phase = result == nil ? .idle : .ready
        status = ""
    }

    private func apply(_ result: ScanResult) {
        let previous = selection
        self.result = result
        // Keep earlier choices that still exist; otherwise preselect Safe items.
        let ids = Set(result.findings.map(\.id))
        let kept = previous.intersection(ids)
        selection = kept.isEmpty ? Set(result.findings.filter(Self.isPreselected).map(\.id)) : kept
        recomputeTotals()
        rebuildTopLevelClaims()
        phase = .ready
        status = ""
    }

    static func isPreselected(_ f: Finding) -> Bool {
        f.safety == .safe && f.isRemovable && !f.needsAdmin && f.category != .largeFiles
    }

    /// Free memory when the window closes; nothing keeps running.
    func reset() {
        cancelScan()
        result = nil
        selection = []
        totalsByCategory = [:]
        countsByCategory = [:]
        progress = [:]
        diskMapPath = "/"
        phase = .idle
        iconCache = [:]
        uninstallApp = nil
        uninstallItems = []
    }

    // MARK: Queries

    func findings(in category: CleanerCategory) -> [Finding] {
        guard let result else { return [] }
        var list = result.findings.filter { $0.category == category }
        if category == .leftovers && !showUncertain { list = list.filter { $0.group != "Uncertain matches" } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { f in
                f.title.lowercased().contains(q) || f.reason.lowercased().contains(q)
                    || (f.group?.lowercased().contains(q) ?? false) || f.items.contains { $0.path.lowercased().contains(q) }
            }
        }
        switch sort {
        case .size: list.sort { $0.size > $1.size }
        case .date: list.sort { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case .name: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return list
    }

    /// Findings grouped for display, groups ordered by their total size.
    func groupedFindings(in category: CleanerCategory) -> [(group: String, findings: [Finding])] {
        let list = findings(in: category)
        var order: [String] = []
        var groups: [String: [Finding]] = [:]
        for f in list {
            let g = f.group ?? category.title
            if groups[g] == nil { order.append(g) }
            groups[g, default: []].append(f)
        }
        if sort == .size {
            order.sort { groups[$0]!.reduce(0) { $0 + $1.size } > groups[$1]!.reduce(0) { $0 + $1.size } }
        }
        return order.map { ($0, groups[$0]!) }
    }

    func totalSize(in category: CleanerCategory) -> Int64 { totalsByCategory[category] ?? 0 }

    func selectedSize(in category: CleanerCategory) -> Int64 { selectedByCategory[category] ?? 0 }

    func count(in category: CleanerCategory) -> Int { countsByCategory[category] ?? 0 }

    /// Size, or the item count for findings that take no space (receipts, snapshots).
    func summary(in category: CleanerCategory) -> String {
        let size = totalSize(in: category)
        if size > 0 { return Bytes.text(size) }
        let n = count(in: category)
        return n == 1 ? "1 item" : "\(n) items"
    }

    private func recomputeTotals() {
        var totals: [CleanerCategory: Int64] = [:]
        var counts: [CleanerCategory: Int] = [:]
        for f in result?.findings ?? [] {
            totals[f.category, default: 0] += f.size
            counts[f.category, default: 0] += 1
        }
        totalsByCategory = totals
        countsByCategory = counts
        recomputeSelectionTotals()
    }

    /// Effective (deduplicated) selected bytes, overall and per category.
    private func recomputeSelectionTotals() {
        guard let result else { selectedTotal = 0; selectedByCategory = [:]; return }
        var perCategory: [CleanerCategory: Int64] = [:]
        var total: Int64 = 0
        for (finding, item) in result.effectiveItems(for: selection) {
            perCategory[finding.category, default: 0] += item.size
            total += item.size
        }
        selectedByCategory = perCategory
        selectedTotal = total
    }

    /// Open the confirm sheet, capturing what's running at that moment.
    func reviewAndClean() {
        busyTools = Array(Set(selectedFindings.flatMap(\.blockingProcesses)).intersection(ProcessProbe.executableNames())).sorted()
        showConfirm = true
    }

    var selectedFindings: [Finding] {
        result?.findings.filter { selection.contains($0.id) && $0.isRemovable } ?? []
    }

    var count: (selected: Int, total: Int) {
        (selectedFindings.count, result?.findings.count ?? 0)
    }

    // MARK: Selection

    func isSelected(_ f: Finding) -> Bool { selection.contains(f.id) }

    func setSelected(_ f: Finding, _ on: Bool) {
        guard f.isRemovable else { return }
        if on { selection.insert(f.id) } else { selection.remove(f.id) }
    }

    func selectAll(in category: CleanerCategory, safety: Safety?) {
        let ids = findings(in: category).filter { $0.isRemovable && (safety == nil || $0.safety == safety) }.map(\.id)
        selection.formUnion(ids)   // one assignment → one recompute
    }

    func selectNone(in category: CleanerCategory) {
        selection.subtract(findings(in: category).map(\.id))
    }


    // MARK: Cleaning

    /// Running apps among the selected findings that must quit first.
    var appsToQuit: [(bundleID: String, name: String)] {
        let ids = Set(selectedFindings.flatMap(\.quitFirst))
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, ids.contains(id) else { return nil }
            return (id, app.localizedName ?? id)
        }
    }

    var commandsToRun: [String] {
        selectedFindings.compactMap { f in
            if case .command(let argv, _) = f.action { return argv.joined(separator: " ") }
            return nil
        }
    }

    var needsAdmin: Bool { selectedFindings.contains(where: \.needsAdmin) }

    func quit(_ bundleIDs: [String]) async {
        _ = await RunningApps.quit(bundleIDs)
    }

    func clean() async {
        guard let result, phase == .ready else { return }
        showConfirm = false
        phase = .cleaning
        status = "Moving to Trash"
        let work = result.effectiveItems(for: Set(selectedFindings.map(\.id)))
        let outcome = await Remover.perform(work, allSelected: selectedFindings, history: history)
        historyEntries = history.entries
        lastOutcome = outcome
        lastSessionFreed = nil
        showOutcome = true
        // Remove what was handled from the results without a full rescan.
        let done = Set(outcome.entries.map(\.originalPath))
        var updated = result
        let remaining: [Finding] = updated.findings.compactMap { f in
            var f = f
            if f.items.isEmpty {
                return outcome.entries.contains { $0.title == f.title && $0.category == f.category } ? nil : f
            }
            f.items.removeAll { done.contains($0.path) }
            return f.items.isEmpty ? nil : f
        }
        // Item indices changed: rebuild the claims so containment stays exact.
        (updated.findings, updated.resolver) = Scanner.resolve(remaining)
        self.result = updated
        rebuildTopLevelClaims()
        selection = selection.intersection(Set(updated.findings.map(\.id)))
        recomputeTotals()
        phase = .ready
        status = ""
    }

    /// Permanently delete the items from the last cleanup that are still in the Trash.
    func emptyLastSession() async {
        guard let entries = lastOutcome?.entries, !entries.isEmpty else { return }
        lastSessionFreed = await Remover.emptyFromTrash(entries, history: history)
        historyEntries = history.entries
    }

    // MARK: History

    func refreshHistory() {
        history.refreshStates()
        historyEntries = history.entries
    }

    func restore(_ entries: [HistoryEntry]) async -> [String] {
        let failures = await Remover.restore(entries, history: history)
        historyEntries = history.entries
        return failures
    }

    func emptyFromTrash(_ entries: [HistoryEntry]) async {
        _ = await Remover.emptyFromTrash(entries, history: history)
        historyEntries = history.entries
    }

    // MARK: Uninstall

    func chooseAppToUninstall() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an app to uninstall"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { prepareUninstall(path: url.path) }
    }

    func prepareUninstall(path: String) {
        guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else { return }
        let info = bundle.infoDictionary ?? [:]
        let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        let names = [info["CFBundleName"], info["CFBundleDisplayName"], info["CFBundleExecutable"]].compactMap { $0 as? String } + [name]
        uninstallApp = AppRecord(path: path, bundleID: id, name: name, names: names, lastUsed: nil, isApple: id.hasPrefix("com.apple."))
        uninstallSearch = ""
        searchRelated(bundleIDs: [id], names: names, include: path)
    }

    /// Search leftovers by name or bundle ID — works for apps removed long ago.
    func searchLeftovers() {
        let term = uninstallSearch.trimmingCharacters(in: .whitespaces)
        guard term.count >= 3 else { return }
        uninstallApp = nil
        searchRelated(bundleIDs: term.contains(".") ? [term] : [], names: [term], containing: term, include: nil)
    }

    private func searchRelated(bundleIDs: [String], names: [String], containing: String? = nil, include appPath: String?) {
        uninstallBusy = true
        uninstallItems = []
        uninstallSelection = []
        let home = NSHomeDirectory()
        Task {
            let policy = SafetyPolicy(home: home, userVarFolder: Remover.userVarFolder())
            let paths = await DiskIO.run {
                RelatedFiles.find(bundleIDs: bundleIDs, names: names, containing: containing, home: home)
            }
            let all = ((appPath.map { [$0] } ?? []) + paths).filter { policy.check($0) == .allowed }
            let sizes = await DiskIO.sizes(all)
            uninstallItems = all.compactMap { p in sizes[p].map { FindingItem(path: p, size: $0.allocated, modified: $0.newest) } }
                .sorted { $0.size > $1.size }
            uninstallSelection = Set(uninstallItems.map(\.path))   // everything found starts checked
            uninstallBusy = false
        }
    }

    /// Paths checked for removal (explicit — an empty set means nothing).
    var uninstallSelection: Set<String> = []

    var uninstallSelectedItems: [FindingItem] {
        uninstallItems.filter { uninstallSelection.contains($0.path) }
    }

    func uninstall() async {
        let items = uninstallSelectedItems
        guard !items.isEmpty else { return }
        let title = uninstallApp?.name ?? uninstallSearch
        let quit = uninstallApp.map { [$0.bundleID] } ?? []
        if !quit.isEmpty { _ = await RunningApps.quit(quit) }
        let finding = Finding(id: Finding.makeID(.uninstall, title), category: .uninstall, title: title,
                              reason: "", afterRemoval: "", safety: .review, items: items, group: nil, lastUsed: nil,
                              action: .trash, quitFirst: quit,
                              needsAdmin: items.contains { DiskIO.ownerUID($0.path) != getuid() })
        uninstallBusy = true
        let outcome = await Remover.perform(items.map { (finding, $0) }, allSelected: [finding], history: history)
        historyEntries = history.entries
        lastOutcome = outcome
        lastSessionFreed = nil
        showOutcome = true
        uninstallItems.removeAll { item in outcome.entries.contains { $0.originalPath == item.path } }
        uninstallSelection.formIntersection(uninstallItems.map(\.path))
        uninstallBusy = false
    }

    // MARK: Disk Map

    var diskMapNode: DiskNode? {
        result?.diskMap?.node(at: diskMapPath) ?? result?.diskMap
    }

    /// Bytes of findings under a path (for "X reclaimable" badges). Only
    /// outermost claims count, so a worktree and the `target/` inside it aren't
    /// added twice.
    func reclaimable(under path: String) -> (size: Int64, categories: [CleanerCategory]) {
        var total: Int64 = 0
        var cats = Set<CleanerCategory>()
        for claim in topLevelClaims where claim.path == path || SafetyPolicy.isInside(claim.path, path) {
            total += claim.size
            cats.insert(claim.category)
        }
        return (total, CleanerCategory.displayOrder.filter(cats.contains))
    }

    /// Removable items not contained in another finding's item; rebuilt per scan.
    @ObservationIgnored private var topLevelClaims: [(path: String, size: Int64, category: CleanerCategory)] = []

    private func rebuildTopLevelClaims() {
        guard let result else { topLevelClaims = []; return }
        topLevelClaims = result.findings.filter(\.isRemovable).flatMap { f in
            f.items.enumerated().compactMap { i, item in
                result.resolver.containedIn[ScanResult.claimID(f.id, i)] == nil ? (item.path, item.size, f.category) : nil
            }
        }
    }

    /// Select every finding item under a Disk Map folder.
    func selectFindings(under path: String) {
        guard let result else { return }
        selection.formUnion(result.findings.filter { f in
            f.isRemovable && f.items.contains { $0.path == path || SafetyPolicy.isInside($0.path, path) }
        }.map(\.id))
    }

    // MARK: Helpers

    func icon(for path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = image
        return image
    }

    func reveal(_ path: String) { reveal([path]) }

    /// Select the items in Finder (one window, all of them selected).
    func reveal(_ paths: [String]) {
        let urls = paths.filter(DiskIO.exists).map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func openFullDiskAccessSettings() { FullDiskAccess.openSettings() }

    /// Full Disk Access can only be granted to an app bundle.
    var canGrantFullDiskAccess: Bool { AppRelaunch.isAppBundle }

    /// Select the app in Finder so it can be dragged into the Full Disk Access list.
    func revealAppForFullDiskAccess() { reveal(Bundle.main.bundleURL.path) }

    /// The grant only applies to a newly started process.
    func relaunchForFullDiskAccess() { AppRelaunch.relaunch() }
}

enum Bytes {
    /// Decimal units, like Finder. "—" for zero, for size columns.
    static func format(_ n: Int64) -> String {
        n == 0 ? "—" : n.formatted(.byteCount(style: .file))
    }

    /// For sentences ("Zero KB selected").
    static func text(_ n: Int64) -> String { n.formatted(.byteCount(style: .file)) }
}
