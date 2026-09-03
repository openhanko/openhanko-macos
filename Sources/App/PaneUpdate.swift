// Installing firmware, without picotool.
//
// The device was deliberately left updatable but not readable: SWD is fused shut
// and secure boot means only images signed with the project key will run, while
// USB mass storage stays open. Nothing surfaced that to anyone who was not
// already running picotool from a terminal.
//
// Dropping a UF2 on the bootloader volume is the whole mechanism. It is also
// safe by construction here, which is the part worth knowing: a wrong or
// tampered image copies fine and then refuses to boot, and the device returns to
// the bootloader rather than becoming a brick. The signature does the work — this
// pane only has to find the volume.

import AppKit

final class PaneUpdate: Pane {
    private let headline = UI.title("")
    private let detail = UI.body()
    private let installButton = NSButton()
    private let progress = UI.caption("")
    private var watchTimer: Timer?

    /// The bootloader's mass-storage volume. RP2350 mounts as RP2350; the older
    /// RP2040 used RPI-RP2, and a device that has been through both is not
    /// unusual on a workbench.
    private static let volumes = ["/Volumes/RP2350", "/Volumes/RPI-RP2"]

    private var bundledFirmware: URL? {
        Bundle.main.url(forResource: "firmware", withExtension: "uf2")
    }

    private var bootloaderVolume: String? {
        PaneUpdate.volumes.first { FileManager.default.fileExists(atPath: $0) }
    }

    override func build() {
        installButton.title = "Install Firmware"
        installButton.bezelStyle = .rounded
        installButton.target = self
        installButton.action = #selector(install)

        stack.setViews([headline, detail, installButton, progress], in: .leading)
        stack.setCustomSpacing(10, after: headline)
        stack.setCustomSpacing(16, after: detail)
        stack.setCustomSpacing(8, after: installButton)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The bootloader volume appears without the device's console appearing,
        // so the ordinary status poll cannot see it. This is the only pane that
        // needs to watch the filesystem instead.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.apply(DeviceAgent.shared.status, error: nil)
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        watchTimer?.invalidate()
        watchTimer = nil
    }

    override func apply(_ status: DeviceStatus?, error: String?) {
        guard bundledFirmware != nil else {
            headline.stringValue = "No firmware bundled"
            detail.stringValue = "This build does not carry a firmware image. Releases do."
            installButton.isHidden = true
            progress.stringValue = ""
            return
        }
        installButton.isHidden = false

        if let volume = bootloaderVolume {
            headline.stringValue = "Ready to install"
            detail.stringValue = """
                Installs the firmware bundled with this app. The device restarts \
                on its own.

                An image that is wrong or tampered with will not start, and the \
                device comes back here rather than becoming unusable.
                """
            installButton.isEnabled = true
            progress.stringValue = volume
        } else {
            headline.stringValue = "Put the device in update mode"
            detail.stringValue = """
                Double-tap the reset button on the device. A disk called RP2350 \
                appears and this page will notice it.

                This works even if the firmware is broken or missing.
                """
            installButton.isEnabled = false
            progress.stringValue = status.map { "\($0.name) is running normally." } ?? ""
        }
    }

    @objc private func install() {
        guard let source = bundledFirmware, let volume = bootloaderVolume else { return }
        installButton.isEnabled = false
        progress.stringValue = "Writing…"

        DispatchQueue.global(qos: .userInitiated).async {
            let destination = URL(fileURLWithPath: volume).appendingPathComponent("firmware.uf2")
            var message: String
            do {
                let data = try Data(contentsOf: source)
                try data.write(to: destination)
                // The bootloader reboots as soon as the last block lands, so the
                // volume disappearing is success. A write error at that moment is
                // the disk going away underneath us, not a failure.
                message = "Installed. The device is restarting."
            } catch {
                message = FileManager.default.fileExists(atPath: volume)
                    ? "Could not write to \(volume): \(error.localizedDescription)"
                    : "Installed. The device is restarting."
            }
            DispatchQueue.main.async {
                self.progress.stringValue = message
                self.installButton.isEnabled = true
                DeviceAgent.shared.refresh()
            }
        }
    }
}
