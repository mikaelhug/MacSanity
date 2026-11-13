import Foundation
import MacSanityCore

/// Build output and dependency folders inside your projects (`target`,
/// `node_modules`, `.build`, `.venv`, …). Projects you haven't worked on for a
/// month are preselected; active ones are listed but left unselected.
struct ProjectsDetector: Detector {
    let category = CleanerCategory.projects

    func scan(_ ctx: ScanContext) async -> [Finding] {
        let kinds = Dictionary(uniqueKeysWithValues: Catalog.projectKinds.map { ($0.name, $0) })
        var perProject: [(project: HomeWalk.Project, artifacts: [String])] = []
        for project in ctx.homeWalk.projects {
            var artifacts: [String] = []
            for kindName in project.kinds {
                for artifact in kinds[kindName]?.artifacts ?? [] {
                    let path = project.path + "/" + artifact
                    if DiskIO.isDirectory(path), !DiskIO.isSymlink(path), Self.looksLikeArtifact(path, kind: kindName),
                       ctx.isRemovable(path), !artifacts.contains(path) {
                        artifacts.append(path)
                    }
                }
            }
            if !artifacts.isEmpty { perProject.append((project, artifacts)) }
        }

        let sizes = await DiskIO.sizes(perProject.flatMap(\.artifacts), cancel: ctx.cancel)
        let lastWorkedOn: [String: Date] = await withTaskGroup(of: (String, Date?).self) { group in
            for (project, _) in perProject {
                group.addTask { (project.path, await DiskIO.run { Self.lastWorkedOn(project) }) }
            }
            var result: [String: Date] = [:]
            for await (path, date) in group { if let date { result[path] = date } }
            return result
        }
        var findings: [Finding] = []
        for (project, artifacts) in perProject {
            let items = artifacts.compactMap { p -> FindingItem? in
                guard let s = sizes[p], s.allocated >= 1_000_000 else { return nil }
                return FindingItem(path: p, size: s.allocated, modified: s.newest)
            }
            guard !items.isEmpty else { continue }
            let lastWorked = lastWorkedOn[project.path]
            let days = ctx.days(since: lastWorked)
            let names = items.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
            let rel = project.path.hasPrefix(ctx.home + "/") ? String(project.path.dropFirst(ctx.home.count + 1)) : project.path
            findings.append(Finding(
                id: Finding.makeID(category, project.path), category: category,
                title: (project.path as NSString).lastPathComponent,
                reason: "\(project.kinds.joined(separator: " + ")) build output · \(names)",
                afterRemoval: "Rebuilt or reinstalled on the next build (the first build takes longer).",
                safety: Policies.projectArtifactSafety(daysSinceProjectChange: days),
                items: items,
                group: (rel as NSString).deletingLastPathComponent.isEmpty ? "Home" : (rel as NSString).deletingLastPathComponent,
                lastUsed: lastWorked,
                action: .trash,
                blockingProcesses: Self.blockingProcesses(project.kinds)))
        }
        return findings
    }

    /// Extra evidence that a generically named folder really is build output.
    static func looksLikeArtifact(_ path: String, kind: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        switch (kind, name) {
        case ("Rust", "target"):
            return DiskIO.exists(path + "/CACHEDIR.TAG") || DiskIO.exists(path + "/.rustc_info.json") || DiskIO.exists(path + "/debug")
        case ("Maven", "target"):
            return DiskIO.exists(path + "/classes") || DiskIO.exists(path + "/maven-status") || DiskIO.exists(path + "/surefire-reports")
        case ("Swift", ".build"):
            return DiskIO.exists(path + "/workspace-state.json") || DiskIO.exists(path + "/checkouts") || DiskIO.exists(path + "/debug")
        case ("Python", ".venv"), ("Python", "venv"):
            return DiskIO.exists(path + "/pyvenv.cfg")
        case ("Gradle", "build"), ("Dart", "build"), ("CMake", "build"):
            return !DiskIO.exists(path + "/.git") && !DiskIO.exists(path + "/src")
        default:
            return true
        }
    }

    /// Newest of: last commit, and modification of non-artifact top-level entries.
    static func lastWorkedOn(_ project: HomeWalk.Project) -> Date? {
        var dates: [Date] = []
        if project.hasGit, let t = Double(Command.run("git", ["-C", project.path, "log", "-1", "--format=%ct"], timeout: 10).output) {
            dates.append(Date(timeIntervalSince1970: t))
        }
        let artifacts = Set(Catalog.projectKinds.flatMap(\.artifacts))
        for child in DiskIO.children(of: project.path) where !artifacts.contains((child as NSString).lastPathComponent) {
            if let m = DiskIO.modified(child) { dates.append(m) }
        }
        return dates.max()
    }

    static func blockingProcesses(_ kinds: [String]) -> [String] {
        var result: [String] = []
        for k in kinds {
            switch k {
            case "Rust": result += ["cargo", "rustc", "rust-analyzer"]
            case "Swift": result += ["swift-build", "swift-frontend"]
            case "Node.js": result += ["npm", "pnpm", "yarn", "bun"]
            case "Gradle": result += ["gradle"]
            case "Maven": result += ["mvn"]
            case "Python": result += ["pip", "pip3", "uv"]
            default: break
            }
        }
        return result
    }
}
