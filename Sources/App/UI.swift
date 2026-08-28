// Shared furniture for the panes.
//
// Assembled in code rather than in a nib for the same reason the bundle is
// assembled by a shell script: the layout is simple, and a few helpers read
// better in review than an XML file nobody opens.

import AppKit

enum UI {
    /// Width of wrapping text. Roughly 65 characters at 12pt, which is where
    /// prose stops being comfortable to read.
    static let textWidth: CGFloat = 420
    static let padding: CGFloat = 20

    static func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        return label
    }

    static func body(_ text: String = "") -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = textWidth
        // preferredMaxLayoutWidth tells a label where to wrap but does not stop
        // the enclosing stack widening to fit one long unbroken run, which then
        // overflows the insets. Pinning the width makes the inset real.
        label.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        return label
    }

    static func caption(_ text: String = "") -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        return label
    }

    static func mono(_ text: String = "") -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }

    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        return box
    }

    static func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        return stack
    }

    static func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        return button
    }

    /// A field with a label, for the two-column readouts under Diagnostics.
    static func field(_ name: String, _ value: String) -> NSStackView {
        let key = NSTextField(labelWithString: name)
        key.font = .systemFont(ofSize: 11)
        key.textColor = .tertiaryLabelColor
        key.alignment = .right
        key.widthAnchor.constraint(equalToConstant: 130).isActive = true
        return row([key, mono(value)], spacing: 10)
    }
}

/// A tab that keeps itself up to date while it is on screen.
class Pane: NSViewController {
    let stack = UI.column([])

    override func loadView() {
        view = NSView()
        stack.edgeInsets = NSEdgeInsets(top: UI.padding, left: UI.padding,
                                        bottom: UI.padding, right: UI.padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])
        build()
    }

    /// Subclasses assemble their contents here.
    func build() {}

    /// Called when a status arrives, and when the pane appears.
    func apply(_ status: DeviceStatus?, error: String?) {}

    override func viewDidAppear() {
        super.viewDidAppear()
        NotificationCenter.default.addObserver(
            self, selector: #selector(statusChanged),
            name: DeviceAgent.statusChanged, object: nil)
        statusChanged()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func statusChanged() {
        apply(DeviceAgent.shared.status, error: DeviceAgent.shared.lastError)
    }
}
