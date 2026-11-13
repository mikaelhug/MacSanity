import CoreServices
import Foundation
import MacSanityCore
import Security

/// One installed application as shown to the user (top-level `.app` bundles).
struct AppRecord: Sendable, Hashable {
    let path: String
    let bundleID: String
    let name: String
    /// Every name the app goes by (CFBundleName, executable, …), for matching folders.
    let names: [String]
    let lastUsed: Date?
    let isApple: Bool
}

/// Everything installed on this Mac: the ground truth for "is this app still
/// here?". Includes every nested bundle (helpers, login items, XPC services,
/// extensions) because those own data folders and containers too.
struct AppInventory: Sendable {
    let apps: [AppRecord]
    let index: AppIndex
    /// Lowercased bundle IDs of everything (top-level and nested).
    let allBundleIDs: Set<String>

    func isInstalled(bundleID: String) -> Bool { allBundleIDs.contains(bundleID.lowercased()) }

    /// Builds the inventory: Spotlight (finds apps anywhere) ∪ a direct walk of
    /// the standard application folders (works even if Spotlight is off).
    static func load(home: String) async -> AppInventory {
        await DiskIO.run {
            var paths = Set<String>()
            for root in ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                         "/Applications/Utilities", home + "/Applications", "/System/Library/CoreServices",
                         "/Library/Application Support", home + "/Applications/Chrome Apps.localized"] {
                for child in DiskIO.children(of: root) {
                    if child.hasSuffix(".app") { paths.insert(child) }
                    // One level deeper (vendor folders: "/Applications/Setapp/X.app",
                    // "/Library/Application Support/Vendor/Helper.app").
                    else if DiskIO.isDirectory(child) {
                        for grandchild in DiskIO.children(of: child) where grandchild.hasSuffix(".app") {
                            paths.insert(grandchild)
                        }
                    }
                }
            }
            for p in spotlightApps() where !isExcluded(p, home: home) { paths.insert(p) }

            var records: [AppRecord] = []
            var installed: [InstalledApp] = []
            var allIDs = Set<String>()
            for path in paths.sorted() {
                guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else { continue }
                let info = bundle.infoDictionary ?? [:]
                let fileName = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
                let names = [info["CFBundleName"], info["CFBundleDisplayName"], info["CFBundleExecutable"]]
                    .compactMap { $0 as? String } + [fileName]
                let signing = signingInfo(path)
                installed.append(InstalledApp(bundleID: id, names: names, teamID: signing.team, appGroups: signing.groups))
                allIDs.insert(id.lowercased())
                records.append(AppRecord(path: path, bundleID: id, name: fileName, names: names, lastUsed: lastUsedDate(path),
                                         isApple: id.hasPrefix("com.apple.")))
                for nested in nestedBundles(path) {
                    guard let b = Bundle(path: nested), let nid = b.bundleIdentifier else { continue }
                    let nInfo = b.infoDictionary ?? [:]
                    let nNames = [nInfo["CFBundleName"], nInfo["CFBundleExecutable"]].compactMap { $0 as? String }
                    let nSigning = nested.hasSuffix(".appex") ? signingInfo(nested) : (signing.team, [])
                    installed.append(InstalledApp(bundleID: nid, names: nNames, teamID: nSigning.0, appGroups: nSigning.1))
                    allIDs.insert(nid.lowercased())
                }
            }
            // Only top-level, user-visible apps (not ones nested inside other apps).
            let topLevel = records.filter { r in !records.contains { $0.path != r.path && r.path.hasPrefix($0.path + "/") } }
            return AppInventory(apps: topLevel, index: AppIndex(installed), allBundleIDs: allIDs)
        }
    }

    // MARK: Sources

    private static func spotlightApps() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemContentType == 'com.apple.application-bundle'"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Simulator runtimes and device images contain thousands of iOS apps that
    /// aren't Mac apps; the Trash holds removed ones.
    private static func isExcluded(_ path: String, home: String) -> Bool {
        path.contains("/CoreSimulator/") || path.contains("/.Trash/") || path.contains("/Developer/Platforms/")
            || path.hasPrefix("/Library/Developer/") || path.contains(".xcarchive/") || path.hasPrefix("/private/var/")
            || path.hasPrefix("/System/Library/Templates/") || path.contains("/Backups.backupdb/")
    }

    private static func nestedBundles(_ appPath: String) -> [String] {
        var result: [String] = []
        let contents = appPath + "/Contents"
        for sub in ["Library/LoginItems", "Library/LaunchServices", "Helpers", "XPCServices", "PlugIns",
                    "Library/SystemExtensions", "Frameworks", "Applications", "MacOS"] {
            for child in DiskIO.children(of: contents + "/" + sub) {
                if child.hasSuffix(".app") || child.hasSuffix(".appex") || child.hasSuffix(".xpc") || child.hasSuffix(".systemextension") {
                    result.append(child)
                } else if child.hasSuffix(".framework") {
                    // Electron/Chromium helpers live in Frameworks/*.framework/Helpers.
                    for h in DiskIO.children(of: child + "/Helpers") + DiskIO.children(of: child + "/Versions/Current/Helpers")
                    where h.hasSuffix(".app") { result.append(h) }
                }
            }
        }
        return result
    }

    private static func signingInfo(_ path: String) -> (team: String?, groups: [String]) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return (nil, []) }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return (nil, []) }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []
        return (team, groups)
    }

    private static func lastUsedDate(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
