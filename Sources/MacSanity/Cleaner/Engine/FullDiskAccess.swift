import AppKit

/// Full Disk Access lets the cleaner see other apps' containers, the Trash, iOS
/// backups and Mail downloads. Without it the scan still works; protected places
/// are listed as "Grant Full Disk Access to scan".
enum FullDiskAccess {
    /// Readable only with Full Disk Access.
    private static let probe = "/Library/Application Support/com.apple.TCC/TCC.db"

    static var isGranted: Bool {
        let fd = open(probe, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
