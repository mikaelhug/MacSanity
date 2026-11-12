import AppKit

// Plain AppKit entry point. The UI is a single NSStatusItem menu
// (StatusMenuController), so there are no SwiftUI scenes to host.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
