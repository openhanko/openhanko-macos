// Settings that live on the device.
//
// The idle colour took four firmware builds and four signatures to settle,
// which is three too many for a preference about somebody's desk at night. It is
// stored on the device now, so this is the place it gets changed.

import AppKit

final class PaneSettings: Pane {
    private static let colours = ["off", "blue", "green", "cyan",
                                  "red", "purple", "yellow", "white"]

    private let popup = NSPopUpButton()
    private let note = UI.caption("")
    private let explanation = UI.body()
    private let aidLine = UI.caption("")

    override func build() {
        popup.addItems(withTitles: PaneSettings.colours.map { $0.capitalized })
        popup.target = self
        popup.action = #selector(chooseColour)

        let label = NSTextField(labelWithString: "Idle light")
        label.font = .systemFont(ofSize: 12, weight: .medium)

        explanation.stringValue = """
            What the ring shows when the device has nothing to say — enough to \
            find it on a dark desk without being a nuisance in the room.

            There is no brightness to set. The sensor's ring takes one bit per \
            colour channel and no intensity, so the only dimmer is how many of \
            the three are lit: blue alone is the quietest thing that is still \
            visible, and white is all three. Off is also a choice.
            """

        stack.setViews([UI.row([label, popup], spacing: 12), note,
                        explanation, UI.separator(), aidLine], in: .leading)
        stack.setCustomSpacing(6, after: stack.views[0])
        stack.setCustomSpacing(16, after: note)
        stack.setCustomSpacing(16, after: explanation)
    }

    override func apply(_ status: DeviceStatus?, error: String?) {
        guard let status else {
            popup.isEnabled = false
            note.stringValue = "Connect the device to change its settings."
            aidLine.stringValue = ""
            return
        }
        popup.isEnabled = true
        if let index = PaneSettings.colours.firstIndex(of: status.idleLight) {
            popup.selectItem(at: index)
        }
        if note.stringValue.isEmpty { note.stringValue = "Saved on the device." }

        // Reported rather than offered. The device switches modes on its own by
        // noticing whether this driver is installed, and forcing standard while
        // it is does not stick — the probe upgrades it straight back. A control
        // that undid itself a second later would read as broken.
        aidLine.stringValue = status.aidMode == "pinpad"
            ? "Touch-only mode, chosen by the device because this driver is installed."
            : "Driverless mode. Reconnect the device to switch it now this driver is installed."
    }

    @objc private func chooseColour() {
        let colour = PaneSettings.colours[popup.indexOfSelectedItem]
        popup.isEnabled = false
        note.stringValue = "Saving…"

        DeviceAgent.shared.perform({ console -> String in
            // Try first, unlock only if refused. Every CONFIG_UNLOCK costs a
            // button press whether or not the window is already open, so asking
            // for one before finding out it was needed makes changing an LED
            // cost a trip to wherever the device is plugged in.
            do {
                _ = try console.ask("IDLE_LIGHT \(colour)", timeout: 5)
                return "Saved on the device."
            } catch ConsoleError.refused(_, let reply) where reply.contains("CONFIG_LOCKED") {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: PaneSettings.needsPress, object: nil)
                }
                _ = try console.ask("CONFIG_UNLOCK", timeout: 25)
                _ = try console.ask("IDLE_LIGHT \(colour)", timeout: 5)
                return "Saved on the device."
            }
        }, completion: { [weak self] result in
            guard let self else { return }
            self.popup.isEnabled = true
            switch result {
            case .success(let message):
                self.note.stringValue = message
                DeviceAgent.shared.refresh()
            case .failure(let error):
                self.note.stringValue = "\(error)"
                DeviceAgent.shared.refresh()
            }
        })
    }

    static let needsPress = Notification.Name("io.openhanko.needsPress")
    private var pressObserver: NSObjectProtocol?

    override func viewDidAppear() {
        super.viewDidAppear()
        // Held as a token and released below. Pane's viewDidDisappear removes
        // observers registered with `self` as the observer, which a block-based
        // registration is not — so without this, every visit to this tab adds
        // another live observer and the same message is written several times.
        pressObserver = NotificationCenter.default.addObserver(
            forName: PaneSettings.needsPress, object: nil, queue: .main) { [weak self] _ in
                self?.note.stringValue = "Press the button on the device to confirm."
            }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let pressObserver {
            NotificationCenter.default.removeObserver(pressObserver)
            self.pressObserver = nil
        }
    }
}
