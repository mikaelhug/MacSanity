import AppKit
import MacSanityCore

/// Developer aid: `MACSANITY_CLEANER_SELFTEST=1 MacSanity` exercises the real
/// removal path on a throwaway folder it creates itself (with a hostile name),
/// then exits non-zero on any failure. Touches nothing else.
@MainActor
enum CleanerSelfTest {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["MACSANITY_CLEANER_SELFTEST"] == "1" }

    static func runAndExit() {
        Task {
            var failures = 0
            func check(_ name: String, _ ok: Bool) {
                print(ok ? "PASS  \(name)" : "FAIL  \(name)"); if !ok { failures += 1 }
            }
            let home = NSHomeDirectory()
            let name = "com.macsanity.selftest it's \"quoted\" $(nope)"
            let path = home + "/Library/Caches/" + name
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path + "/blob", contents: Data(count: 2_000_000))
            let size = await DiskIO.size(path)
            check("fixture created (\(size.allocated) bytes)", size.allocated >= 2_000_000)
            check("fixture passes safety policy", SafetyPolicy(home: home).check(path) == .allowed)

            let finding = Finding(id: "selftest", category: .appCaches, title: "Self-test", reason: "", afterRemoval: "",
                                  safety: .safe, items: [FindingItem(path: path, size: size.allocated, modified: nil)],
                                  group: nil, lastUsed: nil, action: .trash)
            let history = CleanerHistory(fileName: "CleanerHistory-selftest.json")
            let outcome = await Remover.perform([(finding, finding.items[0])], allSelected: [finding], history: history)
            let entry = outcome.entries.first
            check("moved to Trash", !DiskIO.exists(path) && entry?.trashPath.map(DiskIO.exists) == true)
            check("trash path is inside ~/.Trash", entry?.trashPath?.hasPrefix(home + "/.Trash/") == true)
            check("history recorded", history.entries.contains { $0.id == entry?.id })

            if let entry {
                let restoreFailures = await Remover.restore([entry], history: history)
                check("restored to original place", restoreFailures.isEmpty && DiskIO.exists(path + "/blob"))
                let again = await Remover.perform([(finding, finding.items[0])], allSelected: [finding], history: history)
                if let e2 = again.entries.first {
                    let freed = await Remover.emptyFromTrash([e2], history: history)
                    check("emptied only our item", freed > 0 && !(e2.trashPath.map(DiskIO.exists) ?? true))
                } else { check("second move", false) }
            }

            // Admin script quoting, run as the current user with plain /bin/sh (no root).
            let src = home + "/Library/Caches/com.macsanity.selftest-admin it's \"q\" `x`"
            try? FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
            let dest = home + "/.Trash/com.macsanity.selftest-admin it's \"q\" `x`"
            if case .success(let script) = AdminRunner.shellScript(for: [.moveToTrash(source: src, destination: dest, uid: getuid(), gid: getgid())]) {
                let r = Command.run("/bin/sh", ["-c", script], timeout: 10)
                check("admin script quoting moves hostile name", r.ok && !r.output.contains("FAILED") && DiskIO.exists(dest) && !DiskIO.exists(src))
                try? FileManager.default.removeItem(atPath: dest)
            } else { check("admin script built", false) }
            if case .failure = AdminRunner.shellScript(for: [.moveToTrash(source: "/System/Library/x", destination: dest, uid: 0, gid: 0)]) {
                check("admin script refuses protected path", true)
            } else { check("admin script refuses protected path", false) }
            if case .failure = AdminRunner.shellScript(for: [.bootoutSystem(label: "x; rm -rf /")]) {
                check("admin script refuses unsafe label", true)
            } else { check("admin script refuses unsafe label", false) }

            history.deleteFile()   // (exit() below skips any defer)
            print(failures == 0 ? "\nAll removal self-tests passed." : "\n\(failures) removal self-test(s) failed.")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }
}
