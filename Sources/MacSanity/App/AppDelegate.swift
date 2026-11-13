import AppKit

/// Minimal launch hook. All real state and behavior lives in `AppModel`; this
/// just kicks off one-time setup, installs the status menu, and handles reopen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?
    private var cleanerOnly: CleanerWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CleanerReport.isRequested { CleanerReport.runAndExit(); return }
        if CleanerSelfTest.isRequested { CleanerSelfTest.runAndExit(); return }
        // Developer aid: only the cleaner window (no status item, no event taps),
        // so it can run next to an installed MacSanity. Quits when closed.
        if ProcessInfo.processInfo.environment["MACSANITY_CLEANER_WINDOW"] == "1" {
            cleanerOnly = CleanerWindowController()
            cleanerOnly?.onClose = { NSApp.terminate(nil) }
            cleanerOnly?.show()
            if let dir = ProcessInfo.processInfo.environment["MACSANITY_CLEANER_SNAPSHOTS"] {
                cleanerOnly?.snapshotSections(to: dir)
            }
            return
        }
        // Only one MacSanity may run: two instances would each install an active
        // scroll tap (reversing every scroll twice = not at all), post Safari
        // ⌘←/⌘→ twice, and drive the same DDC buses concurrently. The updater
        // relaunches only after the old process has exited, so it never trips this.
        guard !Self.anotherInstanceIsRunning() else {
            NSLog("MacSanity: another instance is already running — quitting")
            NSApp.terminate(nil)
            return
        }
        AppModel.shared.start()
        statusMenu = StatusMenuController(model: AppModel.shared)
    }

    private static func anotherInstanceIsRunning() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.macsanity.app"
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    /// Reopening the app (e.g. double-clicking it in Finder) brings the menu-bar
    /// icon back, so hiding it can never lock the user out.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppModel.shared.revealIcon()
        // While the cleaner is open the app has a Dock icon; clicking it should
        // bring the cleaner window forward.
        cleanerOnly?.show()
        AppModel.shared.showCleanerIfOpen()
        return true
    }
}
