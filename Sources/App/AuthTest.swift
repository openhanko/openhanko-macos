// Proving the whole chain works, without waiting for something to need it.
//
// Until now the only ways to find out whether the device actually authenticates
// were to lock the screen or run `sudo` — both of which fail in ways that look
// identical whether the fault is the card, the driver, the pairing or macOS.
//
// Signing through the Security framework is the same path `tools/pam` takes and
// the one the driver was built for: SecKeyCreateSignature on a token key makes
// CryptoTokenKit call beginAuth, our driver answers with a secure-PIN request
// rather than a dialog, and the card holds it open until a finger arrives. No
// modal, nothing typed. In driverless mode the same call still succeeds, with
// macOS's own PIN box appearing and the device typing into it — so the test
// works in both modes, and which one you got is part of the answer.

import Foundation
import Security

enum AuthTest {
    struct Outcome {
        let ok: Bool
        let summary: String
        let detail: String
    }

    /// The device's *authentication* key, as macOS sees it.
    ///
    /// The card publishes two: slot 9A, which macOS authenticates logins and
    /// sudo with, and slot 9D, the key-management key it unwraps the login
    /// keychain with. They arrive as two entries with different labels, and
    /// picking either would be wrong for opposite reasons — the firmware
    /// consumes a fingerprint per 9A signature, while 9D runs against a separate
    /// session window that use does not consume. A test that landed on 9D could
    /// therefore succeed with no finger presented at all and report that
    /// authentication works, which is the one answer this must never give by
    /// accident.
    ///
    /// The device names itself after its 9A identity, and `STATUS` reports that
    /// name, so matching on it picks the right key without guessing. No match
    /// means no test, rather than a test of something else.
    private static func tokenKey(named deviceName: String) -> (key: SecKey, tokenID: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrAccessGroup as String: kSecAttrAccessGroupToken,
            kSecReturnRef as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return nil }

        let named = items.filter {
            ($0[kSecAttrLabel as String] as? String) == deviceName
        }
        // Ours first, then Apple's built-in driver holding the same card. Both
        // are the device; the difference is only which of them macOS bound, and
        // testing the one actually in charge is the point.
        let ours = named.first {
            ($0[kSecAttrTokenID as String] as? String)?.hasPrefix("io.openhanko") ?? false
        }
        let apple = named.first {
            ($0[kSecAttrTokenID as String] as? String)?.hasPrefix("com.apple.pivtoken") ?? false
        }
        guard let item = ours ?? apple,
              let tokenID = item[kSecAttrTokenID as String] as? String else { return nil }
        // SecItemCopyMatching returns the ref under kSecValueRef when both
        // kSecReturnRef and kSecReturnAttributes are asked for.
        guard let ref = item[kSecValueRef as String] else { return nil }
        return (unsafeBitCast(ref as AnyObject, to: SecKey.self), tokenID)
    }

    /// Signs a fresh challenge and checks the signature against the public key.
    ///
    /// Random, and verified rather than merely returned. A signature that comes
    /// back is evidence the card did something; a signature that *verifies* is
    /// evidence it did the right thing with the key macOS believes it has, which
    /// is the claim being tested.
    /// The wait is bounded, and the answer is delivered once.
    ///
    /// `SecKeyCreateSignature` blocks until the card answers and cannot be
    /// cancelled, so a card that never answers — unplugged mid-test, a driver
    /// that did not bind, ctkd holding a token for an extension it will not
    /// launch — leaves the caller waiting forever behind a dead button. The
    /// deadline reports that as an outcome like any other, and a real result
    /// arriving afterwards is dropped rather than overwriting it.
    static func run(deviceName: String, timeout: TimeInterval = 30,
                    completion: @escaping (Outcome) -> Void) {
        let once = NSLock()
        var answered = false
        let finish = { (outcome: Outcome) in
            once.lock()
            let first = !answered
            answered = true
            once.unlock()
            guard first else { return }
            DispatchQueue.main.async { completion(outcome) }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finish(Outcome(
                ok: false,
                summary: "No answer",
                detail: """
                    The device did not sign within \(Int(timeout)) seconds.

                    If the ring never flashed, macOS did not ask it. Reconnect \
                    the device and try again.
                    """))
        }

        DispatchQueue.global(qos: .userInitiated).async {

            guard let (key, tokenID) = tokenKey(named: deviceName) else {
                return finish(Outcome(
                    ok: false,
                    summary: "No key to test",
                    detail: """
                        macOS is not holding a key labelled \(deviceName). The \
                        card has not been read yet, or it has no identity.
                        """))
            }

            var challenge = Data(count: 32)
            _ = challenge.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
            }

            // The driver declares digest algorithms, not message ones — the card
            // is handed something already hashed, which is what a PIV
            // GENERAL AUTHENTICATE carries. So the 32 random bytes stand in for a
            // SHA-256 digest, exactly as tools/pam does.
            let attributes = SecKeyCopyAttributes(key) as? [String: Any] ?? [:]
            let isRSA = (attributes[kSecAttrKeyType as String] as? String)
                == (kSecAttrKeyTypeRSA as String)
            let algorithm: SecKeyAlgorithm = isRSA
                ? .rsaSignatureDigestPKCS1v15SHA256
                : .ecdsaSignatureDigestX962SHA256

            let started = Date()
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(
                key, algorithm, challenge as CFData, &error) as Data? else {
                let reason = (error?.takeRetainedValue() as Error?)?.localizedDescription
                    ?? "unknown"
                return finish(Outcome(
                    ok: false,
                    summary: "No signature",
                    detail: """
                        The card did not sign. \(reason)

                        Usually the device did not see a finger in time.
                        """))
            }
            let elapsed = Date().timeIntervalSince(started)

            guard let publicKey = SecKeyCopyPublicKey(key) else {
                return finish(Outcome(
                    ok: false,
                    summary: "Signed, but unverifiable",
                    detail: "The card signed, but macOS has no public key to check it against."))
            }
            let verified = SecKeyVerifySignature(
                publicKey, algorithm, challenge as CFData, signature as CFData, nil)

            let pinpad = tokenID.hasPrefix("io.openhanko")
            finish(Outcome(
                ok: verified,
                summary: verified
                    ? String(format: "Authenticated in %.2f s", elapsed)
                    : "Signature did not verify",
                detail: verified
                    ? (pinpad
                        ? """
                          The card signed a fresh challenge and it checked out. \
                          No PIN box, nothing typed — the fingerprint was the \
                          whole authentication.
                          """
                        : """
                          The card signed a fresh challenge and it checked out. \
                          macOS's own driver handled it, which is why a PIN box \
                          appeared; the device filled it in.
                          """)
                    : """
                      The signature does not match the card's own public key. \
                      That is a fault rather than a refusal — send a diagnostics \
                      copy.
                      """))
        }
    }
}
