// Adding a finger, with the device narrating.
//
// The gesture is sound and completely blind: rest an enrolled finger, click the
// button, lift, present the new one. The only feedback is the ring, so someone
// who does not already know the sequence cannot tell "waiting for you to lift"
// from "nothing happened", and a refusal from a timeout.
//
// The device has been saying all of it on the console the whole time —
// ENROLL_OPEN, ENROLL_REFUSED, ENROLL_CAPTURING, ENROLL_OK, ENROLL_TIMEOUT.
// Nothing was listening. This pane listens.

import AppKit

final class PaneFingerprints: Pane {
    private let headline = UI.title("")
    private let count = UI.caption("")
    private let instructions = UI.body()
    private let startButton = NSButton()
    private let log = UI.body()
    private var watching = false

    override func build() {
        startButton.title = "Add a Fingerprint"
        startButton.bezelStyle = .rounded
        startButton.target = self
        startButton.action = #selector(start)

        log.textColor = .labelColor

        stack.setViews([headline, count, instructions, startButton,
                        UI.separator(), log], in: .leading)
        stack.setCustomSpacing(4, after: headline)
        stack.setCustomSpacing(14, after: count)
        stack.setCustomSpacing(16, after: instructions)
        stack.setCustomSpacing(16, after: startButton)
    }

    override func apply(_ status: DeviceStatus?, error: String?) {
        // Never overwrite a running narration with a poll result. The poll fires
        // every two seconds and enrolment takes far longer than that, so without
        // this the instructions would erase the very thing the user is reading.
        guard !watching else { return }

        guard let status, status.sensorPresent, !status.sensorBlocked else {
            headline.stringValue = "Unavailable"
            count.stringValue = ""
            instructions.stringValue = status == nil
                ? "Connect the device to manage fingerprints."
                : "The sensor is not answering, or is not the one this device was set up with."
            startButton.isEnabled = false
            return
        }

        startButton.isEnabled = true
        let n = status.templateCount
        headline.stringValue = n == 0 ? "No fingerprint enrolled" : "Enrolled fingers"
        count.stringValue = n == 1 ? "1 finger" : "\(n) fingers"

        if n == 0 {
            startButton.title = "Enrol the First Finger"
            instructions.stringValue = """
                The device is already asking — its ring is breathing purple, and \
                it will keep asking until a finger takes.

                Rest the same finger on the sensor twice. Press Start and this \
                window will follow along.
                """
        } else {
            startButton.title = "Add a Fingerprint"
            instructions.stringValue = """
                Adding a finger is the one thing that grows what the device will \
                do, so it has to be authorised by a finger it already knows.

                Rest an enrolled finger on the sensor and click the button on the \
                device. Then lift, and present the new finger. Press Start first \
                and this window will follow along.
                """
        }
    }

    @objc private func start() {
        guard !watching else { return }
        watching = true
        startButton.isEnabled = false
        startButton.title = "Watching…"
        log.stringValue = "Waiting for the device.\n"

        let enrolled = DeviceAgent.shared.status?.templateCount ?? 0
        if enrolled > 0 {
            say("Rest an enrolled finger on the sensor, then click the button on the device.")
        } else {
            say("Rest your finger on the sensor.")
        }

        // Long enough for the whole gesture: the device gives 30 s to present the
        // new finger after the gate opens, and someone reading instructions for
        // the first time is slower than that allows for.
        DeviceAgent.shared.listen(
            seconds: 90,
            stopWhen: { line in
                line.hasPrefix("EVENT ENROLL_OK") || line.hasPrefix("EVENT ENROLL_FAILED")
                    || line.hasPrefix("EVENT ENROLL_TIMEOUT")
            },
            onLine: { [weak self] line in self?.narrate(line) },
            completion: { [weak self] error in
                guard let self else { return }
                self.watching = false
                self.startButton.isEnabled = true
                if let error { self.say("Stopped: \(error)") }
                DeviceAgent.shared.refresh()
                self.apply(DeviceAgent.shared.status, error: nil)
            })
    }

    private func narrate(_ line: String) {
        switch line {
        case let l where l.hasPrefix("EVENT ENROLL_OPEN"):
            say("Accepted. Lift your finger, then press the new one onto the sensor.")
        case let l where l.hasPrefix("EVENT ENROLL_REFUSED"):
            say("That finger is not one the device knows — it flashed red and nothing opened. "
                + "Use a finger you have already enrolled.")
        case let l where l.hasPrefix("EVENT ENROLL_CAPTURING"):
            say("Reading. Hold still, and press the same finger again when the ring asks.")
        case let l where l.hasPrefix("EVENT ENROLL_OK"):
            say("Done. The finger is enrolled.")
        case let l where l.hasPrefix("EVENT ENROLL_FAILED"):
            say("That did not take. The most common cause is a second finger that the device "
                + "already knows — it refuses duplicates on purpose. Try a different finger.")
        case let l where l.hasPrefix("EVENT ENROLL_TIMEOUT"):
            say("The window closed before a finger arrived. Nothing was stored; start again.")
        case let l where l.hasPrefix("EVENT MODULE_MISMATCH"):
            say("The device is refusing everything: this is not the sensor it was set up with.")
        case let l where l.hasPrefix("EVENT TOUCH"):
            break  // presence during unrelated authentication; not this gesture
        default:
            break
        }
    }

    private func say(_ text: String) {
        log.stringValue += text + "\n"
    }
}
