import AppKit
import MacSanityCore
import SwiftUI

/// Owns the cleaner window. Created on demand from the menu; closing the window
/// frees the scan results — nothing keeps running in the background.
@MainActor
final class CleanerWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: CleanerModel?
    /// Called after the window closed and its resources were released.
    var onClose: (() -> Void)?

    func show() {
        if window == nil {
            let model = CleanerModel()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "MacSanity Cleaner"
            window.minSize = NSSize(width: 820, height: 520)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: CleanerRootView(model: model))
            window.setFrameAutosaveName("MacSanityCleaner")
            if !window.setFrameUsingName("MacSanityCleaner") { window.center() }
            window.delegate = self
            self.window = window
            self.model = model
        }
        // A menu-bar (accessory) app never fully becomes the active app, so macOS
        // doesn't show its windows' resize cursors or keyboard focus reliably.
        // Act as a regular app (Dock icon) while the cleaner window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if let model, model.result == nil, model.phase == .idle { model.startScan() }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Developer aid (`MACSANITY_CLEANER_SNAPSHOTS=<dir>`): after the scan, render
    /// each section of this window to PNG — the app captures its own window, so
    /// no screen-recording permission is involved — then close.
    func snapshotSections(to dir: String) {
        Task { @MainActor in
            while model?.phase != .ready { try? await Task.sleep(for: .milliseconds(500)) }
            guard let model, let window else { return }
            let sections: [(String, CleanerSection)] = [("overview", .overview), ("diskmap", .diskMap)]
                + CleanerCategory.displayOrder.map { ($0.rawValue, CleanerSection.category($0)) }
                + [("uninstall", .uninstall), ("history", .history)]
            for (name, section) in sections {
                model.section = section
                try? await Task.sleep(for: .milliseconds(700))
                guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
            model.reviewAndClean()
            try? await Task.sleep(for: .milliseconds(900))
            if let sheet = window.attachedSheet, let view = sheet.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/confirm.png"))
            }
            model.showConfirm = false
            // A window can't close while a sheet is still attached.
            while window.attachedSheet != nil { try? await Task.sleep(for: .milliseconds(100)) }
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        model?.reset()
        // Drop the whole view hierarchy and model; a reopen starts fresh.
        window?.contentViewController = nil
        window = nil
        model = nil
        NSApp.setActivationPolicy(.accessory)   // back to menu-bar only
        onClose?()
    }
}
