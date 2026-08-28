// What the device is doing, and what to do about it.
//
// The old window said one of three things and all three assumed the device was
// healthy. Most of what can actually go wrong — a swapped sensor, no enrolled
// finger, no identity — showed only as a colour on the ring, which is unreadable
// without the leaflet and invisible in a bag. This pane says those out loud, and
// offers the one action that fixes each.

import AppKit

final class PaneStatus: Pane {
    private let dot = NSTextField(labelWithString: "●")
    private let headline = UI.title("")
    private let detail = UI.body()
    private let name = UI.caption("")
    private let pairButton = NSButton()
    private let pairNote = UI.caption("")

    override func build() {
        dot.font = .systemFont(ofSize: 13)
        let status = UI.row([dot, headline], spacing: 6)

        pairButton.title = "Pair with this Mac…"
        pairButton.bezelStyle = .rounded
        pairButton.target = self
        pairButton.action = #selector(pair)
        pairButton.isHidden = true

        stack.setViews([status, name, detail, UI.separator(), pairButton, pairNote],
                       in: .leading)
        stack.setCustomSpacing(4, after: status)
        stack.setCustomSpacing(16, after: name)
        stack.setCustomSpacing(16, after: detail)
        stack.setCustomSpacing(6, after: pairButton)
    }

    override func apply(_ status: DeviceStatus?, error: String?) {
        guard let status else {
            dot.textColor = .tertiaryLabelColor
            headline.stringValue = "No device connected"
            name.stringValue = ""
            detail.stringValue = """
                Plug in your OpenHanko. It works on any Mac with nothing \
                installed; this app adds settings, guided enrolment and \
                diagnostics.

                If it is plugged in and this does not change, another program may \
                be holding its serial port — provision.py, or a terminal.
                """
            pairButton.isHidden = true
            pairNote.stringValue = ""
            return
        }

        let finding = status.finding
        switch finding.severity {
        case .blocking:  dot.textColor = .systemRed
        case .attention: dot.textColor = .systemOrange
        case .fine:      dot.textColor = .systemGreen
        }
        headline.stringValue = finding.headline
        detail.stringValue = finding.detail
        name.stringValue = "\(status.name) · \(status.chip) · \(status.aidMode) mode"

        // Pairing is offered only when it can succeed. A device with no identity
        // has nothing for macOS to pair against, and one with no finger would
        // pair and then refuse every signature — which reads as the pairing
        // having failed.
        let pairable = status.hasIdentity && status.templateCount > 0
        pairButton.isHidden = !pairable
        pairNote.stringValue = pairable
            ? "Runs sc_auth. macOS asks for your password."
            : ""
    }

    @objc private func pair() {
        guard let status = DeviceAgent.shared.status else { return }
        pairButton.isEnabled = false
        pairNote.stringValue = "Looking for the card in macOS…"
        Pairing.pair(deviceName: status.name) { [weak self] result in
            guard let self else { return }
            self.pairButton.isEnabled = true
            switch result {
            case .success(let message):
                self.pairNote.stringValue = message
            case .failure(let error):
                self.pairNote.stringValue = "\(error)"
            }
        }
    }
}
