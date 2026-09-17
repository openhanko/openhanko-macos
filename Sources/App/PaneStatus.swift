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
    private let testButton = NSButton()
    /// The sudo command to run when the password dialog could not pair.
    private var pendingCommand: String?
    // Wrapping and selectable: it can carry a command to paste, and a
    // single-line caption clipped it after the first line.
    private let pairNote: NSTextField = {
        let field = UI.body()
        field.isSelectable = true
        return field
    }()
    private let testNote = UI.body()

    // The one place an update announces itself without being asked. This pane is
    // what opens, so a line here is the difference between a check that informs
    // somebody and a check that waits to be discovered.
    private let updateNote = UI.body()
    private var updatesObserver: NSObjectProtocol?

    /// Pairing state, and the device it was established for.
    ///
    /// Cached because answering it means running sc_auth twice, which is not
    /// something to do on a two-second poll. Re-asked when the device changes —
    /// including a factory reset, which gives the device a new name along with
    /// its new identity, so the name is a sound key.
    private var pairState: Pairing.State = .unknown
    private var pairCheckedFor: String?

    /// The outcome of the last Pair press, kept until the next press or until
    /// the device changes. Without this the two-second poll's showPairing()
    /// overwrote the result within a cycle, so a failure was on screen for
    /// about as long as it took to notice something had flashed.
    private var pairMessage: String?
    /// Polls tick every two seconds; sc_auth is asked again every fifth one
    /// while a pairing command is outstanding, so the pane notices success
    /// without being told and without hammering sc_auth.
    private var pollsSincePairCheck = 0

    override func build() {
        dot.font = .systemFont(ofSize: 13)
        let status = UI.row([dot, headline], spacing: 6)

        pairButton.title = "Pair in Terminal…"
        pairButton.bezelStyle = .rounded
        pairButton.target = self
        pairButton.action = #selector(pair)
        pairButton.isHidden = true

        testButton.title = "Test Authentication"
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testAuth)
        testButton.isHidden = true

        updateNote.isHidden = true
        stack.setViews([status, name, detail, UI.separator(),
                        UI.row([pairButton, testButton]), pairNote, testNote,
                        updateNote],
                       in: .leading)
        stack.setCustomSpacing(4, after: status)
        stack.setCustomSpacing(16, after: name)
        stack.setCustomSpacing(16, after: detail)
        stack.setCustomSpacing(8, after: stack.views[4])
        stack.setCustomSpacing(10, after: pairNote)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updatesObserver = NotificationCenter.default.addObserver(
            forName: Updates.changed, object: nil, queue: .main) { [weak self] _ in
                self?.showUpdates(DeviceAgent.shared.status)
            }
        showUpdates(DeviceAgent.shared.status)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let updatesObserver {
            NotificationCenter.default.removeObserver(updatesObserver)
            self.updatesObserver = nil
        }
    }

    /// One line, naming what is waiting and where to go. Deliberately not a
    /// button: everything it could offer lives one tab away, and a second route
    /// to the same two actions is how a small window stops being small.
    private func showUpdates(_ status: DeviceStatus?) {
        let app = Updates.appUpdate
        let firmware = Updates.firmwareUpdate(forDeviceVersion: status?.firmwareVersion,
                                              connected: status != nil)
        let waiting = [app.map { "OpenHanko \($0.version)" },
                       firmware.map { "firmware \($0.version)" }].compactMap { $0 }
        guard !waiting.isEmpty else {
            updateNote.isHidden = true
            return
        }
        let sentence = waiting.count == 2
            ? "\(waiting[0]) and \(waiting[1]) are available — see the Update tab."
            : "\(waiting[0]) is available — see the Update tab."

        // A vermilion dot carries the notice; the sentence stays the weight of
        // every other line on this pane. Colouring the whole sentence would make
        // an available update look like a fault.
        let line = NSMutableAttributedString(
            string: "● ",
            attributes: [.foregroundColor: UI.shu,
                         .font: NSFont.systemFont(ofSize: 12)])
        line.append(NSAttributedString(
            string: sentence,
            attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                         .font: NSFont.systemFont(ofSize: 12)]))
        updateNote.attributedStringValue = line
        updateNote.isHidden = false
    }

    override func apply(_ status: DeviceStatus?, error: String?) {
        showUpdates(status)
        testNote.stringValue = testNote.stringValue.isEmpty ? "" : testNote.stringValue
        guard let status else {
            testButton.isHidden = true
            dot.textColor = .tertiaryLabelColor
            headline.stringValue = "No device connected"
            name.stringValue = ""
            detail.stringValue = """
                Plug in your OpenHanko.

                If it is plugged in and nothing changes, another program has its \
                serial port — provision.py, or a terminal.
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
        // Testing needs a key macOS can reach and a finger to authorise with,
        // which is the same bar as pairing.
        testButton.isHidden = !pairable

        guard pairable else {
            pairButton.isHidden = true
            pairNote.stringValue = ""
            return
        }

        var recheck = false
        if case .unpaired = pairState, pairMessage != nil {
            pollsSincePairCheck += 1
            if pollsSincePairCheck >= 5 { pollsSincePairCheck = 0; recheck = true }
        }
        if pairCheckedFor != status.name || recheck {
            if pairCheckedFor != status.name { pairMessage = nil; pendingCommand = nil }
            pairCheckedFor = status.name
            pairState = .unknown
            Pairing.state(deviceName: status.name) { [weak self] state in
                guard let self else { return }
                self.pairState = state
                // The command the user was handed has done its job.
                if case .paired = state { self.pairMessage = nil; self.pendingCommand = nil }
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
        // A result the user has not yet dismissed wins over the state line.
        if let pairMessage {
            if case .unpaired(_) = pairState { pairButton.isHidden = false }
            else { pairButton.isHidden = true }
            pairNote.stringValue = pairMessage
            return
        }
        switch pairState {
        case .unknown:
            pairButton.isHidden = true
            pairNote.stringValue = "Checking pairing…"
        case .noIdentity:
            pairButton.isHidden = true
            pairNote.stringValue = "macOS has not read an identity from this device yet."
        case .paired(let label):
            pairButton.isHidden = true
            pairNote.stringValue = "Paired with this Mac · \(label)"
        case .unpaired:
            pairButton.isHidden = false
            pairNote.stringValue = "Opens a Terminal window, where sudo asks for your password once."
        }
    }

    /// Asks the card to sign something, which is the only honest way to answer
    /// "is this working" without waiting for the lock screen to ask.
    @objc private func testAuth() {
        guard let status = DeviceAgent.shared.status else { return }
        testButton.isEnabled = false
        testButton.title = "Touch the sensor…"
        testNote.stringValue = "Rest your finger on the sensor."
        AuthTest.run(deviceName: status.name) { [weak self] outcome in
            guard let self else { return }
            self.testButton.isEnabled = true
            self.testButton.title = "Test Authentication"
            self.testNote.stringValue = outcome.summary + "\n\n" + outcome.detail
            self.testNote.textColor = outcome.ok ? .secondaryLabelColor : .systemRed
        }
    }

    @objc private func openTerminal() {
        guard let command = pendingCommand else { return }
        do {
            try Pairing.openInTerminal(command: command)
            pairMessage = "Finish in the Terminal window — sudo asks for your password once. "
                + "This pane switches to Paired by itself.\n\nThe command, also on the clipboard:\n\(command)"
        } catch {
            pairMessage = "Could not open a terminal: \(error.localizedDescription)\n\n\(command)"
        }
        showPairing()
    }

    @objc private func pair() {
        guard let status = DeviceAgent.shared.status else { return }
        pairButton.isEnabled = false
        pairMessage = nil
        pendingCommand = nil
        pairNote.stringValue = "Looking for the card in macOS…"
        Pairing.pair(deviceName: status.name) { [weak self] outcome in
            guard let self else { return }
            self.pairButton.isEnabled = true
            switch outcome {
            case .paired(let message):
                self.pairMessage = message
                // Re-ask rather than assume: pairing that reported success and
                // did not take is exactly the case this pane exists to notice.
                self.pairState = .unknown
                Pairing.state(deviceName: status.name) { [weak self] state in
                    guard let self else { return }
                    self.pairState = state
                    self.showPairing()
                }
            case .needsTerminal(let command, _):
                self.pendingCommand = command
                let board = NSPasteboard.general
                board.clearContents()
                board.setString(command, forType: .string)
                self.openTerminal()
            case .failed(let message):
                self.pairMessage = message
            }
            self.showPairing()
        }
    }
}
