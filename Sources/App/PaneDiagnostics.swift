// Everything the device will say about itself.
//
// TRACE is the tool that settled most of the firmware's behaviour, and it has
// only ever been reachable from a terminal. It is the difference between "it did
// not work" and "macOS never asked the card anything", which are the same
// experience and completely different problems.

import AppKit

final class PaneDiagnostics: Pane {
    private let fields = UI.column([], spacing: 4)
    private let sensorLine = UI.monoBlock("")
    private let traceView = NSTextView()
    private let refreshButton = NSButton()
    private let copyButton = NSButton()

    override func build() {
        refreshButton.title = "Read Trace"
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(readTrace)

        copyButton.title = "Copy Diagnostics"
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyAll)

        traceView.isEditable = false
        traceView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        traceView.string = "The device keeps a ring buffer of recent card activity.\n"
            + "Read Trace shows it: APDUs, CCID requests, and when a finger was seen."

        let scroll = NSScrollView()
        scroll.documentView = traceView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: UI.textWidth).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true

        stack.setViews([fields, sensorLine, UI.separator(),
                        UI.row([refreshButton, copyButton]), scroll], in: .leading)
        stack.setCustomSpacing(12, after: fields)
        stack.setCustomSpacing(14, after: sensorLine)
        stack.setCustomSpacing(12, after: stack.views[3])
    }

    override func apply(_ status: DeviceStatus?, error: String?) {
        fields.setViews(rows(for: status, error: error), in: .leading)
        refreshButton.isEnabled = status != nil
        copyButton.isEnabled = status != nil
        if status == nil { sensorLine.stringValue = "" }
    }

    private func rows(for status: DeviceStatus?, error: String?) -> [NSView] {
        guard let status else {
            return [UI.body(error ?? "No device connected.")]
        }
        // Named in the words the rest of the app uses, not the console's keys.
        // The raw line is still one button away for anyone who wants it.
        return [
            UI.field("Device", status.name),
            UI.field("Silicon", status.chip),
            UI.field("Identity", status.hasIdentity ? "on the device" : "none"),
            UI.field("Encrypted at rest", status.hasSecret ? "yes" : "no"),
            UI.field("Sensor", status.sensorBlocked ? "not the one it was set up with"
                        : (status.sensorPresent ? "present and bound" : "not answering")),
            UI.field("Touch line", status.touchLine),
            UI.field("Fingers enrolled", "\(status.templateCount)"),
            UI.field("Mode", status.aidMode),
            UI.field("Driver bound", status.driverClaimed ? "yes" : "no"),
            UI.field("Idle light", status.idleLight),
        ]
    }

    @objc private func readTrace() {
        refreshButton.isEnabled = false
        traceView.string = "Reading…"
        DeviceAgent.shared.perform({ console -> [String] in
            var out = try console.ask("TRACE", timeout: 10)
            // The sensor's own identity is worth having beside the trace: most
            // "it stopped working" reports are really about the module.
            if let info = try? console.ask("FINGERPRINT_INFO", timeout: 5).last {
                out.append(info)
            }
            return out
        }, completion: { [weak self] result in
            guard let self else { return }
            self.refreshButton.isEnabled = true
            switch result {
            case .success(let lines):
                let trace = lines.filter { $0.hasPrefix("TRACE") }
                self.traceView.string = trace.isEmpty
                    ? "Nothing recorded yet. Use the device — sign in, or run sudo — and read again."
                    : trace.joined(separator: "\n")
                if let info = lines.first(where: { $0.hasPrefix("OK FINGERPRINT_INFO") }) {
                    self.sensorLine.stringValue = String(info.dropFirst("OK FINGERPRINT_INFO ".count))
                }
            case .failure(let error):
                self.traceView.string = "\(error)"
            }
        })
    }

    @objc private func copyAll() {
        DeviceAgent.shared.perform({ console -> String in
            var report = ["OpenHanko diagnostics"]
            for command in ["STATUS", "FINGERPRINT_INFO", "OTP_STATUS", "TRACE"] {
                report.append("\n$ \(command)")
                if let lines = try? console.ask(command, timeout: 10) {
                    report.append(contentsOf: lines)
                } else {
                    report.append("(no answer)")
                }
            }
            return report.joined(separator: "\n")
        }, completion: { result in
            guard case .success(let text) = result else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        })
    }
}
