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

# Any Developer ID Application identity in the keychain. Ad-hoc signing is not
# enough: ctkd refuses to load an extension it cannot validate.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning |
    awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
    echo "no Developer ID Application identity found; set CODESIGN_IDENTITY" >&2
    exit 1
fi

rm -rf build
mkdir -p "${BUNDLE}/Contents/MacOS" "${EXT_BUNDLE}/Contents/MacOS"

echo "==> container app"
swiftc Sources/App/main.swift \
    -target "arm64-apple-${DEPLOY_TARGET}" \
    -framework AppKit -framework CryptoTokenKit -framework Security \
    -O -o "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info-app.plist "${BUNDLE}/Contents/Info.plist"

echo "==> token extension"
# -module-name must match com.apple.ctk.driver-class in Info-ext.plist, since
# CryptoTokenKit looks the class up by its Swift-mangled <Module>.<Class> name.
# -e _NSExtensionMain is the entry point every .appex uses.
swiftc Sources/Token/*.swift \
    -target "arm64-apple-${DEPLOY_TARGET}" \
    -module-name "${EXT_NAME}" \
    -framework CryptoTokenKit -framework Foundation \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -O -o "${EXT_BUNDLE}/Contents/MacOS/${EXT_NAME}"
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

if [ "${1:-}" = "install" ]; then
    echo "==> installing to /Applications"
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${BUNDLE}" /Applications/
    # pluginkit notices new extensions on its own, but nudging it makes the
    # registration immediate rather than eventual.
    pluginkit -a "/Applications/${APP_NAME}.app/Contents/PlugIns/${EXT_NAME}.appex" || true
    echo
    echo "registered extensions:"
    pluginkit -m -p com.apple.ctk-tokens | sed 's/^/    /'
fi
