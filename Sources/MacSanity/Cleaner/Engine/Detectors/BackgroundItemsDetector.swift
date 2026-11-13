import Foundation
import MacSanityCore

/// Launch agents/daemons whose program no longer exists (left behind by removed
/// apps — they fail to launch on every login or boot), and privileged helper
/// tools that no daemon references any more.
struct BackgroundItemsDetector: Detector {
    let category = CleanerCategory.backgroundItems

    func scan(_ ctx: ScanContext) async -> [Finding] {
        let roots: [(path: String, domain: String, admin: Bool)] = [
            (ctx.home + "/Library/LaunchAgents", "gui/\(ctx.uid)", false),
            ("/Library/LaunchAgents", "gui/\(ctx.uid)", true),
            ("/Library/LaunchDaemons", "system", true),
        ]
        var findings: [Finding] = []
        var referencedPrograms = Set<String>()

        for root in roots {
            for plist in DiskIO.children(of: root.path) where plist.hasSuffix(".plist") && ctx.isRemovable(plist) {
                guard let dict = NSDictionary(contentsOfFile: plist) as? [String: Any],
                      let label = dict["Label"] as? String else { continue }
                let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
                if let program { referencedPrograms.insert(program) }

                var missing = false
                var reason = ""
                if let program, program.hasPrefix("/") {
                    missing = !DiskIO.exists(program)
                    reason = "Program missing: \(program)"
                } else if dict["BundleProgram"] != nil,
                          let owners = dict["AssociatedBundleIdentifiers"] as? [String] ?? (dict["AssociatedBundleIdentifiers"] as? String).map({ [$0] }) {
                    missing = !owners.contains { ctx.inventory.isInstalled(bundleID: $0) }
                    reason = "App removed: \(owners.joined(separator: ", "))"
                }
                guard missing else { continue }
                let size = DiskIO.modified(plist)
                findings.append(Finding(
                    id: Finding.makeID(category, plist), category: category, title: label,
                    reason: "Program missing",
                    afterRemoval: "Nothing — the program it starts is already gone.",
                    safety: .safe,
                    items: [FindingItem(path: plist, size: 4096, modified: size)],
                    group: root.domain == "system" ? "System background items" : "Login background items",
                    lastUsed: size, action: .launchItem(label: label, domain: root.domain),
                    needsAdmin: root.admin,
                    details: reason + ". It fails to start at every \(root.domain == "system" ? "boot" : "login")."))
            }
        }

        // Privileged helper tools no daemon points at any more.
        for tool in DiskIO.children(of: "/Library/PrivilegedHelperTools") where ctx.isRemovable(tool) {
            guard !referencedPrograms.contains(tool) else { continue }
            let label = (tool as NSString).lastPathComponent
            if DiskIO.exists("/Library/LaunchDaemons/\(label).plist") { continue }
            let size = await DiskIO.size(tool)
            findings.append(Finding(
                id: Finding.makeID(category, tool), category: category, title: label,
                reason: "Unused helper tool",
                afterRemoval: "Nothing — no installed app starts it.",
                safety: .review,
                items: [FindingItem(path: tool, size: size.allocated, modified: size.newest)],
                group: "Orphaned helper tools", lastUsed: size.newest, action: .trash, needsAdmin: true))
        }
        return findings
    }
}
