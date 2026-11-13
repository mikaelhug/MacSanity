import AppKit

/// Quit and run follow-up shell steps once this process has fully exited
/// (a running bundle can't be replaced, and a second instance would quit
/// itself on launch). The detached shell outlives our termination.
@MainActor
enum AppRelaunch {
    /// Runs `script` after this process exits, then terminates the app.
    static func runAfterExit(_ script: String) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done\n" + script]
        try process.run()
        NSApp.terminate(nil)
    }

    /// Whether we're running from an .app bundle (permissions such as Full Disk
    /// Access can only be granted to an app, not to a bare executable).
    static var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Reopen this app (e.g. so a newly granted permission takes effect).
    static func relaunch() {
        try? runAfterExit("/usr/bin/open \(Shell.quote(Bundle.main.bundleURL.path))")
    }
}
