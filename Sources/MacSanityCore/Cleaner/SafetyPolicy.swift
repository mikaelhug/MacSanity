/// The cleaner's hard safety boundary. Every path is checked here before it can be
/// shown as selectable and again right before it is moved — whatever a rule or
/// detector claims. Pure string logic over absolute, standardized paths, so it is
/// fully checkable without touching the disk (`swift run CleanerCheck`).
///
/// Two layers:
/// 1. **Allowed scopes** (allowlist): only paths *strictly inside* one of these
///    roots may ever be removed. Everything else — /System, /usr, other volumes,
///    unknown locations — is denied by default.
/// 2. **Protected locations** (denylist): personal data and OS state inside the
///    allowed scopes that must never be touched, nor any folder that *contains*
///    one of them.
public struct SafetyPolicy: Sendable {
    public enum Verdict: Equatable, Sendable {
        case allowed
        case denied(String)
    }

    public let home: String
    /// The per-user `/private/var/folders/xx/…` directory (parent of `T` and `C`).
    public let userVarFolder: String?

    private let allowedRoots: [String]
    private let protectedPaths: [String]
    private let protectedNamePrefixes: [(parent: String, prefix: String)]
    private let protectedSuffixes: [String]
    private let containerRoots: Set<String>

    public init(home: String, userVarFolder: String? = nil) {
        let home = Self.trimTrailingSlash(home)
        self.home = home
        self.userVarFolder = userVarFolder.map(Self.trimTrailingSlash)

        var allowed = [
            home,
            "/private/tmp",
            "/Applications",
            "/Library/Caches",
            "/Library/Logs",
            "/Library/Application Support",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
            "/Library/PrivilegedHelperTools",
            "/Library/Updates",
            "/macOS Install Data",
        ]
        if let v = self.userVarFolder {
            allowed.append(v + "/T")
            allowed.append(v + "/C")
        }
        allowedRoots = allowed

        let lib = home + "/Library"
        protectedPaths = [
            // Cloud-synced and account data.
            lib + "/Mobile Documents", lib + "/CloudStorage", lib + "/Accounts",
            lib + "/Keychains", lib + "/Mail", lib + "/Messages", lib + "/Calendars",
            lib + "/Safari", lib + "/Suggestions", lib + "/Photos", lib + "/IdentityServices",
            lib + "/Application Support/AddressBook",
            lib + "/Application Support/CallHistoryDB",
            lib + "/Application Support/com.apple.TCC",
            lib + "/Application Support/MacSanity",    // our own history
            // Credentials and identities.
            home + "/.ssh", home + "/.gnupg", home + "/.aws", home + "/.kube",
            home + "/.docker", home + "/.config/gcloud", home + "/.password-store",
            // Never the Trash itself.
            home + "/.Trash",
            // Apple's own apps and the system's admin data.
            "/Applications/Safari.app", "/Applications/Utilities",
            "/Library/Application Support/Apple", "/Library/Application Support/com.apple.TCC",
            "/Library/Application Support/CrashReporter",
        ]
        protectedNamePrefixes = [
            (lib + "/Containers", "com.apple."),
            (lib + "/Group Containers", "group.com.apple."),
            (lib + "/Preferences", "com.apple."),
            (lib + "/Application Support", "com.apple."),
            (lib + "/Caches", "com.apple."),
            ("/Library/LaunchDaemons", "com.apple."),
            ("/Library/LaunchAgents", "com.apple."),
            ("/Library/Application Support", "com.apple."),
            ("/Library/Caches", "com.apple."),
        ]
        protectedSuffixes = [".photoslibrary", ".musiclibrary", ".tvlibrary", ".keychain-db", ".keychain"]

        // Folders that are only ever *containers* of findings: never removable
        // themselves, only their children.
        var roots: Set<String> = Set(allowed)
        for name in ["Library", "Desktop", "Documents", "Downloads", "Pictures", "Music",
                     "Movies", "Public", "Applications", "Developer", ".cache", ".config", ".local"] {
            roots.insert(home + "/" + name)
        }
        for name in ["Caches", "Application Support", "Containers", "Group Containers", "Preferences",
                     "Logs", "LaunchAgents", "Saved Application State", "HTTPStorages", "WebKit",
                     "Cookies", "Application Scripts", "Developer", "iTunes", "Fonts"] {
            roots.insert(lib + "/" + name)
        }
        containerRoots = roots
    }

    public func check(_ path: String) -> Verdict {
        guard path.hasPrefix("/") else { return .denied("not an absolute path") }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0 == ".." || $0 == "." }) {
            return .denied("path is not normalized")
        }
        if path.count > 1 && path.hasSuffix("/") { return check(String(path.dropLast())) }

        if containerRoots.contains(path) { return .denied("a top-level folder can't be removed") }
        guard allowedRoots.contains(where: { Self.isInside(path, $0) }) else {
            return .denied("outside the locations MacSanity may clean")
        }
        for p in protectedPaths {
            if path == p || Self.isInside(path, p) { return .denied("protected location") }
            if Self.isInside(p, path) { return .denied("contains a protected location") }
        }
        for (parent, prefix) in protectedNamePrefixes where Self.isInside(path, parent) {
            let rest = path.dropFirst(parent.count + 1)
            let first = rest.split(separator: "/").first.map(String.init) ?? ""
            if first.hasPrefix(prefix) { return .denied("belongs to macOS") }
            // Group containers are "TEAMID.group.com.apple…" too.
            if parent.hasSuffix("/Group Containers"), first.contains(".com.apple.") {
                return .denied("belongs to macOS")
            }
        }
        for suffix in protectedSuffixes where components.contains(where: { $0.hasSuffix(suffix) }) {
            return .denied("inside a protected library")
        }
        if let v = userVarFolder, Self.isInside(path, "/private/var/folders"),
           !(Self.isInside(path, v + "/T") || Self.isInside(path, v + "/C")) {
            return .denied("system temporary area")
        }
        return .allowed
    }

    /// `path` is strictly below `root`.
    public static func isInside(_ path: String, _ root: String) -> Bool {
        path.count > root.count && path.hasPrefix(root) && path[path.index(path.startIndex, offsetBy: root.count)] == "/"
    }

    private static func trimTrailingSlash(_ s: String) -> String {
        s.count > 1 && s.hasSuffix("/") ? String(s.dropLast()) : s
    }
}
