// The device as a smart card, reached over BLE instead of a reader.
//
// macOS has exactly one smart-card transport and it is USB, so nothing in the
// system will ever find this device on its own. Everything above this file
// therefore talks to `BLECard` where it would otherwise have talked to
// `TKSmartCard`, and the APDUs are identical either way — the firmware answers
// both from the same piv_handle_apdu().
//
// The public API is deliberately synchronous. Its callers are a token driver
// and an XPC handler, both of which are already running on threads that are
// allowed to block, and neither of which wants to model a connection state
// machine. CoreBluetooth's own callbacks run on `queue`; no public method may
// ever be called from there or it will deadlock against itself.

import CoreBluetooth
import Foundation

enum BLECardError: Error, CustomStringConvertible {
    case bluetoothUnavailable(CBManagerState)
    case notFound
    case timeout(String)
    case disconnected
    case malformed(String)

    var description: String {
        switch self {
        case .bluetoothUnavailable(let state): return "bluetooth unavailable (state \(state.rawValue))"
        case .notFound:                        return "no smart-card device found"
        case .timeout(let what):               return "timed out \(what)"
        case .disconnected:                    return "device disconnected"
        case .malformed(let why):              return "malformed response: \(why)"
        }
    }
}

final class BLECard: NSObject {
    static let serviceUUID  = CBUUID(string: "6B1A0001-8F2C-4A55-9D3E-2C7A5B8E0F10")
    static let apduUUID     = CBUUID(string: "6B1A0002-8F2C-4A55-9D3E-2C7A5B8E0F10")
    static let responseUUID = CBUUID(string: "6B1A0003-8F2C-4A55-9D3E-2C7A5B8E0F10")

    /// The PIV application, which this firmware answers alongside its private
    /// AID. This is the versioned form, `…10 00 01 00`; the applet also accepts
    /// the 9-byte base AID, and nothing in between.
    static let pivAID = Data([0xa0, 0x00, 0x00, 0x03, 0x08, 0x00, 0x00, 0x10, 0x00, 0x01, 0x00])

    private let queue = DispatchQueue(label: "dev.smartcard.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var apduCharacteristic: CBCharacteristic?

    /// Set once the link is usable; cleared on disconnect. Guarded by `lock`.
    private let lock = NSLock()
    private var ready = false
    private var connectResult: Result<Void, Error>?
    private let connectSignal = DispatchSemaphore(value: 0)

    /// Reassembly state for the framed response. Only touched on `queue`.
    private var expected = 0
    private var inbound = Data()

    /// Delivery of a completed response to whoever is blocked in `exchange`.
    ///
    /// A condition variable rather than a semaphore: a semaphore accumulates
    /// counts, so a notification arriving with no waiter — a duplicate, or a
    /// reply to a request that already timed out — leaves a stale signal that
    /// the *next* exchange consumes immediately, reporting a disconnect that
    /// never happened. Here the state is the response itself, and a stale
    /// arrival is simply overwritten when the next exchange begins.
    private let responseLock = NSCondition()
    private var response: Result<Data, Error>?

    /// Stable across reboots of this Mac, so it can identify the token.
    private(set) var deviceIdentifier: UUID?
    private(set) var deviceName: String?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    // MARK: - Connection

    /// Connects, discovers, and subscribes. Returns once APDUs can flow.
    ///
    /// `preferring` is the identifier of a device seen before. CoreBluetooth
    /// will not hand out a peripheral by identifier unless it is already
    /// connected system-wide, so this is a preference during the scan rather
    /// than a lookup, and an unknown identifier just falls back to "any device
    /// advertising our service".
    func connect(preferring known: UUID? = nil, timeout: TimeInterval = 15) throws {
        if isConnected { return }

        lock.lock()
        connectResult = nil
        preferredIdentifier = known
        lock.unlock()

        queue.async { self.beginScanIfPossible() }

        if connectSignal.wait(timeout: .now() + timeout) == .timedOut {
            queue.async { self.central.stopScan() }
            throw BLECardError.timeout("connecting")
        }
        lock.lock(); let result = connectResult; lock.unlock()
        if case .failure(let error) = result { throw error }
    }

    func disconnect() {
        queue.async {
            if let peripheral = self.peripheral { self.central.cancelPeripheralConnection(peripheral) }
        }
    }

    private var preferredIdentifier: UUID?

    private func beginScanIfPossible() {
        guard central.state == .poweredOn else { return }  // retried from didUpdateState

        // A peripheral another process already holds open can be adopted
        // directly, which skips the scan entirely.
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
        if let existing = connected.first(where: { preferredIdentifier == nil || $0.identifier == preferredIdentifier }) {
            attach(existing)
            return
        }
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    private func attach(_ peripheral: CBPeripheral) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        deviceIdentifier = peripheral.identifier
        deviceName = peripheral.name
        central.connect(peripheral, options: nil)
    }

    private func finishConnect(_ result: Result<Void, Error>) {
        lock.lock()
        guard connectResult == nil else { lock.unlock(); return }  // only the first wins
        connectResult = result
        if case .success = result { ready = true }
        lock.unlock()
        connectSignal.signal()
    }

    // MARK: - APDU exchange

    /// Sends one APDU and returns the reply, following 61xx chaining so the
    /// caller sees a single logical response.
    func transmit(_ apdu: Data, timeout: TimeInterval = 30) throws -> Data {
        var accumulated = Data()
        var next = apdu

        while true {
            var reply = try exchange(next, timeout: timeout)
            guard reply.count >= 2 else { throw BLECardError.malformed("short reply") }

            let sw2 = reply.removeLast()
            let sw1 = reply.removeLast()
            accumulated.append(reply)

            // 61xx: "sw2 more bytes are waiting", answered with GET RESPONSE.
            guard sw1 == 0x61 else {
                accumulated.append(sw1)
                accumulated.append(sw2)
                return accumulated
            }
            next = Data([0x00, 0xc0, 0x00, 0x00, sw2])
        }
    }

    /// One framed write and its reply, with no chaining.
    private func exchange(_ apdu: Data, timeout: TimeInterval) throws -> Data {
        guard isConnected, let peripheral, let characteristic = apduCharacteristic else {
            throw BLECardError.disconnected
        }

        // [uint16 total length big-endian][payload], split at the negotiated
        // MTU. Matches firmware/simple/main/ble_transport.c.
        var framed = Data([UInt8(truncatingIfNeeded: apdu.count >> 8),
                           UInt8(truncatingIfNeeded: apdu.count)])
        framed.append(apdu)

        // Claim the slot before writing, so a reply cannot land before we are
        // ready to be woken by it.
        responseLock.lock()
        response = nil
        responseLock.unlock()

        queue.async {
            self.expected = 0
            self.inbound = Data()

            let chunk = max(20, peripheral.maximumWriteValueLength(for: .withResponse))
            var offset = 0
            while offset < framed.count {
                let end = min(offset + chunk, framed.count)
                peripheral.writeValue(framed.subdata(in: offset..<end),
                                      for: characteristic, type: .withResponse)
                offset = end
            }
        }

        responseLock.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while response == nil {
            if !responseLock.wait(until: deadline) {
                responseLock.unlock()
                throw BLECardError.timeout("awaiting a response")
            }
        }
        let received = response!
        response = nil
        responseLock.unlock()
        return try received.get()
    }

    // MARK: - PIV convenience

    /// SELECTs the PIV application. Every session starts here.
    @discardableResult
    func selectPIV() throws -> Data {
        var apdu = Data([0x00, 0xa4, 0x04, 0x00, UInt8(Self.pivAID.count)])
        apdu.append(Self.pivAID)
        return try transmit(apdu)
    }

    /// Reads a data object by its 3-byte PIV tag, returning the payload with
    /// the 0x53 wrapper stripped.
    func readObject(tag: [UInt8]) throws -> Data {
        var apdu = Data([0x00, 0xcb, 0x3f, 0xff, UInt8(tag.count + 2), 0x5c, UInt8(tag.count)])
        apdu.append(contentsOf: tag)
        apdu.append(0x00)

        var reply = try transmit(apdu)
        guard reply.count >= 2 else { throw BLECardError.malformed("short object") }
        let status = UInt16(reply[reply.count - 2]) << 8 | UInt16(reply[reply.count - 1])
        guard status == 0x9000 else { throw BLECardError.malformed(String(format: "status %04x", status)) }
        reply.removeLast(2)

        guard let outer = TLV.first(0x53, in: reply) else { throw BLECardError.malformed("no 0x53") }
        return outer
    }

    /// The DER certificate from a slot, unwrapped from its PIV container.
    func readCertificate(slot: UInt8) throws -> Data {
        let tag: [UInt8] = slot == 0x9d ? [0x5f, 0xc1, 0x0b] : [0x5f, 0xc1, 0x05]
        let object = try readObject(tag: tag)
        guard let certificate = TLV.first(0x70, in: object) else {
            throw BLECardError.malformed("no 0x70 in the certificate object")
        }
        return certificate
    }
}

// MARK: - CoreBluetooth delegates

extension BLECard: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            beginScanIfPossible()
        case .unknown, .resetting:
            break  // transient; a further update is coming
        default:
            finishConnect(.failure(BLECardError.bluetoothUnavailable(central.state)))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Prefer the remembered device, but take any if it does not show up —
        // the scan only ever sees devices advertising our private service.
        if let preferred = preferredIdentifier, peripheral.identifier != preferred { return }
        attach(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        finishConnect(.failure(error ?? BLECardError.notFound))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        lock.lock()
        ready = false
        connectResult = nil
        lock.unlock()

        self.peripheral = nil
        apduCharacteristic = nil

        // Release anyone blocked in exchange() rather than let them wait out
        // the full timeout.
        responseLock.lock()
        response = .failure(BLECardError.disconnected)
        responseLock.signal()
        responseLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            finishConnect(.failure(error ?? BLECardError.notFound))
            return
        }
        peripheral.discoverCharacteristics([Self.apduUUID, Self.responseUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.apduUUID:     apduCharacteristic = characteristic
            case Self.responseUUID: peripheral.setNotifyValue(true, for: characteristic)
            default:                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.responseUUID else { return }
        if let error { finishConnect(.failure(error)); return }
        // Notifications are the last thing to come up, so this is the point at
        // which a round trip will actually work.
        if characteristic.isNotifying, apduCharacteristic != nil { finishConnect(.success(())) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.responseUUID, let value = characteristic.value else { return }
        var payload = value

        if expected == 0 {
            guard payload.count >= 2 else { return }
            expected = Int(payload[payload.startIndex]) << 8 | Int(payload[payload.startIndex + 1])
            payload = payload.dropFirst(2)
            inbound = Data()
        }
        inbound.append(payload)
        guard inbound.count >= expected else { return }

        let complete = Data(inbound.prefix(expected))
        expected = 0
        inbound = Data()

        responseLock.lock()
        response = .success(complete)
        responseLock.signal()
        responseLock.unlock()
    }
}

/// Just enough BER-TLV to walk PIV containers.
enum TLV {
    /// Returns the value of the first record with `tag` at the top level.
    static func first(_ tag: UInt8, in data: Data) -> Data? {
        var index = data.startIndex
        while index < data.endIndex {
            let recordTag = data[index]
            index += 1
            guard index < data.endIndex else { return nil }

            var length = Int(data[index])
            index += 1
            if length & 0x80 != 0 {
                let byteCount = length & 0x7f
                guard byteCount > 0, byteCount <= 3, index + byteCount <= data.endIndex else { return nil }
                length = 0
                for _ in 0..<byteCount {
                    length = length << 8 | Int(data[index])
                    index += 1
                }
            }
            guard index + length <= data.endIndex else { return nil }
            if recordTag == tag { return data.subdata(in: index..<(index + length)) }
            index += length
        }
        return nil
    }
}
