// The OpenHanko app.
//
// Its unavoidable job is to be an application bundle, because pluginkit only
// registers an app extension that lives inside one. For a long time that was all
// it did — a window that said "Connected" and invited you to close it.
//
// Everything the device knows about itself was already on its console, and the
// only way to read it was a terminal. So the states that mattered most were the
// ones nobody could see: a swapped sensor showed red on the ring and nothing
// else, adding a finger was a gesture performed blind, and changing the idle
// light took a firmware build and a signature. This app is those things, said in
// words, in the place someone would look for them.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar

        func add(_ pane: NSViewController, _ title: String, _ symbol: String) {
            pane.title = title
            let item = NSTabViewItem(viewController: pane)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }

        add(PaneStatus(), "Status", "circle.dashed")
        add(PaneFingerprints(), "Fingerprints", "hand.point.up.left")
        add(PaneSettings(), "Settings", "slider.horizontal.3")
        add(PaneDiagnostics(), "Diagnostics", "waveform.path.ecg")
        add(PaneUpdate(), "Update", "arrow.down.circle")

        let window = NSWindow(contentViewController: tabs)
        window.title = "OpenHanko"
        window.styleMask.insert(.miniaturizable)
        window.setContentSize(NSSize(width: 500, height: 440))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        DeviceAgent.shared.startPolling()
    }

    // Closing the window is the expected end of a session — this is something to
    // consult, not something to leave running. The driver is part of macOS once
    // installed and keeps working with nothing on screen.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
