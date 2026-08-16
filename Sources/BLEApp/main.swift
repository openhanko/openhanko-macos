// Registers the device as a persistent CryptoTokenKit token.
//
// A wired smart card needs no app: ctkd sees a card in a reader, matches its
// AID, and launches the driver. Nothing does that for a device on the far end
// of a radio, so registration has to be explicit and something has to own the
// Bluetooth connection. An app extension cannot — it is launched on demand and
// killed when idle, and CoreBluetooth needs a process that stays put and holds
// the user's consent — so the app does, and the extension asks it to sign.
//
// This is the same shape Apple's own persistent token uses: PlatformSSOToken is
// a sandboxed extension with a mach-lookup exception onto a daemon that does
// the real work.

import AppKit
import CryptoTokenKit
import Security

/// Must match com.apple.ctk.class-id in the extension's Info.plist.
let tokenClassID = "dev.smartcard.bleapp.token"

/// The remembered device, so a later launch reconnects to the same one rather
/// than to whatever is in range.
let knownDeviceKey = "knownDeviceIdentifier"

final class Controller {
    let card = BLECard()

    /// Registers the certificate and key with CryptoTokenKit under a token
    /// instance identified by the device itself.
    func pair() throws -> String {
        let remembered = UserDefaults.standard.string(forKey: knownDeviceKey).flatMap(UUID.init(uuidString:))
        try card.connect(preferring: remembered, timeout: 20)

        try card.selectPIV()
        let certificateData = try card.readCertificate(slot: 0x9a)

        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw RegistrationError.message("slot 9A did not return a certificate")
        }
        guard let publicKey = SecCertificateCopyKey(certificate),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw RegistrationError.message("no public key in the certificate")
        }
        let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any] ?? [:]

        guard let identifier = card.deviceIdentifier else {
            throw RegistrationError.message("connected device has no identifier")
        }
        UserDefaults.standard.set(identifier.uuidString, forKey: knownDeviceKey)

        // The class ID appears here only once the extension is registered with
        // pluginkit, which means installed in /Applications and launched once.
        guard let driverConfiguration = TKTokenDriver.Configuration.driverConfigurations[tokenClassID] else {
            throw RegistrationError.message("""
                CryptoTokenKit does not know the class ID \(tokenClassID).
                The extension is not registered — install the app in /Applications and open it once.
                """)
        }

        let instanceID = identifier.uuidString

        // Remove before adding. ctkd persists a token's keychain contents per
        // instance ID, so re-pairing an existing instance keeps the *old*
        // published attributes and the change appears to have no effect — a
        // failure mode already paid for once on the wired driver.
        driverConfiguration.removeTokenConfiguration(for: instanceID)
        let configuration = driverConfiguration.addTokenConfiguration(for: instanceID)

        let label = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "smart-card"

        let certificateItem = TKTokenKeychainCertificate(certificate: certificate, objectID: "9a")
        certificateItem?.label = label

        let keyItem = TKTokenKeychainKey(certificate: certificate, objectID: "9a")
        keyItem?.label = label
        keyItem?.canSign = true
        keyItem?.canDecrypt = false
        keyItem?.canPerformKeyExchange = false
        // Marks the key as a credential LocalAuthentication may offer, which is
        // what an in-session unlock (System Settings) needs.
        //
        // The earlier `false` conflated two cases. Before login there is no user
        // session for CoreBluetooth and this cannot work; in session it demonstrably
        // does. The flag is not scopable to one of those, so the driver's short
        // timeouts are what keep the pre-login case harmless: it fails in about
        // four seconds and the password prompt proceeds.
        keyItem?.isSuitableForLogin = true
        keyItem?.publicKeyData = publicKeyData
        keyItem?.keyType = (attributes[kSecAttrKeyType as String] as? String) ?? (kSecAttrKeyTypeECSECPrimeRandom as String)
        keyItem?.keySizeInBits = (attributes[kSecAttrKeySizeInBits as String] as? Int) ?? 256

        // Deliberately unconstrained. A constraint makes CryptoTokenKit call
        // beginAuth before signing, which the wired driver needed in order to
        // get in front of the PIN dialog. There is no dialog here — no CCID, no
        // prompt — so the driver just blocks inside sign() until the button is
        // pressed, and the breathing LED is the whole user interface.

        guard let certificateItem, let keyItem else {
            throw RegistrationError.message("could not build the keychain items")
        }
        configuration.keychainItems = [certificateItem, keyItem]

        card.disconnect()
        return """
            paired \(card.deviceName ?? "device")
            instance \(instanceID)
            \(label)
            """
    }

    func unpair() -> String {
        guard let driverConfiguration = TKTokenDriver.Configuration.driverConfigurations[tokenClassID] else {
            return "the extension is not registered; nothing to remove"
        }
        let instances = driverConfiguration.tokenConfigurations.keys
        for instance in instances {
            driverConfiguration.removeTokenConfiguration(for: instance)
        }
        return instances.isEmpty ? "no tokens were registered"
                                 : "removed \(instances.count) token(s)"
    }

    func status() -> String {
        guard let driverConfiguration = TKTokenDriver.Configuration.driverConfigurations[tokenClassID] else {
            return "extension not registered with CryptoTokenKit"
        }
        let instances = driverConfiguration.tokenConfigurations.keys.sorted()
        if instances.isEmpty { return "extension registered; no token paired yet" }
        return "paired token(s):\n" + instances.map { "  \($0)" }.joined(separator: "\n")
    }
}

enum RegistrationError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// MARK: - UI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let controller = Controller()
    private let output = NSTextField(wrappingLabelWithString: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "smart-card (wireless)"

        let title = NSTextField(labelWithString: "Wireless smart card")
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let pair = NSButton(title: "Pair device", target: self, action: #selector(pairTapped))
        pair.keyEquivalent = "\r"
        let unpair = NSButton(title: "Unpair", target: self, action: #selector(unpairTapped))
        let refresh = NSButton(title: "Status", target: self, action: #selector(statusTapped))

        let buttons = NSStackView(views: [pair, unpair, refresh])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        output.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        output.stringValue = controller.status()

        let stack = NSStackView(views: [title, buttons, output])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
            ])
        }

        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Pairing touches the radio, so it must not run on the main thread.
    @objc private func pairTapped() {
        output.stringValue = "connecting over Bluetooth…"
        DispatchQueue.global().async {
            let result: String
            do { result = try self.controller.pair() }
            catch { result = "failed: \(error.localizedDescription)" }
            DispatchQueue.main.async { self.output.stringValue = result }
        }
    }

    @objc private func unpairTapped() { output.stringValue = controller.unpair() }
    @objc private func statusTapped() { output.stringValue = controller.status() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
