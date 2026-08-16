// Exercises the whole PIV authentication over BLE, with no CryptoTokenKit
// anywhere in the picture.
//
// The point is attribution. When the token driver later misbehaves over the
// air, this says whether the radio, the framing, or the applet is at fault —
// run it, and if it still produces a verified signature the fault is above the
// transport.
//
//     blepiv            connect, read the certificate, sign, verify
//     blepiv info       connect and read the certificate only, no button needed

import CoreBluetooth
import CryptoKit
import Foundation
import Security

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let infoOnly = CommandLine.arguments.dropFirst().contains("info")
let card = BLECard()

// ---------------------------------------------------------------------------
print("connecting…")
do {
    try card.connect()
} catch {
    fail("\(error)")
}
print("connected to \(card.deviceName ?? "device")  \(card.deviceIdentifier?.uuidString ?? "")")

// ---------------------------------------------------------------------------
do {
    let selected = try card.selectPIV()
    guard selected.count >= 2, selected.suffix(2) == Data([0x90, 0x00]) else {
        fail("SELECT failed: \(hex(selected.suffix(2)))")
    }
    print("SELECT PIV: ok")
} catch {
    fail("SELECT: \(error)")
}

// ---------------------------------------------------------------------------
let certificateData: Data
do {
    certificateData = try card.readCertificate(slot: 0x9a)
} catch {
    fail("reading the slot 9A certificate: \(error)")
}

guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
    fail("slot 9A holds \(certificateData.count) bytes that are not a DER certificate")
}
let subject = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "unnamed"
guard let publicKey = SecCertificateCopyKey(certificate) else { fail("no public key in the certificate") }

let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any] ?? [:]
let keyType = attributes[kSecAttrKeyType as String] as? String ?? "?"
let keyBits = attributes[kSecAttrKeySizeInBits as String] as? Int ?? 0
let isEC = keyType == (kSecAttrKeyTypeECSECPrimeRandom as String)

print("certificate: \(certificateData.count) bytes, subject \"\(subject)\"")
print("public key:  \(isEC ? "EC P-\(keyBits)" : "RSA-\(keyBits)")")

if infoOnly {
    print("\ntransport verified (read-only)")
    card.disconnect()
    exit(0)
}

// ---------------------------------------------------------------------------
// The PIN is theatre — the applet accepts any value and the button is the real
// check — but the applet still requires VERIFY before it will sign, exactly as
// a real PIV card does.
//
// It has to be re-sent before *every* signing attempt, not once per session: a
// refused GENERAL AUTHENTICATE clears the verified window on its way out, so a
// caller that verifies once and then retries is refused ever after for the
// wrong reason. CryptoTokenKit gets this right by accident on the wired path,
// because it re-verifies each time it is told authentication is needed.
func verify() throws {
    var pin = Data("000000".utf8)
    while pin.count < 8 { pin.append(0xff) }
    var apdu = Data([0x00, 0x20, 0x00, 0x80, UInt8(pin.count)])
    apdu.append(pin)

    let reply = try card.transmit(apdu)
    guard reply.suffix(2) == Data([0x90, 0x00]) else {
        fail("VERIFY failed: \(hex(reply.suffix(2)))")
    }
}

do {
    try verify()
    print("VERIFY: ok")
} catch {
    fail("VERIFY: \(error)")
}

// ---------------------------------------------------------------------------
let message = Data("hello from the other side".utf8)
let digest = Data(SHA256.hash(data: message))

print("\n>>> press the button on the device <<<\n")

let signature: Data
do {
    // 7C L { 82 00 (empty: "give me a response") 81 L <digest> }
    var dynamic = Data([0x82, 0x00, 0x81, UInt8(digest.count)])
    dynamic.append(digest)

    var body = Data([0x7c, UInt8(dynamic.count)])
    body.append(dynamic)

    let algorithm: UInt8 = isEC ? 0x11 : 0x07
    var apdu = Data([0x00, 0x87, algorithm, 0x9a, UInt8(body.count)])
    apdu.append(body)
    apdu.append(0x00)

    // The applet answers 6982 until a press opens the presence window, so poll
    // rather than demand that the press already have happened. A real driver
    // has to do the same: nothing tells the host when the user is ready.
    let deadline = Date().addingTimeInterval(25)
    var reply = Data()
    var status: UInt16 = 0
    var attempts = 0
    repeat {
        try verify()  // see above: the previous refusal invalidated it
        reply = try card.transmit(apdu, timeout: 30)
        guard reply.count >= 2 else { fail("short GENERAL AUTHENTICATE reply") }
        status = UInt16(reply[reply.count - 2]) << 8 | UInt16(reply[reply.count - 1])
        attempts += 1
        if status == 0x6982 { usleep(400_000) }
    } while status == 0x6982 && Date() < deadline
    if attempts > 1 { print("(\(attempts) attempts while waiting for the press)") }

    guard status == 0x9000 else {
        if status == 0x6982 { fail("refused (6982) — no button press within 20 s") }
        fail(String(format: "GENERAL AUTHENTICATE failed: %04x", status))
    }
    reply.removeLast(2)

    guard let dynamicResponse = TLV.first(0x7c, in: reply),
          let extracted = TLV.first(0x82, in: dynamicResponse) else {
        fail("no signature in the response")
    }
    signature = extracted
} catch {
    fail("GENERAL AUTHENTICATE: \(error)")
}

print("signature:   \(signature.count) bytes  \(hex(signature.prefix(12)))…")

// ---------------------------------------------------------------------------
// The real proof: the signature has to verify against the public key in the
// certificate the device itself just handed us.
let algorithm: SecKeyAlgorithm = isEC ? .ecdsaSignatureDigestX962SHA256
                                      : .rsaSignatureDigestPKCS1v15SHA256
var verifyError: Unmanaged<CFError>?
let valid = SecKeyVerifySignature(publicKey, algorithm,
                                  digest as CFData, signature as CFData, &verifyError)
guard valid else {
    fail("signature did NOT verify: \(verifyError?.takeRetainedValue().localizedDescription ?? "?")")
}

print("verified:    signature checks out against the on-device certificate")
print("\nend-to-end authentication over BLE works")
card.disconnect()
exit(0)
