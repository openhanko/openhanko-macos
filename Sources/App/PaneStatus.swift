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

    /// Pairing state, and the device it was established for.
    ///
    /// Cached because answering it means running sc_auth twice, which is not
    /// something to do on a two-second poll. Re-asked when the device changes —
    /// including a factory reset, which gives the device a new name along with
    /// its new identity, so the name is a sound key.
    private var pairState: Pairing.State = .unknown
    private var pairCheckedFor: String?

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
        guard pairable else {
            pairButton.isHidden = true
            pairNote.stringValue = ""
            return
        }

        if pairCheckedFor != status.name {
            pairCheckedFor = status.name
            pairState = .unknown
            Pairing.state(deviceName: status.name) { [weak self] state in
                guard let self else { return }
                self.pairState = state
                self.showPairing()
            }
        }
        showPairing()
    }

    /// The button is only there when pressing it would do something.
    ///
    /// Offering to pair a device that is already paired is worse than clutter:
    /// it implies the setup did not take, and the honest answer was one sc_auth
    /// call away the whole time.
    private func showPairing() {
        switch pairState {
        case .unknown:
            pairButton.isHidden = true
            pairNote.stringValue = "Checking whether this Mac already trusts it…"
        case .noIdentity:
            pairButton.isHidden = true
            pairNote.stringValue = "macOS has not read an identity from this device yet."
        case .paired(let label):
            pairButton.isHidden = true
            pairNote.stringValue = "Paired with this Mac · \(label)"
        case .unpaired:
            pairButton.isHidden = false
            pairNote.stringValue = "Runs sc_auth. macOS asks for your password."
        }
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
                // Re-ask rather than assume: pairing that reported success and
                // did not take is exactly the case this pane exists to notice.
                self.pairCheckedFor = nil
                DeviceAgent.shared.refresh()
            case .failure(let error):
                self.pairNote.stringValue = "\(error)"
            }
        }
    }
}
