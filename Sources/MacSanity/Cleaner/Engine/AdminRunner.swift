import Foundation
import MacSanityCore

/// Runs a batch of root-level operations behind one standard macOS admin
/// password prompt (`do shell script … with administrator privileges`).
///
/// No privileged helper is installed and nothing stays running as root. The
/// script is passed inline (never via a file another process could swap), built
/// only from fixed command words plus paths/identifiers that were validated by
/// the safety policy and are single-quoted for the shell.
enum AdminRunner {
    enum Operation: Sendable {
        /// Move `source` to `destination` (inside the user's Trash) and give it
        /// to the user so it can be emptied or restored without the password.
        case moveToTrash(source: String, destination: String, uid: uid_t, gid: gid_t)
        /// Move back from the Trash and restore the original owner.
        case restore(trashPath: String, original: String, uid: UInt32, gid: UInt32)
        case bootoutSystem(label: String)
        case forgetReceipt(packageID: String)
        case deleteLocalSnapshot(date: String)
    }

    struct Failure: Error, Sendable { let message: String }

    /// Returns nil on success, or the error (including "User canceled").
    static func run(_ operations: [Operation]) -> Failure? {
        guard !operations.isEmpty else { return nil }
        let script: String
        switch shellScript(for: operations) {
        case .success(let s): script = s
        case .failure(let f): return f
        }
        let apple = "do shell script \"\(appleScriptEscape(script))\" with administrator privileges"
        let result = Command.run("/usr/bin/osascript", ["-e", apple], timeout: 600)
        if !result.ok { return Failure(message: result.output.isEmpty ? "Not authorized" : result.output) }
        if result.output.contains("FAILED") { return Failure(message: "Some system items could not be moved") }
        return nil
    }

    /// The /bin/sh script for a batch (exposed so it can be exercised without
    /// root in the self-test).
    static func shellScript(for operations: [Operation]) -> Result<String, Failure> {
        var lines: [String] = []
        for op in operations {
            switch op {
            case let .moveToTrash(source, destination, uid, gid):
                guard allowed(source), inTrash(destination) else { return .failure(Failure(message: "Refused an unsafe path")) }
                lines.append(move(source, destination, owner: "\(uid):\(gid)"))
            case let .restore(trashPath, original, uid, gid):
                // History is a user-writable file, so a restore is held to the same
                // rules as a removal: out of the Trash, into a location the policy allows.
                guard inTrash(trashPath), allowed(original) else { return .failure(Failure(message: "Refused an unsafe path")) }
                lines.append(move(trashPath, original, owner: "\(uid):\(gid)"))
            case let .bootoutSystem(label):
                guard identifier(label) else { return .failure(Failure(message: "Refused an unsafe label")) }
                lines.append("/bin/launchctl bootout system/\(q(label)) 2>/dev/null; true")
            case let .forgetReceipt(id):
                guard identifier(id) else { return .failure(Failure(message: "Refused an unsafe package id")) }
                lines.append("/usr/sbin/pkgutil --forget \(q(id))")
            case let .deleteLocalSnapshot(date):
                guard date.allSatisfy({ $0.isNumber || $0 == "-" }) else { return .failure(Failure(message: "Refused an unsafe snapshot")) }
                lines.append("/usr/bin/tmutil deletelocalsnapshots \(q(date))")
            }
        }
        // Each line runs even if an earlier one failed; failures are reported.
        return .success(lines.map { "{ \($0); } || echo FAILED" }.joined(separator: "; "))
    }

    /// Move only if the destination is free (never overwrite, never silently
    /// skip), then hand ownership over without following symlinks.
    private static func move(_ source: String, _ destination: String, owner: String) -> String {
        "if [ -e \(q(destination)) ] || [ -L \(q(destination)) ] || [ ! -e \(q(source)) ]; then echo FAILED; "
            + "else /bin/mv \(q(source)) \(q(destination)) && /usr/sbin/chown -hR \(owner) \(q(destination)) || echo FAILED; fi"
    }

    private static func clean(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
            && !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
    }

    private static func inTrash(_ path: String) -> Bool {
        clean(path) && SafetyPolicy.isInside(path, NSHomeDirectory() + "/.Trash")
    }

    private static func allowed(_ path: String) -> Bool {
        clean(path) && SafetyPolicy(home: NSHomeDirectory(), userVarFolder: DiskIO.userVarFolder()).check(path) == .allowed
    }

    /// Sources must be allowed by the policy; destinations must be in the Trash.
    private static func valid(_ path: String) -> Bool { inTrash(path) || allowed(path) }

    private static func identifier(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
    }

    /// Single-quote for /bin/sh.
    static func q(_ s: String) -> String { Shell.quote(s) }

    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
