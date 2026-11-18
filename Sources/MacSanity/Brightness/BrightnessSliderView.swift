import AppKit

/// A menu-item view: the monitor's name above a sun–slider–sun row. Hosted in an
/// `NSMenuItem.view`; `NSSlider` tracks natively inside the menu's event loop.
@MainActor
final class BrightnessSliderView: NSView {
    let key: String
    private let label = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let onChange: (String, Int) -> Void

    static let width: CGFloat = 270
    private static let inset: CGFloat = 14

    init(monitor: MonitorBrightness, onChange: @escaping (String, Int) -> Void) {
        self.key = monitor.id
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 48))
        autoresizingMask = [.width]

        label.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail

        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderMoved)

        let low = Self.symbol("sun.min")
        let high = Self.symbol("sun.max")
        let row = NSStackView(views: [low, slider, high])
        row.orientation = .horizontal
        row.spacing = 6

        let column = NSStackView(views: [label, row])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            row.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        update(monitor)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Reflect the model. The range is always applied; only the knob position is
    /// held back while this slider is being dragged, so a late DDC read can't yank it.
    ///
    /// The range must never be skipped: the view is first built in
    /// `menuNeedsUpdate`, while the click that opens the menu is still held down.
    /// Skipping it then left NSSlider's default 0…1 range, so the slider could only
    /// send brightness 0 or 1.
    func update(_ monitor: MonitorBrightness) {
        label.stringValue = monitor.verified ? monitor.name : "\(monitor.name) — unverified"
        slider.setAccessibilityLabel("\(monitor.name) brightness")
        if slider.minValue != 0 { slider.minValue = 0 }
        if slider.maxValue != Double(monitor.max) { slider.maxValue = Double(monitor.max) }
        guard !isBeingDragged else { return }
        if slider.integerValue != monitor.value { slider.integerValue = monitor.value }
    }

    /// Mid-drag means the menu is on screen and the mouse is down. A view that is
    /// not in a visible window (just created, or the menu is still opening) can't be.
    private var isBeingDragged: Bool {
        window?.isVisible == true && NSEvent.pressedMouseButtons & 1 != 0
    }

    @objc private func sliderMoved() {
        onChange(key, slider.integerValue)
    }

    private static func symbol(_ name: String) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        view.contentTintColor = .secondaryLabelColor
        view.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }
}
