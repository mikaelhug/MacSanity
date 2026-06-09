import Foundation

/// Thin typed wrapper over `UserDefaults.standard`. Only persistent user
/// preferences live here. Keep Awake is deliberately *not* stored (it's a
/// transient session mode), and launch-at-login state is owned by SMAppService
/// rather than duplicated here.
enum Defaults {
    private enum Key {
        static let reverseEnabled = "reverseEnabled"
        static let reverseMouse = "reverseMouse"
        static let reverseTrackpad = "reverseTrackpad"
        static let hideIcon = "hideIcon"
    }

    /// Seed the factory defaults: scroll reversal off until the user opts in,
    /// and — when they do — mice reverse while the trackpad stays natural.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.reverseEnabled: false,
            Key.reverseMouse: true,
            Key.reverseTrackpad: false,
            Key.hideIcon: false,
        ])
    }

    static var reverseEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.reverseEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Key.reverseEnabled) }
    }
    static var reverseMouse: Bool {
        get { UserDefaults.standard.bool(forKey: Key.reverseMouse) }
        set { UserDefaults.standard.set(newValue, forKey: Key.reverseMouse) }
    }
    static var reverseTrackpad: Bool {
        get { UserDefaults.standard.bool(forKey: Key.reverseTrackpad) }
        set { UserDefaults.standard.set(newValue, forKey: Key.reverseTrackpad) }
    }
    static var hideIcon: Bool {
        get { UserDefaults.standard.bool(forKey: Key.hideIcon) }
        set { UserDefaults.standard.set(newValue, forKey: Key.hideIcon) }
    }
}
