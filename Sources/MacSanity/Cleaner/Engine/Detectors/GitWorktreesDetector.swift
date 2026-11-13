import Foundation
import MacSanityCore

/// Linked git worktrees (coding agents create many: `.claude/worktrees/*`).
/// Each one is classified by whether it has uncommitted changes and whether its
/// branch is merged. Removal moves the folder to the Trash (so even uncommitted
/// work stays recoverable) and then prunes git's worktree metadata.
struct GitWorktreesDetector: Detector {
    let category = CleanerCategory.worktrees

    struct Info: Sendable {
        let path: String
        let repository: String
        let branch: String
        let changedFiles: [String]
        let merged: Bool
        let lastChange: Date?
        let valid: Bool
    }

    func scan(_ ctx: ScanContext) async -> [Finding] {
        guard Command.locate("git") != nil else { return [] }
        let paths = ctx.homeWalk.worktrees.filter(ctx.isRemovable)
        let infos = await withTaskGroup(of: Info?.self) { group in
            for p in paths { group.addTask { await DiskIO.run { Self.inspect(p) } } }
            var all: [Info] = []
            for await i in group { if let i { all.append(i) } }
            return all
        }
        let sizes = await DiskIO.sizes(infos.map(\.path), cancel: ctx.cancel)
        // A shell, editor or agent working inside a worktree right now.
        let inUse = await DiskIO.run { ProcessProbe.pathsInUse(under: infos.map(\.path)) }

        return infos.compactMap { info in
            guard let size = sizes[info.path], size.allocated > 0 else { return nil }
            let days = ctx.days(since: info.lastChange)
            let clean = info.changedFiles.isEmpty
            let active = inUse.contains { $0 == info.path || $0.hasPrefix(info.path + "/") }
            let safety = info.valid ? Policies.worktreeSafety(clean: clean, merged: info.merged, daysSinceChange: days, inUse: active) : .review
            let branch = info.branch == "HEAD" ? "Detached HEAD" : "Branch \(info.branch)"
            var reason: String
            if active {
                reason = "In use · \(branch)"
            } else if !info.valid {
                reason = "Repository is gone"
            } else if !clean {
                reason = info.changedFiles.count == 1 ? "1 uncommitted change" : "\(info.changedFiles.count) uncommitted changes"
            } else {
                reason = "\(branch) · \(info.merged ? "merged" : "not merged")"
            }
            let repoName = ((info.repository as NSString).lastPathComponent)
            return Finding(
                id: Finding.makeID(category, info.path), category: category,
                title: (info.path as NSString).lastPathComponent,
                reason: reason,
                afterRemoval: (info.merged
                    ? "The folder goes to the Trash; the branch and its commits stay in the repository."
                    : "The folder goes to the Trash; the branch stays, but unmerged work exists only on that branch.")
                    + " If you put it back, run `git worktree repair` in it.",
                safety: safety,
                items: [FindingItem(path: info.path, size: size.allocated, modified: size.newest)],
                group: "Worktrees of \(repoName)",
                lastUsed: info.lastChange,
                action: .gitWorktree(repository: info.repository),
                blockingProcesses: [],
                details: info.changedFiles.isEmpty ? "" : "Changed: " + info.changedFiles.prefix(8).joined(separator: ", ")
                    + (info.changedFiles.count > 8 ? "…" : ""))
        }
    }

    /// Blocking: runs a few git commands in the worktree.
    static func inspect(_ path: String) -> Info? {
        let common = Command.run("git", ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"], timeout: 10)
        guard common.ok else {
            return Info(path: path, repository: path, branch: "?", changedFiles: [], merged: false,
                        lastChange: DiskIO.modified(path), valid: false)
        }
        let repo = common.output.hasSuffix("/.git") ? String(common.output.dropLast(5)) : common.output
        let branch = Command.run("git", ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"], timeout: 10).output
        let status = Command.run("git", ["-C", path, "status", "--porcelain", "--untracked-files=normal"], timeout: 30)
        let changed = status.ok ? status.output.split(separator: "\n").map { String($0.dropFirst(3)) } : ["(status unavailable)"]

        // Default branch: origin/HEAD, else main, else master.
        var base = Command.run("git", ["-C", repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], timeout: 10).output
        if base.isEmpty || base.contains("fatal") {
            base = Command.run("git", ["-C", repo, "rev-parse", "--verify", "--quiet", "main"], timeout: 10).ok ? "main" : "master"
        }
        // The worktree's own HEAD (`-C <worktree>`), not the main checkout's.
        let merged = Command.run("git", ["-C", path, "merge-base", "--is-ancestor", "HEAD", base], timeout: 10).ok

        let commitTime = Double(Command.run("git", ["-C", path, "log", "-1", "--format=%ct"], timeout: 10).output)
            .map { Date(timeIntervalSince1970: $0) }
        let gitDir = Command.run("git", ["-C", path, "rev-parse", "--path-format=absolute", "--git-dir"], timeout: 10).output
        let indexTime = DiskIO.modified(gitDir + "/index")
        let lastChange = [commitTime, indexTime].compactMap { $0 }.max()

        return Info(path: path, repository: repo, branch: branch.isEmpty ? "HEAD" : branch,
                    changedFiles: changed, merged: merged, lastChange: lastChange, valid: true)
    }
}
