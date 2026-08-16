// Container app for the CryptoTokenKit extension.
//
// It exists because an app extension must live inside an application bundle for
// pluginkit to register it. Launching it once is what makes macOS notice the
// token driver; after that the extension is loaded on demand by ctkd.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let text = NSTextField(wrappingLabelWithString: """
        smart-card token driver installed.

        This window does nothing. Its only job is to be an application bundle \
        so macOS registers the CryptoTokenKit extension inside it.

        Check registration:
            pluginkit -m -p com.apple.ctk-tokens
            system_profiler SPSmartCardsDataType
        """)
        text.frame = NSRect(x: 20, y: 20, width: 420, height: 160)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "smart-card token"
        window.contentView?.addSubview(text)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
