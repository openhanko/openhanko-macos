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
        case .pinpad:     return "Connected — press to authenticate"
        }
    }

    var detail: String {
        switch self {
        case .noDevice:
            return """
            Plug in your OpenHanko. macOS will offer to pair it the first time, \
            and it works on any Mac with nothing installed.
            """
        case .driverless(let name):
            return """
            \(name)

            macOS is using its built-in smart card driver, so you will be asked \
            for a PIN — pressing the button types it for you.

            Unplug and plug the device back in to switch it to press-only mode \
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

        let title = NSTextField(labelWithString: "OpenHanko")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        headline.font = .systemFont(ofSize: 13, weight: .medium)
        dot.font = .systemFont(ofSize: 13)

        let status = NSStackView(views: [dot, headline])
        status.orientation = .horizontal
        status.spacing = 6

        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 400

        // Worth saying outright. The driver is a system extension and has
        // nothing to do with this window: closing it quits this app and changes
        // nothing about whether the key works. Without that sentence people
        // reasonably assume it has to stay running, and leave it in the Dock
        // forever.
        let hint = NSTextField(wrappingLabelWithString:
            "The driver is part of macOS once installed, and works whether or not "
            + "this window is open. You can close it — nothing will reopen it, and "
            + "the key keeps working. Open OpenHanko again any time you want to "
            + "check on it.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [title, status, detail, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
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
