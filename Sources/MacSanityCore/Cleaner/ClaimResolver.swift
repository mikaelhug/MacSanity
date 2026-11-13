/// Makes sure every byte is counted once.
///
/// Different detectors legitimately find overlapping paths: a git worktree
/// contains a Rust `target/`, a temp folder contains a large file. The resolver:
/// - drops exact duplicates (the higher-priority category keeps the path),
/// - records which claims are *contained in* another claim.
/// Contained claims stay listed, but are only counted (and only removed) when
/// their container isn't selected — see `effectiveSelection`.
public struct ClaimResolver: Sendable {
    public struct Claim: Sendable, Equatable {
        public let id: String
        public let path: String
        public let priority: Int
        public init(id: String, path: String, priority: Int) {
            self.id = id; self.path = path; self.priority = priority
        }
    }

    /// Claims that survived duplicate removal.
    public private(set) var accepted: [Claim] = []
    /// id → id of the nearest accepted claim that contains it.
    public private(set) var containedIn: [String: String] = [:]

    public init(_ claims: [Claim]) {
        // Highest priority first; stable by path for determinism.
        let ordered = claims.sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.path < $1.path }
        var byPath: [String: Claim] = [:]
        for c in ordered where byPath[c.path] == nil { byPath[c.path] = c }
        accepted = byPath.values.sorted { $0.path < $1.path }

        // Sorted by path, every ancestor of a path precedes it; a stack of open
        // ancestors gives the nearest container in O(n log n).
        var stack: [Claim] = []
        for c in accepted {
            while let top = stack.last, !SafetyPolicy.isInside(c.path, top.path) { stack.removeLast() }
            if let parent = stack.last { containedIn[c.id] = parent.id }
            stack.append(c)
        }
    }

    /// The selected ids that actually need removing (and counting): those with
    /// no selected ancestor claim.
    public func effectiveSelection(_ selected: Set<String>) -> Set<String> {
        selected.filter { id in
            var current = containedIn[id]
            while let parent = current {
                if selected.contains(parent) { return false }
                current = containedIn[parent]
            }
            return true
        }
    }
}
