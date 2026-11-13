// Standalone checks for the cleaner's pure logic. Run with `swift run CleanerCheck`.
// Exits 0 if all pass, 1 otherwise (stands in for XCTest, like the other runners).

import Foundation
import MacSanityCore

var failures = 0
@MainActor func check(_ name: String, _ ok: Bool) {
    print(ok ? "PASS  \(name)" : "FAIL  \(name)")
    if !ok { failures += 1 }
}

// MARK: SafetyPolicy

let home = "/Users/test"
let varFolder = "/private/var/folders/3k/abc/0"
let policy = SafetyPolicy(home: home, userVarFolder: varFolder)
func allowed(_ p: String) -> Bool { policy.check(p) == .allowed }

check("safety: cache child allowed", allowed("/Users/test/Library/Caches/go-build"))
check("safety: project artifact allowed", allowed("/Users/test/Private/Buizz/target"))
check("safety: home itself denied", !allowed("/Users/test"))
check("safety: Library root denied", !allowed("/Users/test/Library"))
check("safety: Caches root denied", !allowed("/Users/test/Library/Caches"))
check("safety: Documents root denied", !allowed("/Users/test/Documents"))
check("safety: file inside Documents allowed", allowed("/Users/test/Documents/big.iso"))
check("safety: System denied", !allowed("/System/Library/Caches/x"))
check("safety: usr denied", !allowed("/usr/local/lib/x"))
check("safety: other volume denied", !allowed("/Volumes/Backup/x"))
check("safety: relative denied", !allowed("Library/Caches/x"))
check("safety: dot-dot denied", !allowed("/Users/test/Library/Caches/../../.ssh"))
check("safety: dot denied", !allowed("/Users/test/./x"))
check("safety: iCloud denied", !allowed("/Users/test/Library/Mobile Documents/com~apple~CloudDocs/x"))
check("safety: keychains denied", !allowed("/Users/test/Library/Keychains/login.keychain-db"))
check("safety: ssh denied", !allowed("/Users/test/.ssh/id_ed25519"))
check("safety: ancestor of protected denied", !allowed("/Users/test/Library/Application Support"))
check("safety: AddressBook denied", !allowed("/Users/test/Library/Application Support/AddressBook"))
check("safety: apple container denied", !allowed("/Users/test/Library/Containers/com.apple.Notes"))
check("safety: apple group container denied", !allowed("/Users/test/Library/Group Containers/group.com.apple.notes"))
check("safety: team apple group container denied", !allowed("/Users/test/Library/Group Containers/UBF8T346G9.com.apple.x"))
check("safety: apple prefs denied", !allowed("/Users/test/Library/Preferences/com.apple.dock.plist"))
check("safety: 3rd-party container allowed", allowed("/Users/test/Library/Containers/com.spotify.client"))
check("safety: photos library denied", !allowed("/Users/test/Pictures/Photos Library.photoslibrary/database"))
check("safety: trash denied", !allowed("/Users/test/.Trash/foo"))
check("safety: tmp child allowed", allowed("/private/tmp/claude-501/x"))
check("safety: tmp root denied", !allowed("/private/tmp"))
check("safety: user T child allowed", allowed(varFolder + "/T/Mac-Temporary-Files.noindex"))
check("safety: user T root denied", !allowed(varFolder + "/T"))
check("safety: other var folder denied", !allowed("/private/var/folders/zz/other/T/x"))
check("safety: /Library/Caches child allowed", allowed("/Library/Caches/com.vendor.app"))
check("safety: /Library/Keychains denied", !allowed("/Library/Keychains/System.keychain"))
check("safety: apple launch daemon denied", !allowed("/Library/LaunchDaemons/com.apple.x.plist"))
check("safety: vendor launch daemon allowed", allowed("/Library/LaunchDaemons/com.vendor.helper.plist"))
check("safety: Applications app allowed", allowed("/Applications/Battle.net.app"))
check("safety: Safari denied", !allowed("/Applications/Safari.app"))
check("safety: our history denied", !allowed("/Users/test/Library/Application Support/MacSanity/CleanerHistory.json"))
check("safety: trailing slash normalized", !allowed("/Users/test/Library/Caches/"))

// MARK: OrphanMatcher

let index = AppIndex([
    InstalledApp(bundleID: "com.microsoft.VSCode", names: ["Code", "Visual Studio Code", "Electron"]),
    InstalledApp(bundleID: "com.anthropic.claudefordesktop", names: ["Claude"]),
    InstalledApp(bundleID: "com.google.Chrome", names: ["Google Chrome", "Chrome"], teamID: "EQHXZ8M8AV"),
    InstalledApp(bundleID: "com.spotify.client", names: ["Spotify"]),
    InstalledApp(bundleID: "com.tinyspeck.slackmacgap", names: ["Slack"], teamID: "BQR82RBBHL",
                 appGroups: ["BQR82RBBHL.com.tinyspeck.slackmacgap"]),
    InstalledApp(bundleID: "se.velox.app", names: ["Velox"]),
])
func own(_ name: String, _ loc: LibraryLocation = .named, id: String? = nil, days: Double = 400) -> Ownership {
    OrphanMatcher.classify(name: name, location: loc, identifier: id, modifiedDaysAgo: days, index: index)
}
func isOrphan(_ o: Ownership, _ c: Ownership.Confidence? = nil) -> Bool {
    if case .orphan(let conf, _) = o { return c == nil || conf == c }
    return false
}

check("orphan: VS Code 'Code' folder is owned", own("Code") == .owned)
check("orphan: Claude-3p is owned (prefix)", own("Claude-3p") == .owned)
check("orphan: Google vendor folder is owned", own("Google") == .owned)
check("orphan: Spotify bundle-id cache owned", own("com.spotify.client") == .owned)
check("orphan: helper bundle id owned", own("com.spotify.client.helper") == .owned)
check("orphan: Slack ShipIt owned", own("com.tinyspeck.slackmacgap.ShipIt") == .owned)
check("orphan: removed app bundle id is medium", isOrphan(own("ai.opencode.desktop"), .medium))
check("orphan: removed app container is high", isOrphan(own("x", .container, id: "ai.opencode.desktop"), .high))
check("orphan: removed app prefs plist is high", isOrphan(own("ai.opencode.desktop.plist", .preferences), .high))
check("orphan: removed app saved state is high", isOrphan(own("ai.opencode.desktop.savedState", .savedState), .high))
check("orphan: same-vendor removed app is low", isOrphan(own("com.google.Keystone"), .low))
check("orphan: apple folder never suggested", own("com.apple.Safari") == .owned)
check("orphan: tool folder never suggested", own("go-build") == .owned)
check("orphan: recently modified is in use", own("ai.opencode.desktop", days: 3) == .inUse)
check("orphan: plain unknown name is low", isOrphan(own("SomeOldApp"), .low))
check("orphan: home dot-folder of installed app owned", own(".velox", .homeDotFolder) == .owned)
check("orphan: home dot-folder of tool owned", own(".cargo", .homeDotFolder) == .owned)
check("orphan: home dot-folder of removed app low", isOrphan(own(".medivia", .homeDotFolder), .low))
check("orphan: group container by app group owned",
      own("BQR82RBBHL.com.tinyspeck.slackmacgap", .groupContainer) == .owned)
check("orphan: group container same team owned", own("EQHXZ8M8AV.com.google.other", .groupContainer) == .owned)
check("orphan: group container unknown medium", isOrphan(own("ABCDE12345.com.gone.app", .groupContainer), .medium))

check("hint: opencode", OrphanMatcher.displayHint("ai.opencode.desktop") == "opencode")
check("hint: spotify helper", OrphanMatcher.displayHint("com.spotify.client.helper") == "spotify")
check("hint: group container team stripped", OrphanMatcher.displayHint("ABCDE12345.com.gone.app") == "gone")
check("hint: helper GPU cut", OrphanMatcher.displayHint("com.microsoft.Headlamp.helper.GPU") == "Headlamp")
check("hint: helper plugin cut", OrphanMatcher.displayHint("org.chromium.Chromium.helper.plugin") == "Chromium")
check("hint: core product cut", OrphanMatcher.displayHint("org.jkiss.dbeaver.core.product") == "dbeaver")
check("hint: godot", OrphanMatcher.displayHint("org.godotengine.godot") == "godot")
check("orphan: Apple Logic content folder is owned", own("Logic") == .owned)
if case .orphan(_, let hint) = own("ai.opencode.desktop.plist", .preferences) {
    check("hint: plist suffix stripped", hint == "opencode")
} else { check("hint: plist suffix stripped", false) }

// MARK: VersionedSiblings

let copilot = VersionedSiblings.superseded(["github-copilot-git-2.53.0-4", "github-copilot-git-2.56.0-2", "copilot", "github-copilot-sdk"])
check("versions: older copilot git superseded", copilot == ["github-copilot-git-2.53.0-4"])
check("versions: playwright", VersionedSiblings.superseded(["chromium-1091", "chromium-1105", "firefox-1400", "ffmpeg-1009"]) == ["chromium-1091"])
check("versions: jetbrains", VersionedSiblings.superseded(["IntelliJIdea2024.1", "IntelliJIdea2025.2", "PyCharm2025.1"]) == ["IntelliJIdea2024.1"])
check("versions: vscode extension with platform suffix",
      VersionedSiblings.superseded(["ms-python.python-2024.2.1-darwin-arm64", "ms-python.python-2025.1.0-darwin-arm64", "ms-python.vscode-pylance-2025.1.0"])
        == ["ms-python.python-2024.2.1-darwin-arm64"])
check("versions: numeric compare not lexical", VersionedSiblings.superseded(["tool-1.9.0", "tool-1.10.0"]) == ["tool-1.9.0"])
check("versions: unversioned untouched", VersionedSiblings.superseded(["stable-aarch64-apple-darwin", "nightly-aarch64-apple-darwin"]).isEmpty)
check("versions: single version untouched", VersionedSiblings.superseded(["gradle-8.5-bin"]).isEmpty)

// MARK: ClaimResolver

let resolver = ClaimResolver([
    .init(id: "wt", path: "/u/p/.claude/worktrees/a", priority: CleanerCategory.worktrees.claimPriority),
    .init(id: "tgt", path: "/u/p/.claude/worktrees/a/target", priority: CleanerCategory.projects.claimPriority),
    .init(id: "big", path: "/u/p/.claude/worktrees/a/target/debug/big.bin", priority: CleanerCategory.largeFiles.claimPriority),
    .init(id: "dupLow", path: "/u/p/target", priority: CleanerCategory.largeFiles.claimPriority),
    .init(id: "dupHigh", path: "/u/p/target", priority: CleanerCategory.projects.claimPriority),
    .init(id: "sib", path: "/u/p/targetx", priority: CleanerCategory.projects.claimPriority),
])
check("claims: duplicate keeps higher priority", resolver.accepted.contains { $0.id == "dupHigh" } && !resolver.accepted.contains { $0.id == "dupLow" })
check("claims: nested recorded", resolver.containedIn["tgt"] == "wt" && resolver.containedIn["big"] == "tgt")
check("claims: prefix sibling not nested", resolver.containedIn["sib"] == nil)
check("claims: selecting container drops children", resolver.effectiveSelection(["wt", "tgt", "big"]) == ["wt"])
check("claims: grandchild dropped via grandparent", resolver.effectiveSelection(["wt", "big"]) == ["wt"])
check("claims: child alone counted", resolver.effectiveSelection(["tgt"]) == ["tgt"])

// MARK: Policies

check("policy: clean merged old worktree safe", Policies.worktreeSafety(clean: true, merged: true, daysSinceChange: 10) == .safe)
check("policy: clean merged recent worktree review", Policies.worktreeSafety(clean: true, merged: true, daysSinceChange: 1) == .review)
check("policy: unmerged worktree review", Policies.worktreeSafety(clean: true, merged: false, daysSinceChange: 30) == .review)
check("policy: worktree in use careful", Policies.worktreeSafety(clean: true, merged: true, daysSinceChange: 30, inUse: true) == .careful)
check("policy: dirty worktree careful", Policies.worktreeSafety(clean: false, merged: true, daysSinceChange: 30) == .careful)
check("policy: ipsw version parsed", Policies.osVersion(fromInstallerName: "UniversalMac_27.2.1_26B131_Restore.ipsw") == [27, 2, 1])
check("policy: newer ipsw is review", Policies.installerSafety(installerVersion: [27, 2, 1], runningVersion: [27, 2]) == .review)
check("policy: same ipsw is safe", Policies.installerSafety(installerVersion: [27, 2], runningVersion: [27, 2, 0]) == .safe)
check("policy: older ipsw is safe", Policies.installerSafety(installerVersion: [26, 4], runningVersion: [27, 2]) == .safe)
check("policy: unknown installer is review", Policies.installerSafety(installerVersion: nil, runningVersion: [27, 2]) == .review)
check("policy: active agent session careful", Policies.agentSessionSafety(hoursSinceActivity: 2) == .careful)
check("policy: old agent session safe", Policies.agentSessionSafety(hoursSinceActivity: 48) == .safe)
check("policy: fresh temp not offered", Policies.tempSafety(daysSinceChange: 1, openByProcess: false) == nil)
check("policy: open temp not offered", Policies.tempSafety(daysSinceChange: 10, openByProcess: true) == nil)
check("policy: old temp safe", Policies.tempSafety(daysSinceChange: 10, openByProcess: false) == .safe)

// MARK: Catalog sanity

let catalogPaths = Catalog.developer.flatMap(\.paths).map { $0.replacingOccurrences(of: "~", with: home) }
check("catalog: unique ids", Set(Catalog.developer.map(\.id)).count == Catalog.developer.count)
check("catalog: every path passes safety policy",
      catalogPaths.allSatisfy { policy.check($0.replacingOccurrences(of: "/*", with: "/x")) == .allowed })

print(failures == 0 ? "\nAll cleaner checks passed." : "\n\(failures) cleaner check(s) failed.")
exit(failures == 0 ? 0 : 1)
