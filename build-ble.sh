#!/bin/bash
# Builds and signs the wireless (BLE) token driver.
#
# Deliberately a separate bundle from build.sh rather than a variant of it. The
# wired driver works and is installed; a persistent token declares a completely
# different set of extension attributes, and one .appex cannot be both. Keeping
# them apart means breaking the wireless path cannot take the wired one with it.
#
#   ./build-ble.sh              build and sign into build/
#   ./build-ble.sh install      also copy to /Applications and register
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="OpenHankoBLE"
EXT_NAME="OpenHankoBLEToken"
BUNDLE="build/${APP_NAME}.app"
EXT_BUNDLE="${BUNDLE}/Contents/PlugIns/${EXT_NAME}.appex"
DEPLOY_TARGET="macos13.0"

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning |
    awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
    echo "no Developer ID Application identity found; set CODESIGN_IDENTITY" >&2
    exit 1
fi

rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${EXT_BUNDLE}/Contents/MacOS"

echo "==> container app"
# The app owns CoreBluetooth. An extension is launched on demand and killed
# when idle, which is no place to hold a radio connection or a TCC grant.
swiftc Sources/BLE/BLECard.swift Sources/BLEApp/main.swift \
    -target "arm64-apple-${DEPLOY_TARGET}" \
    -framework AppKit -framework CryptoTokenKit -framework CoreBluetooth -framework Security \
    -O -o "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info-ble-app.plist "${BUNDLE}/Contents/Info.plist"

echo "==> token extension"
# -module-name must match the module half of com.apple.ctk.driver-class.
swiftc Sources/BLE/BLECard.swift Sources/BLEToken/TokenDriver.swift \
    -target "arm64-apple-${DEPLOY_TARGET}" \
    -module-name "${EXT_NAME}" \
    -framework CryptoTokenKit -framework CoreBluetooth -framework Foundation \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -O -o "${EXT_BUNDLE}/Contents/MacOS/${EXT_NAME}"
cp Resources/Info-ble-ext.plist "${EXT_BUNDLE}/Contents/Info.plist"

echo "==> signing as ${IDENTITY}"
# Inside out: the extension must be sealed before the app is signed.
codesign --force --timestamp=none --options runtime \
    --entitlements Resources/ble-token.entitlements \
    --sign "${IDENTITY}" "${EXT_BUNDLE}"
codesign --force --timestamp=none --options runtime \
    --sign "${IDENTITY}" "${BUNDLE}"
codesign --verify --deep --strict --verbose=2 "${BUNDLE}"

echo "==> built ${BUNDLE}"

if [ "${1:-}" = "install" ]; then
    echo "==> installing to /Applications"
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${BUNDLE}" /Applications/
    pluginkit -a "/Applications/${APP_NAME}.app/Contents/PlugIns/${EXT_NAME}.appex" || true
    echo
    echo "registered CryptoTokenKit extensions:"
    pluginkit -m -p com.apple.ctk-tokens | sed 's/^/    /'
fi
