import Foundation

/// Thin typed wrapper over `UserDefaults.standard`. Only persistent user
/// preferences live here. Keep Awake is deliberately *not* stored (it's a
/// transient session mode), and launch-at-login state is owned by SMAppService
/// rather than duplicated here.
enum Defaults {
    private enum Key {
        static let reverseMouse = "reverseMouse"
        static let reverseTrackpad = "reverseTrackpad"
        static let safariNavButtons = "safariNavButtons"
        static let hideIcon = "hideIcon"
        static let manualDDCDisplays = "manualDDCDisplays"
        static let manualDDCValues = "manualDDCValues"
    }

    /// Seed the factory defaults: all input features off until the user opts in.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.reverseMouse: false,
            Key.reverseTrackpad: false,
            Key.safariNavButtons: false,
            Key.hideIcon: false,
        ])
    }

    static var reverseMouse: Bool {
        get { UserDefaults.standard.bool(forKey: Key.reverseMouse) }
        set { UserDefaults.standard.set(newValue, forKey: Key.reverseMouse) }
    }
    static var reverseTrackpad: Bool {
        get { UserDefaults.standard.bool(forKey: Key.reverseTrackpad) }
        set { UserDefaults.standard.set(newValue, forKey: Key.reverseTrackpad) }
    }
    static var safariNavButtons: Bool {
        get { UserDefaults.standard.bool(forKey: Key.safariNavButtons) }
        set { UserDefaults.standard.set(newValue, forKey: Key.safariNavButtons) }
    }
    static var hideIcon: Bool {
        get { UserDefaults.standard.bool(forKey: Key.hideIcon) }
        set { UserDefaults.standard.set(newValue, forKey: Key.hideIcon) }
    }

    /// Stable keys of displays the user opted into write-only (unverified) DDC
    /// brightness because they don't answer DDC reads.
    static var manualDDCDisplays: [String] {
        get { UserDefaults.standard.stringArray(forKey: Key.manualDDCDisplays) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Key.manualDDCDisplays) }
    }
    /// Last brightness written to each manually-enabled display (its slider
    /// position, since the monitor can't be asked).
    static var manualDDCValues: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: Key.manualDDCValues) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Key.manualDDCValues) }
    }
}
