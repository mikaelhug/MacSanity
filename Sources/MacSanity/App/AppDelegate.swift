import AppKit

/// Minimal launch hook. All real state and behavior lives in `AppModel`; this
/// just kicks off one-time setup and handles reopen.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    /// Reopening the app (e.g. double-clicking it in Finder) brings the menu-bar
    /// icon back, so hiding it can never lock the user out.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppModel.shared.revealIcon()
        return true
    }
}
