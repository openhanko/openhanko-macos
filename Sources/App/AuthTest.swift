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
    static func run(deviceName: String, completion: @escaping (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let finish = { (outcome: Outcome) in
                DispatchQueue.main.async { completion(outcome) }
            }

            guard let (key, tokenID) = tokenKey(named: deviceName) else {
                return finish(Outcome(
                    ok: false,
                    summary: "No key to test",
                    detail: """
                        macOS is not holding an authentication key labelled \
                        \(deviceName). That usually means the card has not been \
                        read yet, or it has no identity.
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

                        A refusal here is usually the device not seeing a finger \
                        in time, or a sensor it will not accept.
                        """))
            }
            let elapsed = Date().timeIntervalSince(started)

            guard let publicKey = SecKeyCopyPublicKey(key) else {
                return finish(Outcome(
                    ok: false,
                    summary: "Signed, but unverifiable",
                    detail: "The card produced a signature and macOS has no public key to check it against."))
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
                          A fresh challenge was signed by the card and checked \
                          against its public key. This driver handled it, so no \
                          PIN box appeared and nothing was typed — the fingerprint \
                          was the whole authentication.
                          """
                        : """
                          A fresh challenge was signed by the card and checked \
                          against its public key. macOS's own driver handled it, \
                          which is why a PIN box appeared; the device filled it \
                          in when you touched the sensor.
                          """)
                    : """
                      The card returned a signature that does not match its own \
                      public key. That is a real fault rather than a refusal — \
                      worth a diagnostics copy.
                      """))
        }
    }
}
