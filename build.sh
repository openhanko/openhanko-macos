#!/bin/bash
# Builds and signs the CryptoTokenKit token driver.
#
# Assembled by hand rather than with an .xcodeproj: the bundle layout for an app
# extension is simple enough (Info.plist plus a Mach-O linked with
# -e _NSExtensionMain) that a script is easier to read and to keep in the repo
# than several thousand lines of pbxproj.
#
#   ./build.sh              build and sign into build/
#   ./build.sh install      also copy to /Applications and register
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="OpenHanko"
EXT_NAME="OpenHankoToken"
BUNDLE="build/${APP_NAME}.app"
EXT_BUNDLE="${BUNDLE}/Contents/PlugIns/${EXT_NAME}.appex"
DEPLOY_TARGET="macos13.0"

# Universal: Apple silicon and Intel. The Intel Macs are half the point — they
# cannot use Apple's Touch ID keyboard at all, so they are the machines most in
# need of this. swiftc takes one -target per invocation, so each binary is built
# once per architecture and joined with lipo.
ARCHS=(arm64 x86_64)

# Compiles one Mach-O per architecture into build/obj, then lipos them into $out.
universal() {
    local out="$1"; shift
    local parts=()
    for arch in "${ARCHS[@]}"; do
        local part="build/obj/$(basename "$out").${arch}"
        swiftc "$@" -target "${arch}-apple-${DEPLOY_TARGET}" -O -o "$part"
        parts+=("$part")
    done
    lipo -create "${parts[@]}" -output "$out"
}

# Any Developer ID Application identity in the keychain. Ad-hoc signing is not
# enough: ctkd refuses to load an extension it cannot validate.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning |
    awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
    echo "no Developer ID Application identity found; set CODESIGN_IDENTITY" >&2
    exit 1
fi

rm -rf build
mkdir -p "${BUNDLE}/Contents/MacOS" "${EXT_BUNDLE}/Contents/MacOS" build/obj

echo "==> container app"
# Every file in Sources/App, not just main.swift: the app grew from one window
# into panes, a console client and a device agent, and a glob is one fewer thing
# to forget when adding the next one.
universal "${BUNDLE}/Contents/MacOS/${APP_NAME}" Sources/App/*.swift \
    -framework AppKit -framework CryptoTokenKit -framework Security
cp Resources/Info-app.plist "${BUNDLE}/Contents/Info.plist"

# No firmware image goes in here any more. It was 279K of a build artefact that
# was stale the moment it shipped, and the only way to replace it was another
# notarised release — which is exactly the problem the update feed exists to
# solve. The Update pane fetches from openhanko.io and checks the published
# SHA-256 before writing anything.
#
# Resources/firmware.uf2 is still read if present, because a bench build that
# wants to install a locally signed image without publishing it is a reasonable
# thing to want. Releases do not carry one.
mkdir -p "${BUNDLE}/Contents/Resources"
cp Resources/OpenHanko.icns "${BUNDLE}/Contents/Resources/"

if [ -f Resources/firmware.uf2 ] && [ "${BUNDLE_FIRMWARE:-0}" = "1" ]; then
    cp Resources/firmware.uf2 "${BUNDLE}/Contents/Resources/firmware.uf2"
    echo "    bundled firmware.uf2 ($(du -h Resources/firmware.uf2 | cut -f1)) — BUNDLE_FIRMWARE=1"
fi

echo "==> token extension"
# -module-name must match com.apple.ctk.driver-class in Info-ext.plist, since
# CryptoTokenKit looks the class up by its Swift-mangled <Module>.<Class> name.
# -e _NSExtensionMain is the entry point every .appex uses.
universal "${EXT_BUNDLE}/Contents/MacOS/${EXT_NAME}" Sources/Token/*.swift \
    -module-name "${EXT_NAME}" \
    -framework CryptoTokenKit -framework Foundation \
    -Xlinker -e -Xlinker _NSExtensionMain
cp Resources/Info-ext.plist "${EXT_BUNDLE}/Contents/Info.plist"

echo "==> signing as ${IDENTITY}"
# Inside out: the extension must already be sealed when the app is signed.
codesign --force --timestamp=none --options runtime \
    --entitlements Resources/token.entitlements \
    --sign "${IDENTITY}" "${EXT_BUNDLE}"
codesign --force --timestamp=none --options runtime \
    --sign "${IDENTITY}" "${BUNDLE}"
codesign --verify --deep --strict --verbose=2 "${BUNDLE}"

echo "==> built ${BUNDLE}"

# Never leave two registrations of the same extension.
#
# Launching the app from build/ registers that copy; installing registers the
# one in /Applications. Both then carry bundle id ${EXT_NAME}, from different
# paths and with different UUIDs, and ctkd will bind a token from one while the
# other is the process that runs. The card then answers nobody: sc_auth still
# lists the identity, system_profiler still lists the driver, no APDUs reach the
# card, and the extension logs nothing — which reads exactly like a code bug.
#
# It cannot happen to anyone who installs a release, because there is only ever
# one copy. It happens easily here, so `install` unregisters the build copy and
# a plain build says so when an installed copy already owns the registration.
if [ "${1:-}" = "install" ]; then
    echo "==> installing to /Applications"
    # Quit first: the app holds the device's serial port, and the extension is a
    # live process inside the bundle about to be replaced.
    osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
    pluginkit -r "${EXT_BUNDLE}" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${BUNDLE}" /Applications/

    # Replacing the bundle underneath ctkd leaves it serving a token identity
    # for an extension it will no longer launch: sc_auth keeps reporting the
    # token, no APDUs reach the card, and nothing is logged. Restarting it here
    # is what makes reinstalling reliable; both daemons relaunch on demand.
    killall ctkd pkd 2>/dev/null || true

    # pluginkit notices new extensions on its own, but nudging it makes the
    # registration immediate rather than eventual.
    pluginkit -a "/Applications/${APP_NAME}.app/Contents/PlugIns/${EXT_NAME}.appex" || true
    lsregister -f "/Applications/${APP_NAME}.app" 2>/dev/null \
        || /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
           -f "/Applications/${APP_NAME}.app"
    echo
    echo "registered extensions:"
    pluginkit -m -p com.apple.ctk-tokens | sed 's/^/    /'
    echo
    echo "re-insert the device: macOS binds a token driver at insertion."
elif [ -d "/Applications/${APP_NAME}.app" ]; then
    echo
    echo "note: /Applications/${APP_NAME}.app is installed and owns the extension"
    echo "      registration. Do not open ${BUNDLE} — two registrations of"
    echo "      ${EXT_NAME} wedge ctkd. Run './build.sh install' instead."
fi
