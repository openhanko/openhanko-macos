// The window a user sees after installing OpenHanko.
//
// Its unavoidable job is to be an application bundle, because pluginkit only
// registers an app extension that lives inside one. But it is also the only
// place the driver can explain itself, and a device that authenticates without
// a prompt is indistinguishable from one that is broken — so it says what it
// can see, in the order someone troubleshooting would want to know it.

import AppKit
import CryptoTokenKit

let tokenClassID = "io.openhanko.app.token"

enum DeviceState {
    case noDevice
    case driverless(String)
    case pinpad(String)

    var headline: String {
        switch self {
        case .noDevice:   return "No device connected"
        case .driverless: return "Connected — driverless mode"
                // Just "Connected". It used to append what to do next, which reads as an
        // instruction the moment you look at the window — but this line is shown
        // whenever the device is present, not only when something is waiting on
        // it, so it told people to touch the sensor when nothing had asked.
        case .pinpad:     return "Connected"
        }
    }

    var detail: String {
        switch self {
        case .noDevice:
            return """
            Plug in your OpenHanko. macOS will offer to pair it the first time, \
            and it works on any Mac with nothing installed.

            A new device needs a fingerprint before it can pair. The ring breathes \
            purple while it waits for one; touch the sensor twice with the same \
            finger, then unplug and reconnect to pair.
            """
        case .driverless(let name):
            return """
            \(name)

            macOS is using its built-in smart card driver, so you will be asked \
            for a PIN — touching the sensor types it for you.

            Unplug and plug the device back in to switch it to touch-only mode \
            now that this driver is installed.
            """
        case .pinpad(let name):
            return """
            \(name)

            This driver is handling your device, so there is no PIN prompt at \
            all. When macOS needs you, the light breathes; touch the device and \
            it signs.
            """
        }
    }
}

func currentState() -> DeviceState {
    // Token IDs look like "<class id>:<instance>" for ours, and
    // "com.apple.pivtoken:<instance>" when macOS's built-in driver has the card.
    let ids = TKTokenWatcher().tokenIDs

    if let ours = ids.first(where: { $0.hasPrefix(tokenClassID) }) {
        return .pinpad(describe(tokenID: ours))
    }
    if let apple = ids.first(where: { $0.hasPrefix("com.apple.pivtoken") }) {
        return .driverless(describe(tokenID: apple))
    }
    return .noDevice
}

/// The device's own name, taken from the certificate it published, so the
/// window shows the same "OpenHanko #XXXXXX" the device prints and `sc_auth`
/// lists — which is how someone tells two of them apart.
func describe(tokenID: String) -> String {
    let query: [String: Any] = [
        kSecClass as String: kSecClassCertificate,
        kSecAttrAccessGroup as String: kSecAttrAccessGroupToken,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
       let items = result as? [[String: Any]] {
        for item in items where (item[kSecAttrTokenID as String] as? String) == tokenID {
            if let label = item[kSecAttrLabel as String] as? String, !label.isEmpty {
                return label
            }
        }
    }
    return "Paired device"
}

enum Layout {
    /// Width of the wrapping text, inside the window's padding.
    static let textWidth: CGFloat = 380
    static let padding: CGFloat = 24
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let dot = NSTextField(labelWithString: "●")
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "OpenHanko"

        // No "OpenHanko" heading: the title bar already says it, and repeating it
        // pushed everything else down to make room for a word the user just read.
        headline.font = .systemFont(ofSize: 15, weight: .semibold)
        dot.font = .systemFont(ofSize: 13)

        let status = NSStackView(views: [dot, headline])
        status.orientation = .horizontal
        status.spacing = 6

        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = Layout.textWidth

        // The one thing a person opening this window most needs told, so it is
        // set like a statement rather than a footnote. It was tertiary grey at
        // 11pt — the faintest, smallest text on screen — which is the opposite
        // of what it deserved.
        let closable = NSTextField(labelWithString: "You can close this window.")
        closable.font = .systemFont(ofSize: 13, weight: .medium)

        let closableWhy = NSTextField(wrappingLabelWithString:
            "The driver is part of macOS once installed and keeps working on its "
            + "own. Nothing will reopen this window; open OpenHanko again whenever "
            + "you want to check on things.")
        closableWhy.font = .systemFont(ofSize: 12)
        closableWhy.textColor = .secondaryLabelColor
        closableWhy.preferredMaxLayoutWidth = Layout.textWidth

        let rule = NSBox()
        rule.boxType = .separator

        let stack = NSStackView(views: [status, detail, rule, closable, closableWhy])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: Layout.padding, left: Layout.padding,
                                        bottom: Layout.padding, right: Layout.padding)
        // The separator is the only thing that should span the width; everything
        // else is left-aligned text.
        // preferredMaxLayoutWidth alone only tells a label where to wrap; it does
        // not stop the stack widening to fit a long unbroken run, and the text
        // then overflowed the insets — visibly wider than the separator below it.
        // Pinning the width makes the inset real.
        for label in [detail, closableWhy] {
            label.widthAnchor.constraint(equalToConstant: Layout.textWidth).isActive = true
        }

        stack.setCustomSpacing(20, after: detail)
        stack.setCustomSpacing(16, after: rule)
        stack.setCustomSpacing(4, after: closable)
        stack.translatesAutoresizingMaskIntoConstraints = false

        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            // Pinned on all four edges, bottom included. Without the bottom the
            // window kept whatever height it was created with and left a band of
            // empty space below the text.
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                rule.widthAnchor.constraint(equalToConstant: Layout.textWidth),
            ])
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
        }

        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        refresh()
        // Cheap enough to poll, and it means plugging the device in while this
        // window is open visibly does something.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let state = currentState()
        headline.stringValue = state.headline
        detail.stringValue = state.detail
        switch state {
        case .noDevice:   dot.textColor = .tertiaryLabelColor
        case .driverless: dot.textColor = .systemOrange
        case .pinpad:     dot.textColor = .systemGreen
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
