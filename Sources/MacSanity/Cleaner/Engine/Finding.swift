import Foundation
import MacSanityCore

/// One thing the cleaner suggests removing (or only reports), e.g. "Go build
/// cache", "OpenCode (not installed)", or "Buizz worktree nice-diffie".
/// A finding can span several paths (an app's leftovers live in many places).
struct Finding: Identifiable, Sendable, Hashable {
    /// Stable across scans: category + primary path, so selections survive a rescan.
    let id: String
    let category: CleanerCategory
    var title: String
    /// Why it's suggested ("Not used since March", "App was removed", "Superseded by 2.56").
    var reason: String
    /// What happens after removal.
    var afterRemoval: String
    var safety: Safety
    var items: [FindingItem]
    /// Group header in the list (an app, a project, a tool).
    var group: String?
    /// Most recent use or modification, shown as "Last used".
    var lastUsed: Date?
    /// App bundle path for the row icon.
    var iconPath: String?
    var action: RemovalAction
    /// Apps that must be quit first (bundle IDs).
    var quitFirst: [String] = []
    /// Executables whose running processes block removal ("cargo", "go").
    var blockingProcesses: [String] = []
    /// Root-owned items: removal needs the admin password.
    var needsAdmin = false
    /// Longer explanation, shown only on hover (the row keeps `reason` short).
    var details = ""

    var size: Int64 { items.reduce(0) { $0 + $1.size } }
    var isRemovable: Bool { if case .reportOnly = action { false } else { true } }
}

struct FindingItem: Sendable, Hashable {
    let path: String
    let size: Int64
    let modified: Date?
}

/// How a finding is removed. Everything ends in the Trash or in a tool's own
/// cleanup command — never a direct delete.
enum RemovalAction: Sendable, Hashable {
    /// Move every item to the Trash.
    case trash
    /// Run a tool's cleanup command; if the tool is missing and `fallbackToTrash`, trash the items.
    case command([String], fallbackToTrash: Bool)
    /// `git worktree remove` in `repository`, then trash what remains.
    case gitWorktree(repository: String)
    /// `launchctl bootout` the job, then trash the plist (and its program, if listed).
    case launchItem(label: String, domain: String)
    /// `pkgutil --forget` a receipt (needs admin).
    case forgetReceipt(packageID: String)
    /// Size only; managed by its own app.
    case reportOnly(hint: String)
}

extension Finding {
    static func makeID(_ category: CleanerCategory, _ key: String) -> String { "\(category.rawValue):\(key)" }
}
