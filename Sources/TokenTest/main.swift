// Signs with a token-backed key through the ordinary Security APIs.
//
// This is the test that matters: it asks the keychain for token keys and calls
// SecKeyCreateSignature, which is the same path Chrome and the system take.
// Nothing here knows whether the token is wired or wireless — if this works,
// the driver is genuinely installed rather than merely registered.
//
//     tokentest              list token keys, sign with each
//     tokentest <substring>  only keys whose token ID contains <substring>

import CryptoKit
import Foundation
import Security

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

let filter = CommandLine.arguments.dropFirst().first

let query: [String: Any] = [
    kSecClass as String: kSecClassKey,
    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    kSecReturnRef as String: true,
    kSecReturnAttributes as String: true,
    kSecMatchLimit as String: kSecMatchLimitAll,
]

var result: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &result)
guard status == errSecSuccess, let items = result as? [[String: Any]] else {
    print("no private keys in the keychain (status \(status))")
    exit(1)
}

// Only keys living on a token; ordinary software keys are not interesting here.
let tokenKeys = items.filter { $0[kSecAttrTokenID as String] != nil }
    .filter { item in
        guard let filter else { return true }
        let tokenID = item[kSecAttrTokenID as String] as? String ?? ""
        return tokenID.localizedCaseInsensitiveContains(filter)
    }

print("found \(tokenKeys.count) token key(s)\n")
if tokenKeys.isEmpty {
    let all = items.compactMap { $0[kSecAttrTokenID as String] as? String }
    print("token IDs present: \(Set(all).sorted())")
    exit(1)
}

var anySigned = false

for item in tokenKeys {
    let tokenID = item[kSecAttrTokenID as String] as? String ?? "?"
    let label = item[kSecAttrLabel as String] as? String ?? "unnamed"
    guard let key = item[kSecValueRef as String] else {
        print("— \(label): no key reference"); continue
    }
    let privateKey = key as! SecKey

    print("— \(label)")
    print("  token: \(tokenID)")

    guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
        print("  no public key; skipping\n"); continue
    }
    let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any] ?? [:]
    let isEC = (attributes[kSecAttrKeyType as String] as? String) == (kSecAttrKeyTypeECSECPrimeRandom as String)
    let algorithm: SecKeyAlgorithm = isEC ? .ecdsaSignatureDigestX962SHA256
                                          : .rsaSignatureDigestPKCS1v15SHA256

    guard SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm) else {
        print("  does not support \(algorithm.rawValue)\n"); continue
    }

    let message = Data("token signing test".utf8)
    let digest = Data(SHA256.hash(data: message))

    print("  signing with \(algorithm.rawValue) — press the button if the device is waiting")
    let started = Date()

    var signError: Unmanaged<CFError>?
    guard let signature = SecKeyCreateSignature(privateKey, algorithm,
                                                digest as CFData, &signError) as Data? else {
        let error = signError?.takeRetainedValue()
        print("  FAILED after \(String(format: "%.1f", -started.timeIntervalSinceNow))s: "
              + "\(error?.localizedDescription ?? "unknown")\n")
        continue
    }

    let elapsed = -started.timeIntervalSinceNow
    print("  SIGNED: \(signature.count) bytes in \(String(format: "%.1f", elapsed))s  \(hex(signature.prefix(10)))…")

    var verifyError: Unmanaged<CFError>?
    let valid = SecKeyVerifySignature(publicKey, algorithm, digest as CFData,
                                      signature as CFData, &verifyError)
    print(valid ? "  verified against the token's public key\n"
                : "  DID NOT VERIFY: \(verifyError?.takeRetainedValue().localizedDescription ?? "?")\n")
    anySigned = anySigned || valid
}

exit(anySigned ? 0 : 1)
