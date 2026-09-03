// What the device says about itself, and what that means in words.
//
// STATUS is one line of key=value pairs written for whoever is debugging the
// firmware. This turns it into the two things a person actually wants: is
// anything wrong, and what should I do about it.
//
// The mapping matters more than it looks. A device whose sensor has been swapped
// shows red on the ring and nothing else — someone without the leaflet has a
// dead object and no way to learn why. Every condition below that is worth
// saying out loud is said out loud.

import Foundation

struct DeviceStatus {
    var fields: [String: String] = [:]

    var name: String { fields["name"] ?? "OpenHanko" }
    var chip: String { fields["chip"] ?? "unknown" }
    var aidMode: String { fields["aid"] ?? "standard" }
    var idleLight: String { fields["idle"] ?? "blue" }
    var templateCount: Int { Int(fields["fp"] ?? "") ?? 0 }
    var hasIdentity: Bool { fields["keys"] == "loaded" }
    var hasSecret: Bool { fields["otp"] == "set" }
    var sensorPresent: Bool { fields["presence"] == "fingerprint" }
    var sensorBlocked: Bool { fields["presence"] == "blocked" }
    var touchLine: String { fields["touch"] ?? "unwired" }
    var driverClaimed: Bool { fields["claimed"] == "yes" }

    /// Parses `OK STATUS a=b c="d e" ...`.
    ///
    /// Hand-rolled rather than split-on-space: the device name is quoted and
    /// contains one, and splitting naively truncated it to `name="OpenHanko`.
    init(line: String) {
        var rest = Substring(line)
        while let equals = rest.firstIndex(of: "=") {
            let keyStart = rest[rest.startIndex..<equals]
                .lastIndex(where: { $0 == " " }).map { rest.index(after: $0) } ?? rest.startIndex
            let key = String(rest[keyStart..<equals])
            var valueStart = rest.index(after: equals)
            var value = ""
            if valueStart < rest.endIndex, rest[valueStart] == "\"" {
                valueStart = rest.index(after: valueStart)
                if let closing = rest[valueStart...].firstIndex(of: "\"") {
                    value = String(rest[valueStart..<closing])
                    rest = rest[rest.index(after: closing)...]
                } else {
                    value = String(rest[valueStart...])
                    rest = rest[rest.endIndex...]
                }
            } else if let space = rest[valueStart...].firstIndex(of: " ") {
                value = String(rest[valueStart..<space])
                rest = rest[space...]
            } else {
                value = String(rest[valueStart...])
                rest = rest[rest.endIndex...]
            }
            if !key.isEmpty { fields[key] = value }
        }
    }

    static func read(_ console: DeviceConsole) throws -> DeviceStatus {
        let lines = try console.ask("STATUS", timeout: 5)
        guard let status = lines.last(where: { $0.hasPrefix("OK STATUS") }) else {
            throw ConsoleError.noAnswer("STATUS")
        }
        return DeviceStatus(line: status)
    }
}

/// Something the user should know, in the order they should know it.
struct Finding {
    enum Severity { case blocking, attention, fine }
    let severity: Severity
    let headline: String
    let detail: String
}

extension DeviceStatus {
    /// The one thing to say, chosen rather than accumulated.
    ///
    /// Ordered by what stops the device working. A unit with a swapped sensor
    /// also has no enrolled finger from its own point of view, and telling
    /// someone to enrol one when nothing will accept it is worse than saying
    /// nothing.
    var finding: Finding {
        if sensorBlocked {
            return Finding(
                severity: .blocking,
                headline: "Sensor failure",
                detail: """
                The device cannot confirm its fingerprint sensor, so it is \
                refusing to authenticate.

                Factory reset clears this: hold the button while plugging the \
                device in. It erases the key, so you will need to pair again.
                """)
        }
        if !sensorPresent {
            return Finding(
                severity: .blocking,
                headline: "No fingerprint sensor",
                detail: """
                The sensor is not answering, so the device cannot authenticate. \
                This is a hardware fault, not a setting.
                """)
        }
        if !hasIdentity {
            return Finding(
                severity: .blocking,
                headline: "No identity yet",
                detail: """
                The device makes its own key the first time it starts with a \
                working sensor. If this does not clear, check Diagnostics.
                """)
        }
        if templateCount == 0 {
            return Finding(
                severity: .attention,
                headline: "No fingerprint enrolled",
                detail: """
                The ring is breathing purple and will keep asking. Rest the same \
                finger on the sensor twice, or open Fingerprints to be talked \
                through it.
                """)
        }
        if !hasSecret {
            return Finding(
                severity: .attention,
                headline: "Not encrypted at rest",
                detail: """
                This device has no secret in one-time memory, so its key material \
                is stored unwrapped. Provisioned units have one; a development \
                board may not.
                """)
        }
        if touchLine == "unwired" {
            return Finding(
                severity: .attention,
                headline: "Touch line not connected",
                detail: """
                The sensor's TouchOut wire is missing. Everything still works, \
                but the device cannot check that a finger is really present.
                """)
        }
        return Finding(
            severity: .fine,
            headline: aidMode == "pinpad" ? "Ready — no PIN prompts" : "Ready",
            detail: aidMode == "pinpad"
                ? """
                  macOS asks the device instead of asking you. When something \
                  needs you the ring flashes blue — touch it.
                  """
                : """
                  macOS is using its own driver, so you will see a PIN box. \
                  Touching the sensor fills it in.

                  Reconnect the device to switch to touch-only mode.
                  """)
    }
}
