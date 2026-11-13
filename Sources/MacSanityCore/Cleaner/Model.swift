/// How careful the user should be with a finding. Drives preselection.
public enum Safety: Int, Comparable, Sendable, Codable, CaseIterable {
    /// Regenerated automatically when needed (caches, build output). Preselected.
    case safe
    /// Probably unneeded, but worth a look (old downloads, unmerged worktrees). Not preselected.
    case review
    /// May hold data you want (uncommitted work, uncertain leftovers). Never preselected.
    case careful

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// The cleaner's sections, in the order they're shown and claim paths.
public enum CleanerCategory: String, CaseIterable, Sendable, Codable {
    case uninstall, leftovers, worktrees, temporary, installers, backgroundItems,
         developer, projects, appCaches, unusedApps, largeFiles, system

    /// Higher wins when two findings claim the same path or one contains another.
    public var claimPriority: Int {
        switch self {
        case .uninstall: 100
        case .leftovers: 90
        case .backgroundItems: 85
        case .worktrees: 80
        case .temporary: 70
        case .installers: 65
        case .unusedApps: 60
        case .developer: 50
        case .projects: 40
        case .appCaches: 30
        case .system: 20
        case .largeFiles: 10
        }
    }
}
