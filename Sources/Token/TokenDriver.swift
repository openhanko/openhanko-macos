// CryptoTokenKit token driver for the smart-card device.
//
// Why this exists rather than relying on Apple's built-in pivtoken:
//
//   1. PIN entry. Apple's pivtoken always collects the PIN itself, in a dialog,
//      and the device then has to type it over HID into whatever window happens
//      to hold focus. A custom driver can hand CryptoTokenKit an APDUTemplate,
//      which per Apple's own header "allows using hardware PINPad for secure PIN
//      entry (provided that the reader has one)" — and our reader has one. Then
//      the button press *is* the PIN entry: no field, no keystrokes, no focus.
//
//   2. Transport. A token driver talks to whatever it likes, which is the only
//      route to a wireless version, since macOS has no Bluetooth smart-card
//      transport of its own.

import CryptoKit
import CryptoTokenKit
import Foundation
import os

let log = Logger(subsystem: "io.openhanko.app.token", category: "token")

/// Diagnostics for an extension you cannot attach a debugger to.
///
/// os_log turned out to be unusable here: Logger.info is memory-only, and even
/// at error level nothing from this subsystem ever reached `log show`. So this
/// also appends to a file inside the sandbox container, which is the one
/// channel that has proven reliable:
///
///     tail -f ~/Library/Containers/io.openhanko.app.token/Data/token.log
func note(_ message: String) {
    // Without .public the interpolation is redacted to <private> in the log.
    log.error("\(message, privacy: .public)")

    let line = "\(Date()) \(message)\n"
    let path = NSHomeDirectory() + "/token.log"
    if let data = line.data(using: .utf8) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - PIV constants

enum PIV {
    /// GET DATA object identifiers, as the 0x5C tag-list the card expects.
    static let certificate9A = Data([0x5c, 0x03, 0x5f, 0xc1, 0x05])
    static let certificate9D = Data([0x5c, 0x03, 0x5f, 0xc1, 0x0b])

    static let slotAuthentication: UInt8 = 0x9a

    /// SP 800-78 algorithm identifiers, carried in P1 of GENERAL AUTHENTICATE.
    static let algorithmRSA2048: UInt8 = 0x07
    static let algorithmECCP256: UInt8 = 0x11

    /// VERIFY against the PIV application PIN. The PIN field is 8 bytes padded
    /// with 0xFF, which is what the APDU template below reserves.
    static let pinBlockLength = 8
}

// MARK: - Minimal BER-TLV

enum TLV {
    /// Returns the value of the first record with `tag` at the top level.
    static func value(of tag: UInt8, in data: Data) -> Data? {
        var index = data.startIndex
        while index < data.endIndex {
            let recordTag = data[index]
            index += 1
            guard index < data.endIndex else { return nil }

            var length = Int(data[index])
            index += 1
            if length & 0x80 != 0 {
                let byteCount = length & 0x7f
                guard byteCount > 0, byteCount <= 3,
                      index + byteCount <= data.endIndex else { return nil }
                length = 0
                for _ in 0..<byteCount {
                    length = (length << 8) | Int(data[index])
                    index += 1
                }
            }
            guard index + length <= data.endIndex else { return nil }

            if recordTag == tag {
                return data.subdata(in: index..<(index + length))
            }
            index += length
        }
        return nil
    }

    /// BER length encoding for `count`.
    static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        if count <= 0xff { return Data([0x81, UInt8(count)]) }
        return Data([0x82, UInt8(count >> 8), UInt8(count & 0xff)])
    }
}

// MARK: - APDU exchange

enum CardError: Error, LocalizedError {
    case status(UInt16)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .status(let sw): return String(format: "card returned %04X", sw)
        case .malformedResponse(let what): return "malformed response: \(what)"
        }
    }
}

extension TKSmartCard {
    /// Sends one APDU and follows 61xx with GET RESPONSE until the card is done.
    ///
    /// The Swift overlay returns (sw, response) rather than taking an inout
    /// status word, and `le` is a plain Int.
    func transmit(ins: UInt8, p1: UInt8, p2: UInt8,
                  data: Data? = nil, le: Int? = nil) throws -> Data {
        var (sw, response) = try self.send(ins: ins, p1: p1, p2: p2, data: data, le: le)

        while (sw & 0xff00) == 0x6100 {
            let remaining = Int(sw & 0x00ff)
            let (nextSW, chunk) = try self.send(ins: 0xc0, p1: 0x00, p2: 0x00, data: nil,
                                                le: remaining == 0 ? 256 : remaining)
            response.append(chunk)
            sw = nextSW
        }

        guard sw == 0x9000 else { throw CardError.status(sw) }
        return response
    }
}

// MARK: - Driver

final class TokenDriver: TKSmartCardTokenDriver, TKSmartCardTokenDriverDelegate {

    func tokenDriver(_ driver: TKSmartCardTokenDriver,
                     createTokenFor smartCard: TKSmartCard,
                     aid AID: Data?) throws -> TKSmartCardToken {
        note("createToken for card, AID \(AID?.hex ?? "none")")

        // CryptoTokenKit has already selected our AID, so the applet is live.
        let wrapper = try smartCard.transmit(ins: 0xcb, p1: 0x3f, p2: 0xff,
                                             data: PIV.certificate9A, le: 0)

        // GET DATA returns 0x53 { 0x70 <certificate DER>, ... }
        guard let container = TLV.value(of: 0x53, in: wrapper),
              let certificateDER = TLV.value(of: 0x70, in: container),
              let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw CardError.malformedResponse("no certificate in slot 9A")
        }

        let objectID = "9a" as NSString
        let certificateItem = TKTokenKeychainCertificate(certificate: certificate,
                                                         objectID: objectID)
        // The certificate's own subject, not a fixed string. Devices name
        // themselves after their key's fingerprint, and hardcoding a label here
        // threw that away the moment this driver took over: the same card that
        // reads "OpenHanko #FA764A" under Apple's pivtoken became an anonymous
        // "smart-card authentication" under ours, and two devices on one Mac
        // became indistinguishable.
        let label = (SecCertificateCopySubjectSummary(certificate) as String?)
            ?? "smart-card authentication"
        certificateItem?.label = label

        guard let keyItem = TKTokenKeychainKey(certificate: certificate, objectID: objectID) else {
            throw CardError.malformedResponse("certificate carries no usable public key")
        }
        keyItem.label = label
        keyItem.canSign = true
        keyItem.canDecrypt = false
        keyItem.canPerformKeyExchange = false
        keyItem.isSuitableForLogin = true
        // Every use of this key costs a button press on the device. Saying so
        // here is what makes macOS ask us to authenticate before each signature
        // rather than caching one authentication forever.
        keyItem.constraints = [NSNumber(value: TKTokenOperation.signData.rawValue): TokenSession.pinConstraint]

        // Slot 9D, the key-management key, published for key agreement.
        //
        // macOS wraps the login keychain unlock key to a PIV key-management key
        // when a card is paired. Publishing only 9A meant it found nothing
        // suitable and said so — "No suitable key was found on the selected
        // SmartCard" — leaving the account password required after every
        // smart-card login just to open the keychain.
        //
        // Absent rather than fatal if the slot is empty: a card with no 9D is
        // still perfectly usable for authentication, just without this.
        var keychainItems: [TKTokenKeychainItem] = []
        if let certificateItem { keychainItems.append(certificateItem) }
        keychainItems.append(keyItem)

        if let managementWrapper = try? smartCard.transmit(ins: 0xcb, p1: 0x3f, p2: 0xff,
                                                           data: PIV.certificate9D, le: 0),
           let managementContainer = TLV.value(of: 0x53, in: managementWrapper),
           let managementDER = TLV.value(of: 0x70, in: managementContainer),
           let managementCertificate = SecCertificateCreateWithData(nil, managementDER as CFData) {

            let managementID = "9d" as NSString
            let managementLabel = (SecCertificateCopySubjectSummary(managementCertificate) as String?)
                ?? label

            if let item = TKTokenKeychainCertificate(certificate: managementCertificate,
                                                     objectID: managementID) {
                item.label = managementLabel
                keychainItems.append(item)
            }
            if let managementKey = TKTokenKeychainKey(certificate: managementCertificate,
                                                      objectID: managementID) {
                managementKey.label = managementLabel
                managementKey.canSign = false
                managementKey.canDecrypt = false
                managementKey.canPerformKeyExchange = true
                managementKey.isSuitableForLogin = false
                // Unconstrained on purpose. This key is used while macOS opens
                // the login keychain immediately after a login the user already
                // authorised with a press; asking again there reads as broken.
                keychainItems.append(managementKey)
                note("publishing slot 9D for key agreement")
            }
        } else {
            note("no slot 9D certificate; login keychain unlock will not be available")
        }

        // The instance ID must be stable for the same physical card, or macOS
        // treats it as a new token on every insertion and pairings evaporate.
        // The suffix is deliberate. ctkd persists a token's keychain contents
        // per instance ID, including each key's operation constraints, and
        // Apple's header requires constraints to stay constant for the token's
        // lifetime. Changing the ID is how you get those contents rebuilt after
        // altering constraints; without it the old ones silently win.
        let instanceID = certificateDER.sha256Hex + ".v4"

        note("publishing key: canSign=\(keyItem.canSign) login=\(keyItem.isSuitableForLogin) constraints=\(keyItem.constraints ?? [:])")

        let token = Token(smartCard: smartCard, aid: AID,
                          instanceID: instanceID, tokenDriver: driver)
        // OpenSCToken does this inside the token's own initialiser. Doing it
        // here works too, but note whether the container even exists — if
        // keychainContents is nil the fill silently does nothing.
        note("keychainContents present: \(token.keychainContents != nil), \(keychainItems.count) item(s)")
        token.keychainContents?.fill(with: keychainItems)
        note("token created, instance \(instanceID)")
        return token
    }
}

// MARK: - Token

final class Token: TKSmartCardToken, TKTokenDelegate {
    func createSession(_ token: TKToken) throws -> TKTokenSession {
        note("createSession")
        return TokenSession(token: self)
    }
}

// MARK: - Session

final class TokenSession: TKSmartCardTokenSession, TKTokenSessionDelegate {

    /// Names the authentication this session can perform. The value is opaque
    /// to macOS; it only has to match between the key's constraints and
    /// beginAuth below.
    static let pinConstraint = "pin" as NSString

    /// PIN presentation rules. The device ignores the digits entirely — the
    /// button press is the real authorization — but the format still has to be
    /// declared so the reader and the host agree on the block layout.
    private func pinFormat() -> TKSmartCardPINFormat {
        let format = TKSmartCardPINFormat()
        format.charset = .numeric
        format.encoding = .ascii
        format.minPINLength = 6
        format.maxPINLength = 8
        format.pinBlockByteLength = PIV.pinBlockLength
        format.pinJustification = .left
        return format
    }

    /// VERIFY against the application PIN: 00 20 00 80 08 FF*8.
    /// The PIN is written over the padding at offset 5.
    private func verifyTemplate() -> Data {
        var template = Data([0x00, 0x20, 0x00, 0x80, UInt8(PIV.pinBlockLength)])
        template.append(Data(repeating: 0xff, count: PIV.pinBlockLength))
        return template
    }

    func tokenSession(_ session: TKTokenSession,
                      beginAuthFor operation: TKTokenOperation,
                      constraint: Any) throws -> TKTokenAuthOperation {
        let card = try smartCardForSession()
        let format = pinFormat()
        let template = verifyTemplate()

        // Breadcrumb visible in the device trace: SELECT a nonsense AID, which
        // the card refuses with 6A82. os_log from this extension does not reach
        // `log show`, so this is the only reliable evidence that beginAuth ran.
        _ = try? card.transmit(ins: 0xa4, p1: 0x04, p2: 0x00,
                               data: Data([0xf0, 0x44, 0x42, 0x47]))
        note("beginAuth for operation \(operation.rawValue)")

        // Drive the reader's PIN entry explicitly.
        //
        // The system-managed alternative — handing back a
        // TKTokenSmartCardPINAuthOperation with APDUTemplate set — is what
        // Apple's header recommends, and it does not work: measured, macOS
        // ignores the template, collects the PIN itself and passes it in
        // `PIN`, and never sends PC_to_RDR_Secure. Driving the interaction
        // ourselves is the only way the reader is actually asked.
        //
        // This does not remove the PIN prompt: macOS collects a PIN from the
        // user regardless, in PAM for sudo and in SecurityAgent for GUI
        // authorization. What it buys is that the typed digits no longer
        // authenticate anything — the card only verifies on a physical press.
        if card.userInteractionForSecurePINVerification(format, apdu: template,
                                                        pinByteOffset: 5) != nil {
            note("reader supports secure PIN entry; deferring to the pinpad")
            let auth = PinpadAuthOperation()
            auth.session = self
            return auth
        }

        note("reader has no pinpad; falling back to host PIN entry")
        let auth = PINAuthOperation()
        auth.pinFormat = format
        auth.apduTemplate = nil
        auth.session = self
        return auth
    }

    /// Runs secure PIN verification on the reader. Blocking is fine here:
    /// beginAuth builds the context, finish() performs it.
    fileprivate func performSecurePINVerification() throws {
        let card = try smartCardForSession()
        guard let interaction = card.userInteractionForSecurePINVerification(
            pinFormat(), apdu: verifyTemplate(), pinByteOffset: 5) else {
            throw TKError(.authenticationFailed)
        }
        interaction.initialTimeout = 30
        interaction.interactionTimeout = 30

        var succeeded = false
        var failure: Error?
        let finished = DispatchSemaphore(value: 0)
        interaction.run { success, error in
            succeeded = success
            failure = error
            finished.signal()
        }
        finished.wait()

        note("secure PIN verification: success=\(succeeded) sw=\(String(format: "%04x", interaction.resultSW))")
        if let failure {
            note("secure PIN verification error: \(failure.localizedDescription)")
        }
        guard succeeded, interaction.resultSW == 0x9000 else {
            throw TKError(.authenticationFailed)
        }
    }

    /// Sends VERIFY with a PIN the host collected.
    fileprivate func verify(pin: String) throws {
        let card = try smartCardForSession()
        var block = Data(pin.utf8)
        guard block.count <= PIV.pinBlockLength else { throw TKError(.objectNotFound) }
        block.append(Data(repeating: 0xff, count: PIV.pinBlockLength - block.count))

        _ = try card.transmit(ins: 0x20, p1: 0x00, p2: 0x80, data: block)
        note("host-side VERIFY accepted")
    }

    func tokenSession(_ session: TKTokenSession,
                      supports operation: TKTokenOperation,
                      keyObjectID: Any,
                      algorithm: TKTokenKeyAlgorithm) -> Bool {
        note("supportsOperation \(operation.rawValue) key=\(keyObjectID)")

        // Slot 9D does key agreement and nothing else; slot 9A signs and
        // nothing else. Saying otherwise gets the wrong key handed the wrong
        // operation and a 6a86 from the card.
        if operation == .performKeyExchange {
            guard "\(keyObjectID)" == "9d" else { return false }
            // Standard and cofactor are the same operation on P-256, whose
            // cofactor is 1. CryptoTokenKit derives the X9.63 KDF variants from
            // the raw secret itself, so answering for these two is enough.
            let ok = algorithm.isAlgorithm(.ecdhKeyExchangeStandard)
                || algorithm.isAlgorithm(.ecdhKeyExchangeCofactor)
            note("  key exchange algorithm supported=\(ok)")
            return ok
        }

        guard operation == .signData, "\(keyObjectID)" == "9a" else { return false }
        // The card signs a digest; macOS asks for the X9.62 variants for EC and
        // PKCS#1 for RSA. Anything else it can derive from these.
        return algorithm.isAlgorithm(.ecdsaSignatureDigestX962SHA256)
            || algorithm.isAlgorithm(.rsaSignatureDigestPKCS1v15SHA256)
    }

    /// ECDH against slot 9D. macOS hands us the other party's public point and
    /// expects the shared secret back, which it uses to wrap the login keychain
    /// unlock key so a smart-card login does not also demand the password.
    func tokenSession(_ session: TKTokenSession,
                      performKeyExchange otherPartyKeyData: Data,
                      keyObjectID objectID: Any,
                      algorithm: TKTokenKeyAlgorithm,
                      parameters: TKTokenKeyExchangeParameters) throws -> Data {
        let card = try smartCardForSession()
        note("key exchange with \(objectID), peer point \(otherPartyKeyData.count) bytes")

        // 7C { 82 00, 85 <peer public point> } — tag 0x85 is what distinguishes
        // key agreement from the signing use of the same command.
        var dynamic = Data([0x82, 0x00, 0x85])
        dynamic.append(TLV.length(otherPartyKeyData.count))
        dynamic.append(otherPartyKeyData)

        var body = Data([0x7c])
        body.append(TLV.length(dynamic.count))
        body.append(dynamic)

        let response = try card.transmit(ins: 0x87, p1: PIV.algorithmECCP256,
                                         p2: 0x9d, data: body, le: 0)

        guard let dynamicResponse = TLV.value(of: 0x7c, in: response),
              let secret = TLV.value(of: 0x82, in: dynamicResponse) else {
            throw CardError.malformedResponse("no shared secret in the key agreement response")
        }
        note("key exchange produced \(secret.count) bytes")
        return secret
    }

    func tokenSession(_ session: TKTokenSession,
                      sign dataToSign: Data,
                      keyObjectID: Any,
                      algorithm: TKTokenKeyAlgorithm) throws -> Data {
        let card = try smartCardForSession()
        let isEC = algorithm.isAlgorithm(.ecdsaSignatureDigestX962SHA256)
        let pivAlgorithm = isEC ? PIV.algorithmECCP256 : PIV.algorithmRSA2048

        // GENERAL AUTHENTICATE: 7C { 82 00 (response placeholder), 81 <challenge> }
        var dynamic = Data([0x82, 0x00, 0x81])
        dynamic.append(TLV.length(dataToSign.count))
        dynamic.append(dataToSign)

        var body = Data([0x7c])
        body.append(TLV.length(dynamic.count))
        body.append(dynamic)

        note("sign \(dataToSign.count) bytes with PIV algorithm \(String(format: "%02x", pivAlgorithm))")

        let response: Data
        do {
            response = try card.transmit(ins: 0x87, p1: pivAlgorithm,
                                         p2: PIV.slotAuthentication, data: body, le: 0)
        } catch CardError.status(0x6982) {
            // "Security status not satisfied" — the card wants its PIN first.
            //
            // Declaring a constraint on the key only tells CryptoTokenKit that
            // authentication is *possible*. It calls sign first regardless, and
            // only calls beginAuth once the operation reports that auth is
            // actually *needed* — with this specific error and no other. Return
            // anything else, as we did for a long while, and it simply gives up
            // without ever asking, which looks exactly like the constraint
            // being ignored.
            note("card requires authentication; asking CryptoTokenKit for it")
            throw TKError(.authenticationNeeded)
        } catch CardError.status(0x6983) {
            // "Authentication method blocked" — the device found a different
            // fingerprint module than the one it was set up with, and has shut
            // itself down. Nothing a host can do reopens it.
            note("card reports its fingerprint sensor has been changed")
            throw NSError(domain: TKErrorDomain, code: TKError.Code.canceledByUser.rawValue,
                          userInfo: [
                NSLocalizedDescriptionKey:
                    "This OpenHanko's fingerprint sensor is not the one it was set "
                    + "up with, so it has stopped accepting anything. If the sensor "
                    + "was not replaced deliberately, treat the device as tampered "
                    + "with. Holding its button while plugging it in erases the key "
                    + "and starts over.",
            ])
        } catch CardError.status(0x6985) {
            // "Conditions of use not satisfied" — the device has a fingerprint
            // sensor and nothing enrolled on it, so it cannot authorise anything
            // for anybody yet.
            //
            // Deliberately *not* authenticationNeeded. That would send
            // CryptoTokenKit into beginAuth and a secure-PIN request the device
            // can never satisfy, which is how this used to end: either a retry
            // storm, or a pairing dialog sitting with its buttons disabled while
            // the card politely asked for more time. There is nothing to wait
            // for, so say so and stop.
            note("card reports no fingerprint enrolled; refusing without a PIN request")
            // Everything goes in the description. macOS renders that key inline in
            // its own sentence and discards the recovery suggestion entirely, so a
            // next step left there is a next step nobody reads.
            //
            // The reconnect matters and is not guessable: macOS only offers to pair
            // when a card is inserted, so enrolling while it sits in the port
            // leaves the user with no way back to this dialog short of sc_auth.
            throw NSError(domain: TKErrorDomain, code: TKError.Code.canceledByUser.rawValue,
                          userInfo: [
                NSLocalizedDescriptionKey:
                    "No fingerprint is enrolled on this OpenHanko. The ring breathes "
                    + "purple while it waits for one — touch the sensor twice with the "
                    + "same finger, then unplug the device and plug it back in to pair.",
            ])
        }

        guard let dynamicResponse = TLV.value(of: 0x7c, in: response),
              let signature = TLV.value(of: 0x82, in: dynamicResponse) else {
            throw CardError.malformedResponse("no signature in GENERAL AUTHENTICATE response")
        }
        note("signature \(signature.count) bytes")
        return signature
    }

    /// getSmartCardWithError: replaced the deprecated `smartCard` property in
    /// macOS 26; keep working on older systems too.
    private func smartCardForSession() throws -> TKSmartCard {
        if #available(macOS 26.0, *) {
            return try getSmartCard()
        }
        return smartCard
    }
}

// MARK: - Auth operations

/// Authentication performed by the reader itself. finish() is where the
/// blocking work belongs.
final class PinpadAuthOperation: TKTokenAuthOperation {
    weak var session: TokenSession?

    override func finish() throws {
        guard let session else { throw TKError(.authenticationFailed) }
        try session.performSecurePINVerification()
    }
}

// MARK: - Fallback PIN operation

/// Used only when the reader has no pinpad: performs the VERIFY itself once the
/// system has collected a PIN, because with APDUTemplate nil CryptoTokenKit
/// leaves authentication to the token.
final class PINAuthOperation: TKTokenSmartCardPINAuthOperation {
    weak var session: TokenSession?

    override func finish() throws {
        // With APDUTemplate set, the system has already sent the VERIFY to the
        // card and deliberately leaves PIN nil. Nothing left to do here.
        guard let pin, !pin.isEmpty else {
            note("finish: system handled the VERIFY itself")
            return
        }
        guard let session else { throw TKError(.authenticationFailed) }
        try session.verify(pin: pin)
    }
}

// MARK: - Small helpers

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
