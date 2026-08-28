// The single owner of the serial port.
//
// A serial device admits one reader, and this app has four panes that all want
// to ask the device something. Without somewhere to serialise that, two of them
// racing produce a reply to the wrong question — which on a line protocol looks
// exactly like the device malfunctioning.
//
// So: one queue, one connection at a time, opened per operation. Panes never see
// a DeviceConsole; they hand work to the agent and get a result on the main
// thread.

import Foundation

final class DeviceAgent {
    static let shared = DeviceAgent()

    /// Posted whenever a poll produces a status, or the device goes away.
    static let statusChanged = Notification.Name("io.openhanko.statusChanged")

    private let queue = DispatchQueue(label: "io.openhanko.device")
    private var timer: Timer?

    /// One connection, held for as long as the app runs.
    ///
    /// Opening per operation was the first design and it was worse in both
    /// directions. Bringing a CDC endpoint up costs the best part of a second in
    /// settling delays, so a two-second poll held the port about a third of the
    /// time — which is precisely the contention with provision.py that opening
    /// per operation was meant to avoid, arrived at by a longer route. Holding it
    /// makes a poll one round trip, and makes the answer simple to state: the app
    /// owns the port while its window is open, and closing the window quits the
    /// app and gives it back.
    private var console: DeviceConsole?

    private func connected() throws -> DeviceConsole {
        if let console { return console }
        let opened = try DeviceConsole.connect()
        console = opened
        return opened
    }

    /// Drops the connection so the next operation reopens.
    ///
    /// Any failure discards it rather than trying to diagnose which failures are
    /// recoverable. A device that was unplugged and a device that answered late
    /// present identically here, and reopening costs a second once.
    private func dropConnection() { console = nil }

    private(set) var status: DeviceStatus?
    private(set) var lastError: String?

    private init() {}

    func startPolling() {
        poll()
        // Two seconds is fast enough that plugging the device in while a window
        // is open visibly does something, and slow enough that the port is free
        // almost all the time for anyone using provision.py alongside this.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// Runs `work` with the console, on the agent's queue, and calls back on main.
    ///
    /// Every console operation in the app goes through here, including the ones
    /// that take a long time — a fingerprint enrolment holds the port for up to
    /// half a minute — so nothing else can interleave with them.
    func perform<T>(_ work: @escaping (DeviceConsole) throws -> T,
                    completion: @escaping (Result<T, Error>) -> Void) {
        queue.async {
            let result: Result<T, Error>
            do {
                result = .success(try work(try self.connected()))
            } catch {
                self.dropConnection()
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private var polling = false

    private func poll() {
        // A poll that overlaps a long operation would queue behind it and then
        // fire late in a burst. Skipping is the right answer: the next tick is
        // two seconds away and the status it would have read is already stale.
        queue.async { [weak self] in
            guard let self, !self.polling else { return }
            self.polling = true
            defer { self.polling = false }

            var newStatus: DeviceStatus?
            var newError: String?
            do {
                newStatus = try DeviceStatus.read(try self.connected())
            } catch {
                self.dropConnection()
                newError = (error as? ConsoleError)?.description ?? error.localizedDescription
            }
            DispatchQueue.main.async {
                self.status = newStatus
                self.lastError = newError
                NotificationCenter.default.post(name: DeviceAgent.statusChanged, object: nil)
            }
        }
    }

    /// Holds the port and forwards what the device volunteers.
    ///
    /// Enrolment is the reason this exists. The device narrates it —
    /// ENROLL_OPEN, ENROLL_CAPTURING, ENROLL_OK — and until now nothing was
    /// listening, so adding a finger was a gesture performed blind with only the
    /// ring for feedback. Polling cannot substitute: the interesting lines arrive
    /// unasked and would be lost between polls.
    ///
    /// `stopWhen` is evaluated on the agent's queue and must be pure. `onLine`
    /// runs on the main thread and may touch the interface.
    func listen(seconds: TimeInterval,
                stopWhen: @escaping (String) -> Bool,
                onLine: @escaping (String) -> Void,
                completion: @escaping (Error?) -> Void) {
        queue.async {
            do {
                let console = try self.connected()
                console.listen(until: Date().addingTimeInterval(seconds)) { line in
                    DispatchQueue.main.async { onLine(line) }
                    return stopWhen(line)
                }
                DispatchQueue.main.async { completion(nil) }
            } catch {
                self.dropConnection()
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// Forces a poll now, for use after something that changes device state.
    func refresh() { poll() }
}
