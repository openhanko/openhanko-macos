// A line-oriented connection to the device's USB CDC console.
//
// The same protocol `provision.py` speaks, and for the same reason: the console
// is where the device says what it can see, and until now that only existed in a
// terminal. Everything this app knows beyond "a token is present" comes through
// here.
//
// One process owns a serial device at a time, so the app and `provision.py`
// cannot both have it. DeviceAgent holds a single connection for as long as the
// app runs and closing the window quits the app, which makes that a rule someone
// can hold in their head — better than opening per command, which spent a
// second settling the endpoint each time and still owned the port a third of the
// time on a two-second poll.

import Foundation

enum ConsoleError: Error, CustomStringConvertible {
    case noDevice
    case cannotOpen(String, String)
    case noAnswer(String)
    case refused(String, String)

    var description: String {
        switch self {
        case .noDevice:
            return "No OpenHanko is connected."
        case .cannotOpen(let port, let why):
            return "Cannot open \(port): \(why)"
        case .noAnswer(let command):
            return "The device did not answer \(command)."
        case .refused(let command, let reply):
            return "The device refused \(command): \(reply)"
        }
    }
}

final class DeviceConsole {
    private let fd: Int32
    private var buffer = Data()
    let port: String

    /// Candidate CDC ports, newest first.
    ///
    /// `cu.` rather than `tty.`: the tty variant blocks on open until DCD is
    /// asserted, which a CDC gadget never does, so opening one hangs forever.
    static func ports() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.usbmodem") }
            .sorted()
            .map { "/dev/\($0)" }
    }

    init(port: String) throws {
        self.port = port
        // Darwin.open explicitly: an unqualified open() resolves to this
        // type's own connect-by-any-name factory when one exists, and the
        // error that produces points at the assignment rather than the call.
        fd = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fd < 0 {
            throw ConsoleError.cannotOpen(port, String(cString: strerror(errno)))
        }

        // Claim it exclusively, or two clients share one line.
        //
        // macOS does not lock a cu. device on open: the app and provision.py
        // both succeeded against the same port, and what they get is not an
        // error but each other's replies interleaved — a command answered by
        // somebody else's OK, which on a line protocol is indistinguishable from
        // the firmware misbehaving. TIOCEXCL turns that into EBUSY on the second
        // opener, which is a sentence someone can act on.
        if ioctl(fd, TIOCEXCL) != 0 {
            let why = String(cString: strerror(errno))
            Darwin.close(fd)
            throw ConsoleError.cannotOpen(port, "already in use (\(why))")
        }

        var settings = termios()
        if tcgetattr(fd, &settings) == 0 {
            cfmakeraw(&settings)
            _ = tcsetattr(fd, TCSANOW, &settings)
        }

        // macOS needs a moment to finish bringing the CDC endpoint up, and a
        // client killed mid-write can leave half a command in the firmware's line
        // buffer. A bare newline terminates that fragment; whatever it produces
        // is discarded, because reading an orphan's ERR as the reply to the next
        // command is its own bug.
        Thread.sleep(forTimeInterval: 0.4)
        drain()
        _ = Darwin.write(fd, "\n", 1)
        Thread.sleep(forTimeInterval: 0.2)
        drain()
    }

    deinit { Darwin.close(fd) }

    /// Opens the first device that answers, or throws.
    static func connect() throws -> DeviceConsole {
        let candidates = ports()
        if candidates.isEmpty { throw ConsoleError.noDevice }
        var lastError: Error = ConsoleError.noDevice
        for candidate in candidates {
            do {
                let console = try DeviceConsole(port: candidate)
                // Prove it is ours rather than any CDC device that happens to be
                // plugged in. A modem or a debug probe will not answer PING.
                if try console.ask("PING").contains(where: { $0 == "PONG" }) {
                    return console
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func drain() {
        var scratch = [UInt8](repeating: 0, count: 4096)
        while Darwin.read(fd, &scratch, scratch.count) > 0 {}
        buffer.removeAll()
    }

    /// One line, or nil if the device said nothing before the deadline.
    func readLine(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var scratch = [UInt8](repeating: 0, count: 1024)
        while true {
            if let newline = buffer.firstIndex(of: 0x0a) {
                let raw = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let line = String(decoding: raw, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { return line }
                continue
            }
            if Date() >= deadline { return nil }
            let n = Darwin.read(fd, &scratch, scratch.count)
            if n > 0 {
                buffer.append(contentsOf: scratch[0..<n])
            } else {
                // EAGAIN on a non-blocking descriptor. Sleeping beats spinning,
                // and 10 ms is far below the latency of anything on this link.
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    /// Sends one command and collects lines until the terminator.
    ///
    /// Most commands put OK or ERR last. `FINGERPRINT_INFO_RAW` puts it first and
    /// follows it with the page, so a short drain after the terminator tolerates
    /// both orders rather than encoding which command is which — the same fix
    /// `provision.py` carries, and for the same bug.
    @discardableResult
    func ask(_ command: String, timeout: TimeInterval = 20) throws -> [String] {
        _ = (command + "\n").withCString { Darwin.write(fd, $0, strlen($0)) }
        var lines: [String] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let line = readLine(timeout: deadline.timeIntervalSinceNow) else { break }
            lines.append(line)
            if line.hasPrefix("OK") || line.hasPrefix("ERR") || line == "PONG" {
                while let trailing = readLine(timeout: 0.35) { lines.append(trailing) }
                break
            }
        }
        if lines.isEmpty { throw ConsoleError.noAnswer(command) }
        if let last = lines.last(where: { $0.hasPrefix("OK") || $0.hasPrefix("ERR") }),
           last.hasPrefix("ERR") {
            throw ConsoleError.refused(command, last)
        }
        return lines
    }

    /// Watches for unsolicited lines until `stop` returns true or time runs out.
    ///
    /// The device volunteers `EVENT ...` and `PROMPT ...` on its own — that is
    /// how enrolment reports progress — so anything that wants to narrate what
    /// the device is doing has to hold the port and listen.
    func listen(until deadline: Date, onLine: (String) -> Bool) {
        while Date() < deadline {
            guard let line = readLine(timeout: 0.5) else { continue }
            if onLine(line) { return }
        }
    }
}
