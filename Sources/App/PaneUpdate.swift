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
//
// The app still carries an image so that a machine with no network can install
// one. What it carries is whatever was current when the app was built, which is
// why this also asks openhanko.io: a firmware fix should not have to wait for an
// app release and a notarisation round trip to reach anybody. See Updates.swift
// for what that request contains and how to turn it off.

import AppKit

final class PaneUpdate: Pane {
    private let headline = UI.title("")
    private let detail = UI.body()
    private let installButton = NSButton()
    private let downloadButton = NSButton()
    private let progress = UI.caption("")
    private var watchTimer: Timer?
    private let bundledValue = UI.mono()
    private let latestKey = PaneUpdate.key("Latest released")
    private let latestValue = UI.mono()
    private let deviceKey = PaneUpdate.key("On your device")
    private let deviceValue = UI.mono()
    private let appLine = UI.body()
    private let appButton = NSButton()

    /// The last version a running device reported, and which device. In update
    /// mode the device is not running firmware at all and reports nothing, which
    /// is exactly when the comparison is wanted.
    private var lastSeen: (name: String, version: String?)?

    /// What the feed says exists, and what has actually been fetched and checked.
    private var latest: Release?
    private var downloaded: (version: String, url: URL)?
    private var appRelease: Release?

    private lazy var bundledVersion: String? = bundledFirmware.flatMap(PaneUpdate.versionInImage)

    private static func key(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        return label
    }

    /// Reads the firmware version out of a .uf2.
    ///
    /// The firmware carries `OPENHANKO_FW_VERSION=<version>` as one
    /// NUL-terminated string (openhanko-firmware/src/version.c), the same bytes
    /// STATUS reports as fw=. Reading it from the image means no sidecar file can
    /// drift from what is actually installed. UF2 blocks are 512 bytes, with the
    /// payload length at offset 16 and the payload from offset 32.
    static func versionInImage(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count % 512 == 0 else { return nil }
        var payload = Data()
        var offset = 0
        while offset + 512 <= data.count {
            let size = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 16, as: UInt32.self) }
            payload.append(data.subdata(in: (offset + 32)..<(offset + 32 + Int(min(size, 476)))))
            offset += 512
        }
        guard let found = payload.range(of: Data("OPENHANKO_FW_VERSION=".utf8)) else { return nil }
        let tail = payload[found.upperBound...]
        let end = tail.firstIndex(of: 0) ?? tail.endIndex
        return String(decoding: tail[..<end], as: UTF8.self)
    }

    /// The bootloader's mass-storage volume. RP2350 mounts as RP2350; the older
    /// RP2040 used RPI-RP2, and a device that has been through both is not
    /// unusual on a workbench.
    private static let volumes = ["/Volumes/RP2350", "/Volumes/RPI-RP2"]

    private var bundledFirmware: URL? {
        Bundle.main.url(forResource: "firmware", withExtension: "uf2")
    }

    /// A fetched image wins over the bundled one, because it is the newer of the
    /// two by the only test that got it here.
    private var sourceImage: URL? { downloaded?.url ?? bundledFirmware }
    private var sourceVersion: String? { downloaded?.version ?? bundledVersion }

    private var bootloaderVolume: String? {
        PaneUpdate.volumes.first { FileManager.default.fileExists(atPath: $0) }
    }

    override func build() {
        installButton.title = "Install Firmware"
        installButton.bezelStyle = .rounded
        installButton.target = self
        installButton.action = #selector(install)

        downloadButton.bezelStyle = .rounded
        downloadButton.target = self
        downloadButton.action = #selector(downloadFirmware)
        downloadButton.isHidden = true

        appButton.title = "See what changed"
        appButton.bezelStyle = .rounded
        appButton.target = self
        appButton.action = #selector(openAppRelease)
        appButton.isHidden = true
        appLine.isHidden = true

        let versions = UI.column([UI.row([PaneUpdate.key("Bundled with this app"), bundledValue], spacing: 10),
                                  UI.row([latestKey, latestValue], spacing: 10),
                                  UI.row([deviceKey, deviceValue], spacing: 10)], spacing: 4)
        stack.setViews([headline, detail, versions,
                        UI.row([installButton, downloadButton], spacing: 8), progress,
                        UI.separator(), appLine, appButton], in: .leading)
        stack.setCustomSpacing(10, after: headline)
        stack.setCustomSpacing(16, after: detail)
        stack.setCustomSpacing(16, after: versions)
        stack.setCustomSpacing(8, after: stack.views[3])
        stack.setCustomSpacing(20, after: progress)
        stack.setCustomSpacing(10, after: appLine)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The bootloader volume appears without the device's console appearing,
        // so the ordinary status poll cannot see it. This is the only pane that
        // needs to watch the filesystem instead.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.apply(DeviceAgent.shared.status, error: nil)
        }
        check()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        watchTimer?.invalidate()
        watchTimer = nil
    }

    /// Asks for both feeds. Nothing here is modal and nothing blocks: a machine
    /// with no network shows what the app was built with and installs that.
    private func check() {
        guard Updates.enabled else {
            latestValue.stringValue = "not checked — switched off in Settings"
            return
        }
        latestValue.stringValue = "checking…"
        Updates.firmware { [weak self] release in
            guard let self else { return }
            self.latest = release
            if release == nil { self.latestValue.stringValue = "could not reach openhanko.io" }
            self.apply(DeviceAgent.shared.status, error: nil)
        }
        Updates.app { [weak self] release in
            guard let self, let release else { return }
            self.appRelease = release
            guard Updates.isNewer(release.version, than: Updates.appVersion) else { return }
            self.appLine.stringValue = """
                OpenHanko \(release.version) is available. This app is \
                \(Updates.appVersion). Download it from the release page and \
                replace this copy; it will not replace itself.
                """
            self.appLine.isHidden = false
            self.appButton.isHidden = release.notes == nil && release.url.path.isEmpty
        }
    }

    override func apply(_ status: DeviceStatus?, error: String?) {
        showVersions(status)

        // Having no image in hand is the ordinary state of a fresh install now
        // that releases carry none, so it is a step in the sequence rather than
        // the dead end it used to be.
        guard sourceImage != nil else {
            installButton.isHidden = true
            headline.stringValue = "Nothing to install yet"
            if !Updates.enabled {
                detail.stringValue = """
                    Update checking is switched off in Settings, so this cannot \
                    fetch firmware. Turn it on, or install with picotool.
                    """
            } else if let latest {
                detail.stringValue = """
                    Firmware \(latest.version) is published. Download it here, \
                    then put the device in update mode to install it.

                    The download is checked against the checksum openhanko.io \
                    publishes before it is written to anything.
                    """
            } else {
                detail.stringValue = """
                    This build carries no firmware image, and openhanko.io has \
                    not answered yet. Firmware arrives through this pane rather \
                    than inside the app.
                    """
            }
            return
        }
        installButton.isHidden = false

        if let volume = bootloaderVolume {
            headline.stringValue = "Ready to install"
            let which = downloaded != nil ? "the firmware downloaded from openhanko.io"
                                          : "the firmware bundled with this app"
            detail.stringValue = """
                Installs \(which). The device restarts on its own.

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
            if progress.stringValue.isEmpty || PaneUpdate.volumes.contains(progress.stringValue) {
                progress.stringValue = status.map { "\($0.name) is running normally." } ?? ""
            }
        }
    }

    private func showVersions(_ status: DeviceStatus?) {
        if let status { lastSeen = (status.name, status.firmwareVersion) }
        bundledValue.stringValue = bundledVersion ?? "not stated in the image"

        // The middle row carries the whole point of asking: whether anything
        // newer than this app's own copy exists, and whether it is in hand yet.
        if let downloaded {
            latestKey.stringValue = "Downloaded"
            latestValue.stringValue = "\(downloaded.version) — ready to install"
            downloadButton.isHidden = true
        } else if let latest {
            latestKey.stringValue = "Latest released"
            let newer = bundledVersion.map { Updates.isNewer(latest.version, than: $0) } ?? true
            latestValue.stringValue = newer ? "\(latest.version) — newer than the bundled one"
                                            : "\(latest.version) — the bundled one is current"
            downloadButton.title = "Download \(latest.version)"
            downloadButton.isHidden = !newer
        }

        guard let seen = lastSeen else {
            deviceKey.stringValue = "On your device"
            deviceValue.stringValue = "connect it to find out"
            return
        }
        // Named when it came from an earlier reading, since a device in update
        // mode is not the one talking, and it need not be the same device.
        deviceKey.stringValue = status == nil ? "Last seen on \(seen.name)" : "On \(seen.name)"
        guard let installed = seen.version else {
            deviceValue.stringValue = "not reported — predates versioning"
            return
        }
        deviceValue.stringValue = installed == sourceVersion ? "\(installed) — the same" : installed
    }

    @objc private func downloadFirmware() {
        guard let latest else { return }
        downloadButton.isEnabled = false
        progress.stringValue = "Downloading \(latest.version)…"
        Updates.download(latest) { [weak self] result in
            guard let self else { return }
            self.downloadButton.isEnabled = true
            switch result {
            case .success(let file):
                // Trust the image over the feed about its own version: the string
                // is compiled into the firmware, and a feed that disagrees with it
                // is a feed that is wrong.
                let stated = PaneUpdate.versionInImage(at: file) ?? latest.version
                self.downloaded = (stated, file)
                self.progress.stringValue = "Downloaded and checked. Put the device in update mode to install."
            case .failure(let why):
                self.progress.stringValue = "Download failed: \(why.reason)"
            }
            self.apply(DeviceAgent.shared.status, error: nil)
        }
    }

    @objc private func openAppRelease() {
        guard let release = appRelease else { return }
        NSWorkspace.shared.open(release.notes ?? release.url)
    }

    @objc private func install() {
        guard let source = sourceImage, let volume = bootloaderVolume else { return }
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
