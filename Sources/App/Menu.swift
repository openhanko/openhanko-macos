// The menu bar.
//
// An app assembled without a nib gets no menu at all — not even Quit, so ⌘Q does
// nothing and the only way out is the close box. That is the sort of missing
// furniture people read as "this is not really a Mac app", and they are right to.
//
// Built here rather than in main.swift because it is a page of boilerplate with
// one interesting line in it, and mixing that into the window setup buries both.

import AppKit

enum Menu {
    static func install(appName: String) {
        let main = NSMenu()

        // MARK: App
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // MARK: Edit
        //
        // Not decoration: Diagnostics puts the trace in a text view, and without
        // an Edit menu ⌘C does not work in it. Copying a trace into a bug report
        // is most of why that pane exists.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        // MARK: View
        //
        // ⌘1 to ⌘5 for the tabs. NSTabViewController implements the action
        // already; it only needs somewhere to be invoked from.
        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        for (index, title) in ["Status", "Fingerprints", "Settings",
                               "Diagnostics", "Update"].enumerated() {
            let item = view.addItem(withTitle: title,
                                    action: #selector(AppDelegate.selectPane(_:)),
                                    keyEquivalent: "\(index + 1)")
            item.tag = index
        }
        viewItem.submenu = view
        main.addItem(viewItem)

        // MARK: Window
        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize",
                       action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom",
                       action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        // MARK: Help
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "\(appName) on the Web",
                     action: #selector(AppDelegate.openWebsite(_:)), keyEquivalent: "")
        helpItem.submenu = help
        main.addItem(helpItem)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }
}
