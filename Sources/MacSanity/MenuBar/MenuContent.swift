import SwiftUI

/// The pull-down menu shown from the status item. Rendered as a native
/// `NSMenu` by `MenuBarExtra(.menu)`, so `Toggle`s appear as checkmarked items.
struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Toggle(isOn: bind(model.isKeepingAwake, model.setKeepAwake)) {
            Text(model.keepAwakeMenuLabel)
        }
        Menu("Keep Awake For") {
            durationButton("30 Minutes", .interval(30 * 60))
            durationButton("1 Hour", .interval(60 * 60))
            Button("Custom…") {
                if let seconds = CustomDurationPrompt.run() {
                    model.startKeepAwake(.interval(seconds))
                }
            }
        }

        Divider()

        Toggle("Reverse Mouse", isOn: bind(model.reverseMouse, model.setReverseMouse))
        Toggle("Reverse Trackpad", isOn: bind(model.reverseTrackpad, model.setReverseTrackpad))
        if model.anyReverseEnabled && !model.permissionsOK {
            Button("Grant Accessibility Access…") {
                model.requestScrollPermissions()
            }
        }

        Divider()

        Toggle("Start at Login", isOn: bind(model.startAtLogin, model.setStartAtLogin))
        Button("Hide Menu Bar Icon") {
            model.setHideIcon(true)
        }

        Divider()

        Button("Check for Updates…") {
            model.checkForUpdates()
        }
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
