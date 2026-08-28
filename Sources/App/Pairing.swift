// Pairing the card to the account, without a terminal.
//
// This was the one setup step that still needed a shell: read a hash out of
// `sc_auth identities`, then run `sudo sc_auth pair` with it. Neither half is
// hard, and neither is something to ask a person to do by hand — the hash is
// forty hex characters and the consequence of pasting the wrong one is an
// account that trusts a card you do not have.

import Foundation

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

    /// Finds this device's identity and pairs it, prompting for a password.
    ///
    /// The privilege prompt is macOS's own, raised through osascript. An app that
    /// asked for the password itself and then ran sudo would be teaching exactly
    /// the habit that makes phishing work.
    static func pair(deviceName: String,
                     completion: @escaping (Result<String, Failure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let finish = { (result: Result<String, Failure>) in
                DispatchQueue.main.async { completion(result) }
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
                    return finish(.failure(Failure(description:
                        "macOS does not see a smart-card identity on this device.")))
                }

                // Prefer the identity that names this device, so two OpenHankos
                // on one Mac do not pair the wrong one. Then the authentication
                // certificate, then whatever is there.
                let chosen = candidates.first(where: { $0.label.contains(deviceName) })
                    ?? candidates.first(where: { $0.label.lowercased().contains("authentication") })
                    ?? candidates[0]

                if pairedHashes().contains(chosen.hash) {
                    return finish(.success("Already paired — \(chosen.label)"))
                }

                let user = NSUserName()
                let script = "do shell script \"/usr/sbin/sc_auth pair -u \(user) -h \(chosen.hash)\""
                    + " with administrator privileges"
                let output = try run("/usr/bin/osascript", ["-e", script])

                if pairedHashes().contains(chosen.hash) {
                    finish(.success("Paired. Test with: sudo -k && sudo -v"))
                } else {
                    let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    finish(.failure(Failure(description:
                        detail.isEmpty ? "Pairing did not take." : detail)))
                }
            } catch {
                finish(.failure(Failure(description: "\(error)")))
            }
        }
    }
}
