import SwiftUI

/// The pull-down menu shown from the status item. Rendered as a native
/// `NSMenu` by `MenuBarExtra(.menu)`, so `Toggle`s appear as checkmarked items.
struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Toggle("Keep Awake", isOn: bind(model.isKeepingAwake, model.setKeepAwake))
        Menu("Keep Awake For") {
            durationButton("30 Minutes", .minutes(30))
            durationButton("1 Hour", .minutes(60))
            durationButton("Until Turned Off", .indefinite)
        }

        Divider()

        Toggle("Reverse Scrolling", isOn: bind(model.reverseEnabled, model.setReverseEnabled))
        Toggle("Reverse Mouse", isOn: bind(model.reverseMouse, model.setReverseMouse))
            .disabled(!model.reverseEnabled)
        Toggle("Reverse Trackpad", isOn: bind(model.reverseTrackpad, model.setReverseTrackpad))
            .disabled(!model.reverseEnabled)

        if model.reverseEnabled && !model.permissionsOK {
            Button("Grant Scroll Permissions…") {
                model.permissions.requestMissing()
            }
        }

        Divider()

        Toggle("Start at Login", isOn: bind(model.startAtLogin, model.setStartAtLogin))
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit MacSanity") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Bridges an observable value + an intent method into a SwiftUI `Binding`,
    /// so every toggle routes through `AppModel` (which persists and applies the
    /// side effect) rather than mutating state directly.
    private func bind(_ value: Bool, _ set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: { set($0) })
    }

    /// A duration choice that shows a checkmark when it's the active one.
    @ViewBuilder
    private func durationButton(_ title: String, _ duration: KeepAwakeDuration) -> some View {
        Button {
            model.startKeepAwake(duration)
        } label: {
            if model.keepAwakeDuration == duration {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
