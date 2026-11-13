/// Small, pure decision rules used by the detectors. Kept here so every threshold
/// is checked in one place (`swift run CleanerCheck`).
public enum Policies {
    // MARK: Git worktrees

    /// Clean + merged + idle ≥ 7 days → safe; clean but unmerged or recent → review;
    /// uncommitted changes → careful.
    public static func worktreeSafety(clean: Bool, merged: Bool, daysSinceChange: Double, inUse: Bool = false) -> Safety {
        guard clean, !inUse else { return .careful }
        return merged && daysSinceChange >= 7 ? .safe : .review
    }

    // MARK: Temporary files

    /// Temp items untouched this long are suggested.
    public static let tempMinAgeDays: Double = 3
    /// Coding-agent session folders active this recently are never selected.
    public static let agentSessionActiveHours: Double = 24

    public static func tempSafety(daysSinceChange: Double, openByProcess: Bool) -> Safety? {
        if openByProcess { return nil }
        return daysSinceChange >= tempMinAgeDays ? .safe : nil
    }

    public static func agentSessionSafety(hoursSinceActivity: Double) -> Safety {
        hoursSinceActivity >= agentSessionActiveHours ? .safe : .careful
    }

    // MARK: Installers and updates

    /// Parse the OS version out of a restore image / installer name, e.g.
    /// "UniversalMac_27.2.1_26B131_Restore.ipsw" → [27, 2, 1].
    public static func osVersion(fromInstallerName name: String) -> [Int]? {
        for token in name.split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "-" }) {
            let parts = token.split(separator: ".")
            if parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) {
                return parts.compactMap { Int($0) }
            }
        }
        return nil
    }

    /// An installer for the running OS or older is safe; a newer one is likely a
    /// pending update — review. Unknown version → review.
    public static func installerSafety(installerVersion: [Int]?, runningVersion: [Int]) -> Safety {
        guard let v = installerVersion else { return .review }
        return VersionedSiblings.compare(v, runningVersion) <= 0 ? .safe : .review
    }

    // MARK: Projects

    /// Build artifacts of projects untouched this long are preselected.
    public static let staleProjectDays: Double = 30

    public static func projectArtifactSafety(daysSinceProjectChange: Double) -> Safety {
        daysSinceProjectChange >= staleProjectDays ? .safe : .review
    }

    // MARK: Apps

    public static let unusedAppDays: Double = 180
    public static let unusedCacheOwnerDays: Double = 90
    public static let largeFileBytes: Int64 = 500_000_000
    public static let oldDownloadDays: Double = 90
}
