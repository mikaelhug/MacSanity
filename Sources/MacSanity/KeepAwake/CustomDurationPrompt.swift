import AppKit

/// A small modal prompt for a custom Keep Awake duration (hours / minutes /
/// seconds). Returns the total in seconds, or nil if cancelled or all-zero.
@MainActor
enum CustomDurationPrompt {
    static func run() -> Int? {
        let alert = NSAlert()
        alert.messageText = "Keep Awake For…"
        alert.informativeText = "Enter how long to stay awake."
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let hours = numberField(value: 0)
        let minutes = numberField(value: 30)

        let stack = NSStackView(views: [
            hours, unitLabel("h"),
            minutes, unitLabel("m"),
        ])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .firstBaseline
        let fitting = stack.fittingSize
        stack.setFrameSize(NSSize(width: max(fitting.width, 180), height: max(fitting.height, 24)))
        alert.accessoryView = stack

        // Bring the modal forward — an .accessory agent isn't active by default.
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = hours

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let total = hours.integerValue * 3600 + minutes.integerValue * 60
        return total > 0 ? total : nil
    }

    private static func numberField(value: Int) -> NSTextField {
        let field = NSTextField()
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 0
        formatter.maximum = 9999
        formatter.allowsFloats = false
        field.formatter = formatter
        field.integerValue = value
        return field
    }

    private static func unitLabel(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }
}
