/// What MacSanity knows about one installed app (or a bundle nested inside one:
/// helpers, login items, extensions). Built by `AppInventory`; pure data here.
public struct InstalledApp: Sendable, Hashable {
    public var bundleID: String
    /// `CFBundleName`, `CFBundleDisplayName`, `CFBundleExecutable` and the file
    /// name without ".app" — every name an app may use for its data folders.
    public var names: [String]
    public var teamID: String?
    public var appGroups: [String]

    public init(bundleID: String, names: [String], teamID: String? = nil, appGroups: [String] = []) {
        self.bundleID = bundleID
        self.names = names
        self.teamID = teamID
        self.appGroups = appGroups
    }
}

/// Fast lookup structure over the installed apps.
public struct AppIndex: Sendable {
    let bundleIDs: Set<String>                 // lowercased
    let names: Set<String>                     // normalized
    let vendors: Set<String>                   // lowercased "com.google"
    let vendorNames: Set<String>               // normalized "google"
    let groups: Set<String>                    // lowercased app-group IDs
    let teams: Set<String>                     // team IDs

    public init(_ apps: [InstalledApp]) {
        var ids = Set<String>(), names = Set<String>(), vendors = Set<String>()
        var vendorNames = Set<String>(), groups = Set<String>(), teams = Set<String>()
        for app in apps {
            let id = app.bundleID.lowercased()
            ids.insert(id)
            let parts = id.split(separator: ".")
            if parts.count >= 3 {
                vendors.insert(parts.prefix(2).joined(separator: "."))
                let vendor = OrphanMatcher.normalize(String(parts[1]))
                if vendor.count >= 3 { vendorNames.insert(vendor) }
            }
            for n in app.names {
                let norm = OrphanMatcher.normalize(n)
                if !norm.isEmpty { names.insert(norm) }
            }
            for g in app.appGroups { groups.insert(g.lowercased()) }
            if let t = app.teamID { teams.insert(t) }
        }
        bundleIDs = ids; self.names = names; self.vendors = vendors
        self.vendorNames = vendorNames; self.groups = groups; self.teams = teams
    }

    /// The bundle ID is installed, or is a helper/extension of one that is
    /// (`com.spotify.client.helper`), or an installed app is nested under it.
    func ownsBundleID(_ id: String) -> Bool {
        let id = id.lowercased()
        if bundleIDs.contains(id) { return true }
        var parts = id.split(separator: ".")
        while parts.count > 2 {
            parts.removeLast()
            if bundleIDs.contains(parts.joined(separator: ".")) { return true }
        }
        return bundleIDs.contains { $0.hasPrefix(id + ".") }
    }
}

/// How a library folder relates to the installed apps.
public enum Ownership: Equatable, Sendable {
    /// Belongs to an installed app, a known tool, or macOS — never suggested.
    case owned
    /// Something wrote to it recently, so something still uses it.
    case inUse
    /// Probably left behind by an app that is no longer installed.
    case orphan(Confidence, appHint: String)

    public enum Confidence: Int, Comparable, Sendable {
        case low, medium, high
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }
}

/// The kind of library location a folder was found in. Exact-identifier
/// locations (containers, preference plists, saved state) give high confidence.
public enum LibraryLocation: Sendable {
    case container          // ~/Library/Containers/<id> — id from metadata plist
    case groupContainer     // ~/Library/Group Containers/<team>.<group>
    case preferences        // ~/Library/Preferences/<id>.plist
    case savedState         // ~/Library/Saved Application State/<id>.savedState
    case named              // Application Support, Caches, Logs, HTTPStorages, WebKit, …
    case launchItem         // handled by the background-items detector
    case homeDotFolder      // ~/.<name>
}

/// Decides whether a library entry is a leftover of a removed app.
///
/// Built to avoid the classic cleaner false positives:
/// - folders named by an app's *internal* name (VS Code stores data in "Code"),
/// - variants of an installed app's name ("Claude-3p" belongs to Claude),
/// - vendor folders shared by several apps ("Google", "Microsoft"),
/// - helpers and extensions with their own bundle IDs,
/// - Apple's and command-line tools' own folders,
/// - anything still being written to.
public enum OrphanMatcher {
    /// Folders modified within this many days are treated as in use.
    public static let inUseDays: Double = 30

    public static func classify(
        name rawName: String,
        location: LibraryLocation,
        identifier: String? = nil,
        modifiedDaysAgo: Double,
        index: AppIndex
    ) -> Ownership {
        let name = strippedName(rawName, location: location)
        let id = identifier ?? name
        let lowerID = id.lowercased()
        let normalizedName = normalize(name)

        if normalizedName.isEmpty || isSystemOrTool(lowerID: lowerID, normalized: normalizedName) {
            return .owned
        }

        // Group containers: "<TEAMID>.group.x", "group.x" or "<TEAMID>.x".
        if location == .groupContainer {
            if index.groups.contains(lowerID) { return .owned }
            let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2, isTeamID(parts[0]) {
                if index.groups.contains(parts[1].lowercased()) { return .owned }
                if index.teams.contains(parts[0]) { return .owned }   // same developer still installed
            }
            if looksLikeBundleID(lowerID), index.ownsBundleID(lowerID) { return .owned }
            return recentlyUsed(modifiedDaysAgo) ? .inUse : .orphan(.medium, appHint: displayHint(id))
        }

        if looksLikeBundleID(lowerID) {
            if index.ownsBundleID(lowerID) { return .owned }
            let parts = lowerID.split(separator: ".")
            // Last component may itself be the app's name ("com.foo.Spotify").
            if let last = parts.last, index.names.contains(normalize(String(last))) { return .owned }
            if recentlyUsed(modifiedDaysAgo) { return .inUse }
            // Another app from the same vendor is installed: could be a shared
            // component (updater, framework) — never more than "uncertain".
            if parts.count >= 3, index.vendors.contains(parts.prefix(2).joined(separator: ".")) {
                return .orphan(.low, appHint: displayHint(id))
            }
            switch location {
            case .container, .preferences, .savedState: return .orphan(.high, appHint: displayHint(id))
            default: return .orphan(.medium, appHint: displayHint(id))
            }
        }

        // Name-based folders ("Spotify", "Code", "Claude-3p", ".velox").
        if ownsName(normalizedName, index: index) { return .owned }
        if recentlyUsed(modifiedDaysAgo) { return .inUse }
        return .orphan(.low, appHint: name)
    }

    /// Name match against installed apps: exact (internal names included), an
    /// installed name being a prefix ("claude3p" ← "claude"), the folder being a
    /// prefix of an installed name ("google" → "googlechrome"), or a vendor name.
    static func ownsName(_ n: String, index: AppIndex) -> Bool {
        if index.names.contains(n) || index.vendorNames.contains(n) { return true }
        for installed in index.names where installed.count >= 4 {
            if n.hasPrefix(installed) || installed.hasPrefix(n) && n.count >= 4 { return true }
        }
        return false
    }

    /// Lowercase, keep only letters and digits.
    public static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { AlnumFilter.contains($0) }.map(Character.init))
    }

    static func strippedName(_ name: String, location: LibraryLocation) -> String {
        var n = name
        if location == .homeDotFolder, n.hasPrefix(".") { n.removeFirst() }
        for suffix in [".plist", ".savedState", ".binarycookies", ".ShipIt", ".lockfile"] where n.hasSuffix(suffix) {
            n.removeLast(suffix.count)
        }
        return n
    }

    /// Reverse-DNS: at least three components, or two with a known TLD-style first.
    static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && !$0.contains(" ") }) else { return false }
        if parts.count >= 3 { return true }
        return ["com", "org", "net", "io", "app", "dev", "co", "ai", "de", "se", "uk", "me", "us"].contains(String(parts[0]))
    }

    static func isTeamID(_ s: String) -> Bool {
        s.count == 10 && s.allSatisfy { $0.isUppercase || $0.isNumber }
    }

    static func recentlyUsed(_ days: Double) -> Bool { days < inUseDays }

    static func isSystemOrTool(lowerID: String, normalized: String) -> Bool {
        if lowerID.hasPrefix("com.apple.") || lowerID.hasPrefix("group.com.apple.") || lowerID.contains(".com.apple.") {
            return true
        }
        return KnownFolders.systemAndTools.contains(normalized)
    }

    /// The most app-like part of a bundle ID: the last component after the
    /// top-level domain that isn't a generic word ("ai.opencode.desktop" →
    /// "opencode", "com.spotify.client.helper" → "spotify").
    public static func displayHint(_ id: String) -> String {
        var parts = id.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return id }
        if isTeamID(parts[0]) { parts.removeFirst() }
        if parts.first?.lowercased() == "group" { parts.removeFirst() }
        // Everything from the first generic component on describes a sub-part of
        // the app ("com.microsoft.Headlamp.helper.GPU" → "com.microsoft.Headlamp").
        if let cut = parts.dropFirst(2).firstIndex(where: { genericComponents.contains($0.lowercased()) }) {
            parts = Array(parts[..<cut])
        }
        let meaningful = parts.dropFirst().filter { !genericComponents.contains($0.lowercased()) && $0.count > 1 }
        return meaningful.last ?? parts.dropFirst().first ?? id
    }

    static let genericComponents: Set<String> = [
        "app", "apps", "client", "desktop", "mac", "macos", "osx", "helper", "helpers", "agent", "launcher",
        "daemon", "service", "services", "xpc", "plugin", "plugins", "gpu", "renderer", "core", "product",
        "extension", "widget", "shipit", "main", "beta", "plist", "savedstate", "loginhelper", "updater",
    ]
}

/// Folder names that belong to macOS itself or to developer/CLI tools (handled by
/// the Developer catalog), normalized with `OrphanMatcher.normalize`.
public enum KnownFolders {
    public static let systemAndTools: Set<String> = Set([
        // macOS / Apple components that use plain names.
        "addressbook", "callhistorydb", "callhistorytransactions", "clouddocs", "crashreporter",
        "dock", "fileprovider", "icdd", "knowledge", "mobilesync", "syncservices", "animoji",
        "accounts", "applemediaservices", "cloudkit", "familycircle", "geoservices", "homekit",
        "networkserviceproxy", "quicklook", "siri", "spotlight", "tipsd", "contextstoreagent",
        "diagnosticreports", "dmd", "ammosrv", "ckwitness", "pointerevents", "sharedfilelist",
        "stickers", "videoconference", "voicetrigger", "assistant", "audio", "colorpickers",
        "compositions", "coreparsec", "fonts", "keyboardservices", "metadata", "personas",
        "screensavers", "sounds", "telephonyutilities", "webkit", "familysettings", "fsevents",
        "caches", "logs", "preferences", "containers", "temp", "tmp",
        "logic", "garageband", "mainstage", "appleloops", "proapps", "finalcutpro", "motion", "compressor",
        "imovie", "ilife", "iwork", "keynote", "pages", "numbers", "safari", "mail", "photos", "music",
        "podcasts", "books", "news", "maps", "notes", "reminders", "calendar", "contacts", "facetime",
        "askpermissiond", "swiftfrontend", "dmd", "coreduet", "corespeech", "coreaudio",
        "passkit", "familycircled", "cloudkitd", "appstore", "storekit", "screentime", "location",
        "colorsync", "printing", "cups", "searchparty", "findmy", "weather", "stocks", "translation",
        // Developer and CLI tools (sized in the Developer section instead).
        "gobuild", "go", "pip", "pypoetry", "uv", "homebrew", "yarn", "pnpm", "nodegyp", "npm",
        "msplaywright", "cocoapods", "carthage", "jetbrains", "orgswiftswiftpm", "typescript",
        "deno", "bun", "cargo", "rustup", "gradle", "m2", "conda", "pyenv", "rbenv", "nvm", "vscode",
        "cache", "config", "local", "zsh", "zshsessions", "oh-my-zsh", "ohmyzsh", "git", "ssh",
        "gnupg", "docker", "kube", "aws", "claude", "copilot", "codex", "cursor", "ollama",
        "terraform", "terraformd", "tofu", "android", "dotnet", "nuget", "gem", "bundle",
        "swiftpm", "xcode", "zprofile", "bashsessions", "lesshst", "viminfo", "python",
    ].map { OrphanMatcher.normalize($0) })
}

/// Letters and digits, without pulling Foundation into the core target.
enum AlnumFilter {
    static func contains(_ s: Unicode.Scalar) -> Bool {
        s.properties.isAlphabetic || ("0"..."9").contains(s)
    }
}
