/// Finds superseded versions among sibling folders: tools that keep every version
/// they ever downloaded ("github-copilot-git-2.53.0-4" next to "…-2.56.0-2",
/// Playwright's "chromium-1091" next to "chromium-1105", JetBrains'
/// "IntelliJIdea2024.1" next to "IntelliJIdea2025.2", VS Code extensions
/// "ms-python.python-2024.2.1-darwin-arm64" next to a newer one).
public enum VersionedSiblings {
    public struct Parsed: Equatable, Sendable {
        public let stem: String
        public let version: [Int]
        public let suffix: String
    }

    /// Names whose stem+suffix group has a newer version present. The newest of
    /// each group is always kept; unversioned names are never returned.
    public static func superseded(_ names: [String]) -> Set<String> {
        var groups: [String: [(name: String, version: [Int])]] = [:]
        for name in names {
            guard let p = parse(name) else { continue }
            groups[p.stem.lowercased() + "\u{0}" + p.suffix.lowercased(), default: []].append((name, p.version))
        }
        var result = Set<String>()
        for members in groups.values where members.count > 1 {
            let newest = members.max { compare($0.version, $1.version) < 0 }!
            for m in members where m.name != newest.name && compare(m.version, newest.version) < 0 {
                result.insert(m.name)
            }
        }
        return result
    }

    /// Split "stem<sep>1.2.3[-4]<suffix>". The version must start right after a
    /// separator ("-", "_", "@", " ") or a letter→digit boundary, and contain at
    /// least one digit group. Returns nil for unversioned names.
    public static func parse(_ name: String) -> Parsed? {
        let chars = Array(name)
        var i = 1
        while i < chars.count {
            let prev = chars[i - 1]
            if chars[i].isASCIIDigit && (["-", "_", "@", " "].contains(prev) || prev.isLetter) {
                var j = i
                while j < chars.count, chars[j].isASCIIDigit || ((chars[j] == "." || chars[j] == "-" || chars[j] == "_")
                                                                 && j + 1 < chars.count && chars[j + 1].isASCIIDigit) {
                    j += 1
                }
                let versionText = String(chars[i..<j])
                let numbers = versionText.split(whereSeparator: { !$0.isASCIIDigit }).compactMap { Int($0) }
                var stem = String(chars[0..<i])
                if let last = stem.last, ["-", "_", "@", " "].contains(last) { stem.removeLast() }
                if !numbers.isEmpty && !stem.isEmpty {
                    return Parsed(stem: stem, version: numbers, suffix: String(chars[j...]))
                }
            }
            i += 1
        }
        return nil
    }

    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for k in 0..<max(a.count, b.count) {
            let x = k < a.count ? a[k] : 0, y = k < b.count ? b[k] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
