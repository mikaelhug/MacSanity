import AppKit
import Observation

/// The status item and its pull-down menu, built in AppKit (SwiftUI's
/// `MenuBarExtra(.menu)` can't host sliders). `AppModel` stays the single source
/// of truth: the menu is rebuilt from it on every open, and kept live while open
/// via Observation, so state never has to be synced by hand.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var isOpen = false
    private var built: Snapshot?
    /// Reused across rebuilds so an open slider is never torn down mid-drag.
    private var sliderViews: [String: BrightnessSliderView] = [:]
    private var visibilityObservation: NSKeyValueObservation?
    private var iconSymbol: String?

    // Items updated in place while the menu is open.
    private var keepAwakeItem: NSMenuItem?
    private var durationItems: [(KeepAwakeDuration, NSMenuItem)] = []
    private var reverseMouseItem: NSMenuItem?
    private var reverseTrackpadItem: NSMenuItem?
    private var safariNavItem: NSMenuItem?
    private var startAtLoginItem: NSMenuItem?

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.autosaveName = "MacSanity"
        statusItem.behavior = .removalAllowed   // ⌘-drag out of the bar = Hide Icon
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        // Mirror a ⌘-drag removal back into the model.
        visibilityObservation = statusItem.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard let visible = change.newValue else { return }
            Task { @MainActor in
                guard let self, self.model.showIcon != visible else { return }
                self.model.setHideIcon(!visible)
            }
        }
        observe()
    }

    // MARK: Observation

    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    /// Reads every model value the status item and menu display (which is what
    /// registers them for observation) and applies changes.
    private func render() {
        let symbol = model.menuBarSymbolName
        if symbol != iconSymbol {
            iconSymbol = symbol
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacSanity")
            image?.isTemplate = true
            statusItem.button?.image = image
        }
        if statusItem.isVisible != model.showIcon { statusItem.isVisible = model.showIcon }

        let snapshot = Snapshot(model)
        guard isOpen else { return }
        if snapshot.structure != built?.structure {
            build(snapshot)        // a monitor appeared/vanished while open
        } else {
            apply(snapshot)
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        build(Snapshot(model))
    }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        model.brightness.refreshForMenuOpen()
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        model.brightness.menuDidClose()
    }

    // MARK: Building

    private func build(_ s: Snapshot) {
        built = s
        menu.removeAllItems()
        durationItems = []

        // Brightness — only when there's a DDC monitor (or one to opt in).
        if !s.monitors.isEmpty || !s.undetected.isEmpty {
            for monitor in s.monitors {
                let item = NSMenuItem()
                item.view = sliderView(for: monitor)
                menu.addItem(item)
            }
            if !s.undetected.isEmpty {
                menu.addItem(otherDisplaysItem(s.undetected))
            }
            menu.addItem(.separator())
        }
        let live = Set(s.monitors.map(\.id))
        sliderViews = sliderViews.filter { live.contains($0.key) }

        // Keep Awake
        keepAwakeItem = item("Keep Awake") { [model] in model.setKeepAwake(!model.isKeepingAwake) }
        menu.addItem(keepAwakeItem!)
        let durations = NSMenu()
        for (title, duration) in [("30 Minutes", KeepAwakeDuration.interval(30 * 60)),
                                  ("1 Hour", .interval(60 * 60))] {
            let entry = item(title) { [model] in model.startKeepAwake(duration) }
            durationItems.append((duration, entry))
            durations.addItem(entry)
        }
        durations.addItem(item("Custom…") { [model] in
            if let seconds = CustomDurationPrompt.run() { model.startKeepAwake(.interval(seconds)) }
        })
        let durationsItem = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        durationsItem.submenu = durations
        menu.addItem(durationsItem)
        menu.addItem(.separator())

        // Input
        reverseMouseItem = item("Reverse Mouse") { [model] in model.setReverseMouse(!model.reverseMouse) }
        reverseTrackpadItem = item("Reverse Trackpad") { [model] in model.setReverseTrackpad(!model.reverseTrackpad) }
        safariNavItem = item("Safari Back/Forward Buttons") { [model] in
            model.setSafariNavButtons(!model.safariNavButtons)
        }
        [reverseMouseItem!, reverseTrackpadItem!, safariNavItem!].forEach(menu.addItem)
        if s.needsAccessibilityGrant {
            menu.addItem(item("Grant Accessibility Access…") { [model] in model.requestAccessibilityGrant() })
        }
        menu.addItem(.separator())

        // System
        startAtLoginItem = item("Start at Login") { [model] in model.setStartAtLogin(!model.startAtLogin) }
        menu.addItem(startAtLoginItem!)
        menu.addItem(item("Hide Menu Bar Icon") { [model] in model.setHideIcon(true) })
        menu.addItem(.separator())

        menu.addItem(item("Check for Updates…") { [model] in model.checkForUpdates() })
        let quit = item("Quit MacSanity") { NSApplication.shared.terminate(nil) }
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)

        apply(s)
    }

    /// Update titles, checkmarks and slider positions in place.
    private func apply(_ s: Snapshot) {
        built = s
        keepAwakeItem?.title = s.keepAwakeLabel
        keepAwakeItem?.state = s.isKeepingAwake ? .on : .off
        for (duration, entry) in durationItems {
            entry.state = s.keepAwakeDuration == duration ? .on : .off
        }
        reverseMouseItem?.state = s.reverseMouse ? .on : .off
        reverseTrackpadItem?.state = s.reverseTrackpad ? .on : .off
        safariNavItem?.state = s.safariNavButtons ? .on : .off
        startAtLoginItem?.state = s.startAtLogin ? .on : .off
        for monitor in s.monitors { sliderViews[monitor.id]?.update(monitor) }
    }

    private func sliderView(for monitor: MonitorBrightness) -> BrightnessSliderView {
        if let view = sliderViews[monitor.id] {
            view.update(monitor)
            return view
        }
        let view = BrightnessSliderView(monitor: monitor) { [model] key, value in
            model.brightness.setBrightness(key, to: value)
        }
        sliderViews[monitor.id] = view
        return view
    }

    /// Monitors with a DDC transport that didn't answer a brightness read. DDC
    /// writes give no feedback, so only the user can tell whether a write-only
    /// slider works — offered as an explicit, clearly-labelled opt-in.
    private func otherDisplaysItem(_ displays: [UndetectedDisplay]) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let note = NSMenuItem(title: "No DDC brightness reply from these displays", action: nil, keyEquivalent: "")
        note.isEnabled = false
        submenu.addItem(note)
        for display in displays {
            submenu.addItem(.separator())
            submenu.addItem(.sectionHeader(title: display.name))
            let enabled = model.brightness.isManuallyEnabled(display.id)
            let toggle = item("Enable Brightness Slider (Unverified)") { [model] in
                model.brightness.setManuallyEnabled(display.id, !enabled)
            }
            toggle.state = enabled ? .on : .off
            toggle.toolTip = "Sends DDC brightness commands without being able to confirm the monitor obeys. "
                + "If moving the slider changes nothing, turn this off."
            submenu.addItem(toggle)
        }
        let item = NSMenuItem(title: "Other Displays", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func item(_ title: String, _ handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        ActionMenuItem(title: title, handler: handler)
    }
}

/// Everything the menu shows, captured in one read (which also registers the
/// properties for observation).
private struct Snapshot {
    struct Structure: Equatable {
        let monitorIDs: [String]
        let undetectedIDs: [String]
        let needsAccessibilityGrant: Bool
    }

    let keepAwakeLabel: String
    let isKeepingAwake: Bool
    let keepAwakeDuration: KeepAwakeDuration?
    let reverseMouse: Bool
    let reverseTrackpad: Bool
    let safariNavButtons: Bool
    let needsAccessibilityGrant: Bool
    let startAtLogin: Bool
    let monitors: [MonitorBrightness]
    let undetected: [UndetectedDisplay]

    var structure: Structure {
        Structure(monitorIDs: monitors.map(\.id), undetectedIDs: undetected.map(\.id),
                  needsAccessibilityGrant: needsAccessibilityGrant)
    }

    @MainActor init(_ model: AppModel) {
        keepAwakeLabel = model.keepAwakeMenuLabel
        isKeepingAwake = model.isKeepingAwake
        keepAwakeDuration = model.keepAwakeDuration
        reverseMouse = model.reverseMouse
        reverseTrackpad = model.reverseTrackpad
        safariNavButtons = model.safariNavButtons
        needsAccessibilityGrant = model.needsAccessibilityGrant
        startAtLogin = model.startAtLogin
        monitors = model.brightness.monitors
        undetected = model.brightness.undetected
    }
}

/// An `NSMenuItem` that runs a closure.
@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}
