// Asking openhanko.io what the current versions are.
//
// Two feeds, because they are two different problems.
//
// Firmware is the easy one. The device is its own trust anchor: secure boot
// means a locked unit runs nothing that is not signed with the project key, and
// an image that fails that check leaves the device in its bootloader rather than
// bricked. So the download does not have to be trusted to be safe to write. The
// SHA-256 checked here is a guard against a truncated download and casual
// tampering, not the thing standing between a user and hostile firmware — that
// is the signature the device itself verifies, on a curve (secp256k1) CryptoKit
// cannot check anyway.
//
// The app is the hard one, and it is deliberately notify-only. A downloaded
// application *is* the trust anchor, and an app that replaces its own binary is
// a much larger attack surface than one that does not. Gatekeeper verifying a
// notarised DMG the user downloaded themselves is stronger than anything this
// could do, so this says a version is available and links to it.
//
// What leaves the machine: two GETs to openhanko.io carrying a version string
// and nothing else. No identifier, no install count, no serial. The request is
// still a request, so it is switchable off in Settings and the origin's access
// log sees an address and a time like any web server.

import Foundation
import CryptoKit

struct Release {
    let version: String
    let url: URL
    let sha256: String?
    let notes: URL?
}

/// Carries a sentence meant for a person rather than a code meant for a switch,
/// because every one of these ends up in a caption under a button.
struct UpdateFailure: Error {
    let reason: String
}

enum Updates {
    /// Off means no network at all. Checked before every request rather than
    /// cached, so turning it off in Settings takes effect immediately.
    private static let key = "CheckForUpdates"

    static var enabled: Bool {
        get {
            // Absent means on. registerDefaults would do the same thing further
            // away from the code that depends on it.
            UserDefaults.standard.object(forKey: key) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static let base = URL(string: "https://openhanko.io/updates/")!

    private static var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 120
        // Explicit rather than whatever URLSession would compose. An update check
        // has to say which version is asking; it should not also volunteer the OS
        // build and the device model the way the default string does.
        config.httpAdditionalHeaders = ["User-Agent": "OpenHanko/\(appVersion)"]
        return URLSession(configuration: config)
    }()

    /// Compares versions like 0.2.0 and 0.2.0+b952441, ignoring the build suffix
    /// the firmware carries. Returns true when `candidate` is newer than `current`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: "+")[0].split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func fetch(_ name: String, completion: @escaping (Release?) -> Void) {
        guard enabled else { return completion(nil) }
        let task = session.dataTask(with: base.appendingPathComponent(name)) { data, response, _ in
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = object["version"] as? String,
                  let link = object["url"] as? String,
                  let url = URL(string: link),
                  url.scheme == "https"
            else { return completion(nil) }
            completion(Release(version: version,
                               url: url,
                               sha256: object["sha256"] as? String,
                               notes: (object["notes"] as? String).flatMap(URL.init(string:))))
        }
        task.resume()
    }

    static func app(completion: @escaping (Release?) -> Void) {
        fetch("app.json") { release in DispatchQueue.main.async { completion(release) } }
    }

    static func firmware(completion: @escaping (Release?) -> Void) {
        fetch("firmware.json") { release in DispatchQueue.main.async { completion(release) } }
    }

    /// Downloads a firmware image and checks it against the digest the feed
    /// stated. Refuses to hand back a file that does not match, so a truncated
    /// download cannot reach the bootloader volume looking like an image.
    static func download(_ release: Release, completion: @escaping (Result<URL, UpdateFailure>) -> Void) {
        func finish(_ result: Result<URL, UpdateFailure>) {
            DispatchQueue.main.async { completion(result) }
        }
        let task = session.dataTask(with: release.url) { data, response, error in
            guard let data, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return finish(.failure(UpdateFailure(reason: error?.localizedDescription ?? "the download did not complete")))
            }
            if let expected = release.sha256?.lowercased() {
                let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard got == expected else {
                    return finish(.failure(UpdateFailure(reason: "the downloaded image does not match the published checksum")))
                }
            }
            // Named for its version so a stale one cannot masquerade as a fresh
            // download, and in Caches because losing it costs a re-download.
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OpenHanko", isDirectory: true)
            let file = directory.appendingPathComponent("firmware-\(release.version).uf2")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: file)
            } catch {
                return finish(.failure(UpdateFailure(reason: error.localizedDescription)))
            }
            finish(.success(file))
        }
        task.resume()
    }
}
