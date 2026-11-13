import Foundation
import MacSanityCore

/// Your own items in the system temp folders (`/private/tmp`, your per-user
/// `$TMPDIR`) that nothing has touched for days, and coding-agent session
/// scratch folders (`/private/tmp/claude-<uid>/…`) whose sessions have ended.
/// Anything a running process has open (or uses as its working directory) is
/// never offered.
struct TemporaryFilesDetector: Detector {
    let category = CleanerCategory.temporary

    func scan(_ ctx: ScanContext) async -> [Finding] {
        let tmpRoot = "/private/tmp"
        let userTemp = ctx.userVarFolder.map { $0 + "/T" }
        let agentRoot = "\(tmpRoot)/claude-\(ctx.uid)"
        let inUse = await DiskIO.run {
            ProcessProbe.pathsInUse(under: [tmpRoot] + (userTemp.map { [$0] } ?? []))
        }
        func isInUse(_ path: String) -> Bool {
            inUse.contains { $0 == path || $0.hasPrefix(path + "/") }
        }

        var findings: [Finding] = []

        // 1. Coding-agent sessions: one finding per session, grouped by project.
        var sessionPaths: [(project: String, session: String)] = []
        for projectDir in DiskIO.children(of: agentRoot) where DiskIO.isDirectory(projectDir) {
            for sessionDir in DiskIO.children(of: projectDir) where DiskIO.isDirectory(sessionDir) {
                sessionPaths.append((projectDir, sessionDir))
            }
        }
        let sessionSizes = await DiskIO.sizes(sessionPaths.map(\.session), cancel: ctx.cancel)
        for (project, session) in sessionPaths {
            guard let size = sessionSizes[session], size.allocated > 0, ctx.isRemovable(session) else { continue }
            let hours = ctx.days(since: size.newest ?? DiskIO.modified(session)) * 24
            let active = isInUse(session)
            let safety: Safety = active ? .careful : Policies.agentSessionSafety(hoursSinceActivity: hours)
            let projectName = Self.decodeAgentProject((project as NSString).lastPathComponent, home: ctx.home)
            findings.append(Finding(
                id: Finding.makeID(category, session),
                category: category,
                title: "Session \(((session as NSString).lastPathComponent).prefix(8))",
                reason: active ? "In use" : "",
                afterRemoval: "The session's temporary files (build output, downloads, scripts) are gone. Its conversation history isn't affected.",
                safety: safety,
                items: [FindingItem(path: session, size: size.allocated, modified: size.newest)],
                group: "Claude Code · \(projectName)",
                lastUsed: size.newest,
                action: .trash))
        }

        // 2. Generic temp items you own, untouched for a few days.
        var tempItems: [(path: String, group: String)] = []
        for child in DiskIO.children(of: tmpRoot) where child != agentRoot && DiskIO.ownerUID(child) == ctx.uid {
            tempItems.append((child, "System temporary folder (/tmp)"))
        }
        if let userTemp {
            for child in DiskIO.children(of: userTemp)
            where !child.hasSuffix("/Mac-Temporary-Files.noindex") && DiskIO.ownerUID(child) == ctx.uid {
                tempItems.append((child, "Your temporary folder"))
            }
        }
        let sizes = await DiskIO.sizes(tempItems.map(\.path), cancel: ctx.cancel)
        for (path, group) in tempItems {
            guard let size = sizes[path], size.allocated >= 1_000_000, ctx.isRemovable(path) else { continue }
            let days = ctx.days(since: size.newest ?? DiskIO.modified(path))
            guard let safety = Policies.tempSafety(daysSinceChange: days, openByProcess: isInUse(path)) else { continue }
            findings.append(Finding(
                id: Finding.makeID(category, path),
                category: category,
                title: (path as NSString).lastPathComponent,
                reason: "Untouched for \(RelativeTime.describe(days: days))",
                afterRemoval: "Nothing — apps recreate temporary files when they need them.",
                safety: safety,
                items: [FindingItem(path: path, size: size.allocated, modified: size.newest)],
                group: group,
                lastUsed: size.newest,
                action: .trash))
        }
        return findings
    }

    /// "-Users-mikael-Private-Buizz--claude-worktrees-nice-diffie-cf3870" →
    /// "Private/Buizz/.claude/worktrees/nice-diffie-cf3870". The encoding turns
    /// both "/" and "." into "-", so each "-" is resolved against what exists on
    /// disk: a new path component if that folder exists, else part of the name.
    static func decodeAgentProject(_ encoded: String, home: String) -> String {
        let tokens = encoded.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        var path = ""
        var current = ""
        var i = tokens.first == "" ? 1 : 0
        while i < tokens.count {
            var token = tokens[i]
            if token.isEmpty, i + 1 < tokens.count { token = "." + tokens[i + 1]; i += 1 }   // "--x" → "/.x"
            if current.isEmpty {
                current = token
            } else if DiskIO.isDirectory(path + "/" + current) && !DiskIO.isDirectory(path + "/" + current + "-" + token) {
                path += "/" + current
                current = token
            } else {
                current += "-" + token
            }
            i += 1
        }
        let full = path + "/" + current
        if full.hasPrefix(home + "/") { return String(full.dropFirst(home.count + 1)) }
        return full
    }
}

/// Human phrasing for ages ("3 hours ago", "5 days", "4 months").
enum RelativeTime {
    static func describe(hours: Double) -> String {
        if hours.isInfinite { return "unknown" }
        if hours < 1 { return "just now" }
        if hours < 48 { return "\(Int(hours)) hours ago" }
        return describe(days: hours / 24) + " ago"
    }

    static func describe(days: Double) -> String {
        if days.isInfinite { return "a long time" }
        if days < 1 / 24 { return "\(max(1, Int(days * 24 * 60))) minutes" }
        if days < 1 { return "\(Int(days * 24)) hours" }
        if days < 2 { return "1 day" }
        if days < 60 { return "\(Int(days)) days" }
        if days < 730 { return "\(Int(days / 30)) months" }
        return "\(Int(days / 365)) years"
    }
}
