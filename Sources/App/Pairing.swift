// Pairing the card to the account, without a terminal.
//
// This was the one setup step that still needed a shell: read a hash out of
// `sc_auth identities`, then run `sudo sc_auth pair` with it. Neither half is
// hard, and neither is something to ask a person to do by hand — the hash is
// forty hex characters and the consequence of pasting the wrong one is an
// account that trusts a card you do not have.

import AppKit
import Foundation
import os

private let log = Logger(subsystem: "io.openhanko.app", category: "pairing")

enum Pairing {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Runs a tool and returns its combined output.
    private static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Public-key hashes the card is publishing, newest first, with their labels.
    static func identities() throws -> [(hash: String, label: String)] {
        let output = try run("/usr/sbin/sc_auth", ["identities"])
        var found: [(String, String)] = []
        for line in output.split(separator: "\n") {
            let text = String(line)
            // Forty hex characters, then whitespace, then a human label.
            guard let range = text.range(of: "\\b[0-9A-Fa-f]{40}\\b",
                                         options: .regularExpression) else { continue }
            let hash = String(text[range])
            let label = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            found.append((hash, label))
        }
        return found
    }

    /// Hashes already trusted for this account.
    static func pairedHashes() -> Set<String> {
        guard let output = try? run("/usr/sbin/sc_auth", ["list", "-u", NSUserName()]) else {
            return []
        }
        var hashes: Set<String> = []
        for line in output.split(separator: "\n") {
            let text = String(line)
            if let range = text.range(of: "\\b[0-9A-Fa-f]{40}\\b", options: .regularExpression) {
                hashes.insert(String(text[range]))
            }
        }
        return hashes
    }

    enum State {
        case unknown
        case noIdentity
        case paired(String)
        case unpaired(String)
    }

    /// Whether this device is already trusted by this account.
    ///
    /// Both halves are shell-outs, so this is not something to run on every
    /// status poll — the caller caches it and re-asks when the device changes.
    static func state(deviceName: String, completion: @escaping (State) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let answer: State
            let candidates = (try? identities()) ?? []
            if candidates.isEmpty {
                answer = .noIdentity
            } else {
                let chosen = candidates.first(where: { $0.label.contains(deviceName) })
                    ?? candidates.first(where: { $0.label.lowercased().contains("authentication") })
                    ?? candidates[0]
                answer = pairedHashes().contains(chosen.hash)
                    ? .paired(chosen.label)
                    : .unpaired(chosen.label)
            }
            DispatchQueue.main.async { completion(answer) }
        }
    }

    /// What a Pair press came to.
    enum PairOutcome {
        case paired(String)
        /// The password dialog could not finish it; this command, run with
        /// sudo in a terminal, can.
        case needsTerminal(command: String, reason: String)
        case failed(String)
    }

    /// Finds this device's identity and pairs it through macOS's own password
    /// dialog, falling back to a terminal command when that cannot work.
    ///
    /// sc_auth pair needs two things at once: root, and the ctkd of the session
    /// that holds the token. Plain `osascript … with administrator privileges`
    /// got the first by losing the second — its helper runs in the system
    /// bootstrap namespace, where `com.apple.ctkd.token-client` resolves to the
    /// system ctkd (`-st`), which refused "non-existing/missing tokenID" and
    /// surfaced as CryptoTokenKit error -8. Measured. Mach lookups are scoped by
    /// namespace, not by uid, which is why `sudo` from a terminal works: it
    /// stays in the user's namespace. `launchctl asuser` puts the root command
    /// back into it.
    ///
    /// The app never collects the password itself — an app that asked for it
    /// and ran sudo would teach exactly the habit that makes phishing work.
    static func pair(deviceName: String, completion: @escaping (PairOutcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let finish = { (outcome: PairOutcome) in
                DispatchQueue.main.async { completion(outcome) }
            }
            do {
                // macOS can take a moment to read a freshly inserted card.
                var candidates: [(hash: String, label: String)] = []
                for _ in 0..<10 {
                    candidates = try identities()
                    if !candidates.isEmpty { break }
                    Thread.sleep(forTimeInterval: 1)
                }
                guard !candidates.isEmpty else {
                    return finish(.failed("macOS does not see a smart-card identity on this device."))
                }

                // Prefer the identity that names this device, so two OpenHankos
                // on one Mac do not pair the wrong one. Then the authentication
                // certificate, then whatever is there.
                let chosen = candidates.first(where: { $0.label.contains(deviceName) })
                    ?? candidates.first(where: { $0.label.lowercased().contains("authentication") })
                    ?? candidates[0]

                if pairedHashes().contains(chosen.hash) {
                    return finish(.paired("Already paired — \(chosen.label)"))
                }

                let user = NSUserName()
                let command = "sudo sc_auth pair -u \(user) -h \(chosen.hash)"
                let script = "do shell script \"/bin/launchctl asuser \(getuid()) "
                    + "/usr/sbin/sc_auth pair -u \(user) -h \(chosen.hash)\" with administrator privileges"
                let output = try run("/usr/bin/osascript", ["-e", script])
                log.error("sc_auth pair -h \(chosen.hash, privacy: .public) via launchctl asuser said: \(output, privacy: .public)")

                if pairedHashes().contains(chosen.hash) {
                    return finish(.paired("Paired. Test with: sudo -k && sudo -v"))
                }
                // osascript reports a dismissed dialog as error -128.
                if output.contains("-128") {
                    return finish(.failed("Cancelled — nothing was changed."))
                }
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                finish(.needsTerminal(command: command,
                                      reason: detail.isEmpty ? "pairing did not take" : detail))
            } catch {
                finish(.failed("\(error)"))
            }
        }
    }

    /// Opens the pairing command in the user's terminal, where sudo keeps the
    /// session that holds the token.
    ///
    /// A `.command` file rather than scripting Terminal: the app runs with the
    /// hardened runtime and no Apple Events entitlement, and opening a file
    /// needs no automation permission. It also lands in whichever terminal the
    /// user has set to open `.command` files.
    static func openInTerminal(command: String) throws {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.openhanko.app", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("pair-openhanko.command")
        let body = """
            #!/bin/zsh
            # Written by the OpenHanko app to pair this Mac with your device. Safe to delete.
            echo "Pairing your OpenHanko with this Mac."
            echo "sudo asks for your login password; nothing is shown as you type."
            echo
            if \(command); then
              echo; echo "Paired. You can close this window."
            else
              echo; echo "Pairing failed — the lines above say why."
            fi

            """
        try body.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }
}
