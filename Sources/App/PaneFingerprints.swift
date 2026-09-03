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
//
// It shows the sequence as a checklist rather than a transcript. The steps are
// known before the gesture starts, so appending each instruction as it arrives
// leaves the reader scanning a block of equally-weighted sentences to work out
// which one is current — and once it finishes, five past instructions with no
// outcome among them. A list where exactly one row is live says the same thing
// at a glance, and finishes in a state that reads as finished.

import AppKit

/// One row of the enrolment checklist.
///
/// The name is what the step *is* ("A second reading"), shown when it is not the
/// current one. While it is current the row carries the instruction instead,
/// because that is the only line the user needs to act on.
private final class StepRow: NSView {
    enum State { case pending, active, done, failed }

    private let marker = NSImageView()
    private let text = NSTextField(wrappingLabelWithString: "")
    private let name: String

    init(_ name: String) {
        self.name = name
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: UI.textWidth).isActive = true

        marker.translatesAutoresizingMaskIntoConstraints = false
        marker.setContentHuggingPriority(.required, for: .horizontal)

        text.translatesAutoresizingMaskIntoConstraints = false
        text.font = .systemFont(ofSize: 12)
        text.preferredMaxLayoutWidth = UI.textWidth - 24

        addSubview(marker)
        addSubview(text)
        NSLayoutConstraint.activate([
            marker.leadingAnchor.constraint(equalTo: leadingAnchor),
            marker.widthAnchor.constraint(equalToConstant: 16),
            // Aligned to the first line's cap height rather than centred, so a
            // two-line instruction keeps its marker beside the line it belongs
            // to instead of drifting into the gap between the two.
            marker.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            text.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor),
            text.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        show(.pending)
    }

    required init?(coder: NSCoder) { fatalError("assembled in code") }

    /// `detail` replaces the step's name: the instruction while it is active,
    /// the reason when it fails.
    func show(_ state: State, detail: String? = nil) {
        let symbol: String, tint: NSColor, colour: NSColor
        switch state {
        case .pending:
            symbol = "circle"; tint = .tertiaryLabelColor; colour = .tertiaryLabelColor
        case .active:
            symbol = "arrow.right.circle.fill"; tint = .controlAccentColor; colour = .labelColor
        case .done:
            // A grey tick, not a green one. Every row is ticked by the end, and
            // a column of green reads as five separate pieces of good news
            // rather than one finished job. Green is kept for the result line.
            symbol = "checkmark.circle.fill"; tint = .secondaryLabelColor; colour = .secondaryLabelColor
        case .failed:
            symbol = "xmark.circle.fill"; tint = .systemRed; colour = .systemRed
        }

        marker.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        marker.contentTintColor = tint
        text.stringValue = detail ?? name
        text.textColor = colour
        text.font = .systemFont(ofSize: 12, weight: state == .active ? .medium : .regular)
        setAccessibilityLabel("\(text.stringValue) — \(state)")
    }
}

final class PaneFingerprints: Pane {
    private struct Step {
        let name: String
        let instruction: String
    }

    /// Adding to a device that already knows a finger. The gate has to be opened
    /// by one of them first, which is a step the user can fail.
    private static let gatedSteps = [
        Step(name: "Authorisation",
             instruction: "Rest an enrolled finger on the sensor, then click the button on the device."),
        Step(name: "The new finger",
             instruction: "Lift your finger, then press the new one onto the sensor."),
        Step(name: "A second reading",
             instruction: "Hold still, and press the same finger again when the ring asks."),
    ]

    /// The first finger. The device opens enrolment by itself and keeps offering,
    /// so there is nothing to authorise against and no gate to fail.
    private static let firstSteps = [
        Step(name: "Your finger",
             instruction: "Rest your finger on the sensor."),
        Step(name: "A second reading",
             instruction: "Hold still, and press the same finger again when the ring asks."),
    ]

    private let headline = UI.title("")
    private let count = UI.caption("")
    private let intro = UI.body()
    private let startButton = NSButton()
    private let divider = UI.separator()
    private let steps = UI.column([], spacing: 10)
    private let result = UI.body()

    private var plan: [Step] = []
    private var rows: [StepRow] = []
    private var cursor = 0
    private var gated = false
    private var watching = false
    /// How the last run ended, or nil if none has. Decides what the button
    /// offers, so a finished run always has a way out of the state it left.
    private var lastRun: Bool?

    override func build() {
        startButton.title = "Add a Fingerprint"
        startButton.bezelStyle = .rounded
        startButton.target = self
        startButton.action = #selector(start)

        // The button goes last, under the steps rather than over them.
        //
        // A run that fails leaves the reader at the bottom of a red row with
        // nothing beneath it, and the way out sitting above the rule where the
        // eye has already been. Putting the button after the outcome means the
        // recovery is where the problem is. Before any run there are no steps
        // and no rule, so it lands directly under the intro regardless.
        stack.setViews([headline, count, intro,
                        divider, steps, result, startButton], in: .leading)
        stack.setCustomSpacing(4, after: headline)
        stack.setCustomSpacing(14, after: count)
        stack.setCustomSpacing(16, after: intro)
        stack.setCustomSpacing(16, after: divider)
        stack.setCustomSpacing(14, after: steps)
        stack.setCustomSpacing(16, after: result)

        divider.isHidden = true
        result.isHidden = true
    }

    override func apply(_ status: DeviceStatus?, error: String?) {
        // Never overwrite a running narration with a poll result. The poll fires
        // every two seconds and enrolment takes far longer than that, so without
        // this the instructions would erase the very thing the user is reading.
        guard !watching else { return }

        guard let status, status.sensorPresent, !status.sensorBlocked else {
            headline.stringValue = "Unavailable"
            count.stringValue = ""
            intro.stringValue = status == nil
                ? "Connect the device to manage fingerprints."
                : "The sensor is not answering."
            startButton.isEnabled = false
            return
        }

        startButton.isEnabled = true
        let n = status.templateCount
        headline.stringValue = n == 0 ? "No fingerprint enrolled" : "Enrolled fingers"
        count.stringValue = n == 1 ? "1 finger" : "\(n) fingers"

        if n == 0 {
            intro.stringValue = """
                The ring is breathing purple: the device is waiting for its first \
                finger, and will keep asking until one takes.

                Press the button below and follow the steps.
                """
        } else {
            intro.stringValue = """
                A new finger has to be authorised by one the device already knows.

                Press the button below and follow the steps.
                """
        }

        // After a run the button is the way on from where that run left off, so
        // it says so rather than repeating the opening offer.
        switch lastRun {
        case .some(false): startButton.title = "Try Again"
        case .some(true):  startButton.title = "Add Another"
        case nil:          startButton.title = n == 0 ? "Enrol the First Finger"
                                                      : "Add a Fingerprint"
        }
    }

    @objc private func start() {
        guard !watching else { return }
        watching = true
        startButton.isEnabled = false
        startButton.title = "Watching…"

        // Cleared so that a run which ends without a terminal event falls back
        // to the neutral title rather than showing the previous run's verdict.
        lastRun = nil
        gated = (DeviceAgent.shared.status?.templateCount ?? 0) > 0
        plan = gated ? Self.gatedSteps : Self.firstSteps
        rows.forEach { $0.removeFromSuperview() }
        rows = plan.map { StepRow($0.name) }
        steps.setViews(rows, in: .leading)
        divider.isHidden = false
        result.isHidden = true
        cursor = 0
        paint()

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
                if let error { self.fail("Stopped: \(error)") }
                DeviceAgent.shared.refresh()
                self.apply(DeviceAgent.shared.status, error: nil)
            })
    }

    /// Everything before the cursor is done, the step at it is live, the rest wait.
    private func paint() {
        for (i, row) in rows.enumerated() {
            if i < cursor { row.show(.done) }
            else if i == cursor { row.show(.active, detail: plan[i].instruction) }
            else { row.show(.pending) }
        }
    }

    private func step() {
        cursor += 1
        paint()
    }

    private func succeed(_ message: String) {
        lastRun = true
        cursor = rows.count
        paint()
        result.stringValue = message
        result.textColor = .labelColor
        result.isHidden = false
    }

    /// Fails the live step, so the row that could not be completed is the one
    /// carrying the reason. A failure arriving after the last step — a timeout on
    /// the way out, a dropped connection — has no row to land on and goes below.
    private func fail(_ message: String) {
        lastRun = false
        if cursor < rows.count {
            rows[cursor].show(.failed, detail: message)
        } else {
            result.stringValue = message
            result.textColor = .systemRed
            result.isHidden = false
        }
    }

    /// Something worth saying that is not one of the steps.
    private func note(_ message: String) {
        result.stringValue = message
        result.textColor = .secondaryLabelColor
        result.isHidden = false
    }

    private func narrate(_ line: String) {
        switch line {
        case let l where l.hasPrefix("EVENT ENROLL_OPEN"):
            // Only a step when there was a gate to open. On a blank device the
            // device opens enrolment by itself, so this says nothing new.
            if gated { step() }
        case let l where l.hasPrefix("EVENT ENROLL_REFUSED"):
            fail("Not a finger the device knows. Use one you have already enrolled.")
        case let l where l.hasPrefix("EVENT ENROLL_CAPTURING"):
            step()
        case let l where l.hasPrefix("EVENT ENROLL_OK"):
            succeed("Finger enrolled.")
        case let l where l.hasPrefix("EVENT ENROLL_FAILED"):
            fail("That did not take. Try a different finger — the device refuses "
                 + "one it already knows.")
        case let l where l.hasPrefix("EVENT ENROLL_TIMEOUT"):
            fail("Timed out before a finger arrived. Nothing was stored.")
        case let l where l.hasPrefix("EVENT FINGERPRINT_REJECTED"):
            // Not part of the gesture, but worth saying while someone is looking:
            // the device polls for matches throughout, so a finger it does not
            // know gets refused here too, and silence would read as the sensor
            // having missed the touch.
            note("That finger is not one the device knows.")
        case let l where l.hasPrefix("EVENT MODULE_MISMATCH"):
            fail("Sensor failure. The device is refusing everything.")
        case let l where l.hasPrefix("EVENT TOUCH"):
            break  // presence during unrelated authentication; not this gesture
        default:
            break
        }
    }
}
