// CryptoTokenKit driver for the device over BLE.
//
// Unlike the wired driver this is a *persistent* token: there is no reader and
// no card insertion, so nothing discovers the device on its own. The container
// app registers it (see Sources/BLEApp), and CryptoTokenKit then instantiates
// this driver whenever something wants to use the key.
//
// The wired driver had to fight the PIN dialog, which is what forced the
// constraint/beginAuth dance and the TKErrorCodeAuthenticationNeeded discovery.
// None of that applies here: with no CCID there is no PIN prompt to suppress,
// so `sign` simply blocks until the user presses the button. The device's LED
// breathes for as long as it is refusing, which is the prompt.

import CryptoTokenKit
import Foundation
import os

private let log = Logger(subsystem: "dev.smartcard.bleapp.token", category: "driver")

/// Errors are the only level that reaches `log show` without a live stream —
/// info and debug stay in the memory-backed ring and vanish. Everything this
/// driver reports is therefore logged at error level regardless of severity,
/// because a driver you cannot observe is a driver you cannot fix.
func note(_ message: String) {
    log.error("\(message, privacy: .public)")
}

enum TokenError: Error {
    case message(String)
}

// MARK: - Driver

final class TokenDriver: TKTokenDriver, TKTokenDriverDelegate {
    func tokenDriver(_ driver: TKTokenDriver,
                     tokenFor configuration: TKToken.Configuration) throws -> TKToken {
        note("creating token for instance \(configuration.instanceID), \(configuration.keychainItems.count) keychain item(s)")

        let token = Token(tokenDriver: driver, instanceID: configuration.instanceID)
        token.keychainContents?.fill(with: configuration.keychainItems)
        token.delegate = token

        // The app stored which device this token belongs to in the instance ID.
        token.deviceIdentifier = UUID(uuidString: configuration.instanceID)
        return token
    }
}

// MARK: - Token

final class Token: TKToken, TKTokenDelegate {
    var deviceIdentifier: UUID?

    func createSession(_ token: TKToken) throws -> TKTokenSession {
        return TokenSession(token: self)
    }
}

// MARK: - Session

final class TokenSession: TKTokenSession, TKTokenSessionDelegate {
    // These two are a safety property, not a tuning knob.
    //
    // Once a key is marked suitable for login, this driver sits inside an
    // authentication path, and anything slow there is dangerous: an
    // authorization plugin that took ~20 s per attempt once locked this machine
    // out of its own login window until a reboot. A driver that cannot reach
    // the device must fail quickly and let the password prompt through, so
    // both budgets are deliberately short. Their sum bounds the worst case.
    private let presenceTimeout: TimeInterval = 8
    private let connectTimeout: TimeInterval = 4

    /// TKTokenSession already declares `token`; this is the same object,
    /// narrowed to our subclass so the device identifier is reachable.
    private var bleToken: Token? { token as? Token }

    override init(token: TKToken) {
        super.init(token: token)
        self.delegate = self
    }

    func tokenSession(_ session: TKTokenSession,
                      supports operation: TKTokenOperation,
                      keyObjectID: Any,
                      algorithm: TKTokenKeyAlgorithm) -> Bool {
        guard operation == .signData else { return false }
        return algorithm.isAlgorithm(.ecdsaSignatureDigestX962SHA256)
            || algorithm.isAlgorithm(.rsaSignatureDigestPKCS1v15SHA256)
    }

    func tokenSession(_ session: TKTokenSession,
                      sign dataToSign: Data,
                      keyObjectID: Any,
                      algorithm: TKTokenKeyAlgorithm) throws -> Data {
        let isEC = algorithm.isAlgorithm(.ecdsaSignatureDigestX962SHA256)
        note("sign \(dataToSign.count) bytes, \(isEC ? "ECDSA" : "RSA")")

        let card = BLECard()
        do {
            try card.connect(preferring: bleToken?.deviceIdentifier, timeout: connectTimeout)
        } catch {
            note("connect failed: \(error)")
            throw TKError(.tokenNotFound)
        }
        defer { card.disconnect() }

        try card.selectPIV()

        // 7C L { 82 00, 81 L <digest> }
        var dynamic = Data([0x82, 0x00, 0x81, UInt8(dataToSign.count)])
        dynamic.append(dataToSign)
        var body = Data([0x7c, UInt8(dynamic.count)])
        body.append(dynamic)

        var apdu = Data([0x00, 0x87, isEC ? 0x11 : 0x07, 0x9a, UInt8(body.count)])
        apdu.append(body)
        apdu.append(0x00)

        // The applet answers 6982 until a button press opens the presence
        // window, and a refusal also clears the PIN-verified window on its way
        // out — so VERIFY has to be re-sent before every attempt, not once.
        let deadline = Date().addingTimeInterval(presenceTimeout)
        var reply = Data()
        var status: UInt16 = 0
        var attempts = 0

        repeat {
            try verify(card)
            reply = try card.transmit(apdu, timeout: 30)
            guard reply.count >= 2 else { throw TKError(.corruptedData) }
            status = UInt16(reply[reply.count - 2]) << 8 | UInt16(reply[reply.count - 1])
            attempts += 1
            if status == 0x6982 { Thread.sleep(forTimeInterval: 0.4) }
        } while status == 0x6982 && Date() < deadline

        guard status == 0x9000 else {
            note("refused after \(attempts) attempt(s), sw=\(String(format: "%04x", status))")
            throw TKError(.authenticationFailed)
        }
        reply.removeLast(2)

        guard let dynamicResponse = TLV.first(0x7c, in: reply),
              let signature = TLV.first(0x82, in: dynamicResponse) else {
            throw TKError(.corruptedData)
        }
        note("signed after \(attempts) attempt(s): \(signature.count) bytes")
        return signature
    }

    /// The PIN is theatre — the applet accepts any value — but it still gates
    /// signing exactly as a real PIV card does.
    private func verify(_ card: BLECard) throws {
        var block = Data("000000".utf8)
        block.append(Data(repeating: 0xff, count: 8 - block.count))
        var apdu = Data([0x00, 0x20, 0x00, 0x80, UInt8(block.count)])
        apdu.append(block)
        _ = try card.transmit(apdu)
    }
}
