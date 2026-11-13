import Foundation
import MacSanityCore

/// macOS restore images, update downloads and installers, plus disk images and
/// packages in Downloads for apps that are already installed.
struct InstallersDetector: Detector {
    let category = CleanerCategory.installers

    func scan(_ ctx: ScanContext) async -> [Finding] {
        var candidates: [(path: String, title: String, reason: String, safety: Safety, after: String, group: String)] = []

        // Restore images / firmware downloaded by Finder, Apple Configurator, etc.
        for dir in ["Mac Software Updates", "iPhone Software Updates", "iPad Software Updates", "iPod Software Updates"] {
            for file in DiskIO.children(of: ctx.home + "/Library/iTunes/" + dir) where file.hasSuffix(".ipsw") {
                let name = (file as NSString).lastPathComponent
                let version = Policies.osVersion(fromInstallerName: name)
                let isMac = dir.hasPrefix("Mac")
                let safety = isMac ? Policies.installerSafety(installerVersion: version, runningVersion: ctx.osVersion) : .safe
                let versionText = version.map { $0.map(String.init).joined(separator: ".") } ?? "unknown version"
                let reason = !isMac ? "Device firmware"
                    : safety == .safe ? "macOS \(versionText) · already installed"
                    : "macOS \(versionText) · not installed yet"
                candidates.append((file, name, reason, safety, "Downloaded again if you restore a device or install this update.",
                                   "Restore images"))
            }
        }

        // Update assets staged in the per-user temp folder.
        if let t = ctx.userVarFolder.map({ $0 + "/T/Mac-Temporary-Files.noindex" }), DiskIO.isDirectory(t) {
            candidates.append((t, "macOS update download", "Update download",
                               .review, "If an update is in progress it downloads again.", "macOS updates"))
        }

        // System-wide update and installer leftovers.
        for path in DiskIO.children(of: "/Library/Updates") where !path.hasSuffix(".plist") {
            candidates.append((path, (path as NSString).lastPathComponent, "Update leftover",
                               .review, "Downloaded again by Software Update if still needed.", "macOS updates"))
        }
        if DiskIO.isDirectory("/macOS Install Data") {
            candidates.append(("/macOS Install Data", "macOS Install Data", "Upgrade leftover",
                               .safe, "Nothing — the upgrade it belonged to is finished.", "macOS updates"))
        }
        for app in DiskIO.children(of: "/Applications") where (app as NSString).lastPathComponent.hasPrefix("Install macOS") {
            candidates.append((app, (app as NSString).lastPathComponent, "macOS installer",
                               .review, "Download it again from the App Store if you need it.", "macOS installers"))
        }

        // Disk images / packages in Downloads.
        for file in DiskIO.children(of: ctx.home + "/Downloads") {
            let lower = file.lowercased()
            guard lower.hasSuffix(".dmg") || lower.hasSuffix(".pkg") || lower.hasSuffix(".mpkg") else { continue }
            let name = (file as NSString).lastPathComponent
            let installed = Self.installedApp(forInstaller: (name as NSString).deletingPathExtension, ctx: ctx)
            let days = ctx.days(since: DiskIO.modified(file))
            if let installed {
                candidates.append((file, name, "\(installed.name) is installed",
                                   .safe, "Nothing — the app stays installed.", "Installers in Downloads"))
            } else if days >= 30 {
                candidates.append((file, name, "\(RelativeTime.describe(days: days)) old",
                                   .review, "Download it again if you need it.", "Installers in Downloads"))
            }
        }

        let sizes = await DiskIO.sizes(candidates.map(\.path), cancel: ctx.cancel)
        return Self.findings(candidates, sizes: sizes, ctx: ctx)
    }

    /// The installed app an installer file is for: one of the app's names (at
    /// least 4 characters) must be the start of the file name, followed by a
    /// version or separator — "wordcraft-0.14.0-macos.dmg" → WordCraft, but
    /// "Game_Porting_Toolkit.dmg" doesn't match "Games". Longest name wins.
    static func installedApp(forInstaller stem: String, ctx: ScanContext) -> AppRecord? {
        let file = OrphanMatcher.normalize(stem)
        var best: (app: AppRecord, length: Int)?
        for app in ctx.inventory.apps where !app.path.hasPrefix("/System/") {
            for name in app.names {
                let n = OrphanMatcher.normalize(name)
                guard n.count >= 4, file.hasPrefix(n) else { continue }
                let rest = file.dropFirst(n.count)
                // Next character must start a version/platform part, not continue a word.
                guard rest.isEmpty || rest.first!.isNumber || ["macos", "mac", "osx", "universal", "arm64", "darwin", "setup", "installer"]
                    .contains(where: { rest.hasPrefix($0) }) else { continue }
                if n.count > (best?.length ?? 0) { best = (app, n.count) }
            }
        }
        return best?.app
    }

    private static func findings(_ candidates: [(path: String, title: String, reason: String, safety: Safety, after: String, group: String)],
                                 sizes: [String: TreeSize], ctx: ScanContext) -> [Finding] {
        let category = CleanerCategory.installers
        return candidates.compactMap { c in
            guard let size = sizes[c.path], size.allocated > 0, ctx.isRemovable(c.path) else { return nil }
            // Still being written (a download in progress): leave it alone.
            if let newest = size.newest, ctx.now.timeIntervalSince(newest) < 600 { return nil }
            return Finding(
                id: Finding.makeID(category, c.path), category: category, title: c.title, reason: c.reason,
                afterRemoval: c.after, safety: c.safety,
                items: [FindingItem(path: c.path, size: size.allocated, modified: size.newest)],
                group: c.group, lastUsed: size.newest, action: .trash,
                needsAdmin: DiskIO.ownerUID(c.path) != ctx.uid)
        }
    }
}
