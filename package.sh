#!/bin/bash
# Builds a release DMG: signed, notarized, stapled.
#
# Separate from build.sh on purpose. build.sh is the fast loop — seconds, no
# network — and this is the slow one, because notarization is a round trip to
# Apple that takes minutes and needs credentials. Conflating them would put a
# multi-minute wait in the middle of every development build.
#
# Notarization is not optional for something people download. Without it macOS
# refuses to open the app at all beyond the first Gatekeeper prompt, and for a
# security device "right-click, Open, and confirm you trust the developer" is a
# terrible first instruction — it trains exactly the habit this device exists to
# make unnecessary.
#
#   ./package.sh 0.1.0
#
# Credentials, once, before the first run:
#
#   xcrun notarytool store-credentials openhanko-notary \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific>
#
# The app-specific password comes from appleid.apple.com, not your account
# password. Override the profile name with NOTARY_PROFILE if you use another.
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <version>   e.g. $0 0.1.0" >&2
    exit 1
fi

APP_NAME="OpenHanko"
BUNDLE="build/${APP_NAME}.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-openhanko-notary}"
DMG="build/${APP_NAME}-${VERSION}.dmg"
STAGING="build/dmg"

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning |
    awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
    echo "no Developer ID Application identity found; set CODESIGN_IDENTITY" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
echo "==> building ${APP_NAME} ${VERSION}"

# Stamp the version into the bundle so About and the Finder agree with the file
# name. Done before signing, since editing a plist afterwards breaks the seal.
./build.sh >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
    "${BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
    "${BUNDLE}/Contents/PlugIns/OpenHankoToken.appex/Contents/Info.plist"

# Re-sign inside out after the edit. The extension must be sealed before the app
# that contains it, or the app's seal covers a signature that no longer matches.
codesign --force --timestamp --options runtime \
    --entitlements Resources/token.entitlements \
    --sign "${IDENTITY}" "${BUNDLE}/Contents/PlugIns/OpenHankoToken.appex"
codesign --force --timestamp --options runtime \
    --sign "${IDENTITY}" "${BUNDLE}"
codesign --verify --deep --strict "${BUNDLE}"

# ---------------------------------------------------------------------------
echo "==> notarizing (a few minutes)"

# Notarization takes a zip or a disk image, never a bare bundle. ditto rather
# than zip: it preserves the resource forks and symlinks a signed bundle needs,
# and a plain zip has been known to invalidate the signature.
ZIP="build/${APP_NAME}-${VERSION}.zip"
/usr/bin/ditto -c -k --keepParent "${BUNDLE}" "${ZIP}"

xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait
rm -f "${ZIP}"

# Staple the ticket into the bundle so it validates offline. Without this the
# first launch on a machine with no network fails, which is a miserable way to
# discover the difference between "notarized" and "stapled".
xcrun stapler staple "${BUNDLE}"
xcrun stapler validate "${BUNDLE}"

# ---------------------------------------------------------------------------
echo "==> building ${DMG}"

rm -rf "${STAGING}" "${DMG}"
mkdir -p "${STAGING}"
cp -R "${BUNDLE}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING}" \
    -ov -format UDZO \
    "${DMG}" >/dev/null
rm -rf "${STAGING}"

# The disk image is signed and notarized in its own right. A stapled app inside
# an unsigned image still warns on download, because Gatekeeper judges what the
# user actually double-clicked.
codesign --force --timestamp --sign "${IDENTITY}" "${DMG}"
xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${DMG}"

echo
echo "==> ${DMG}"
spctl --assess --type open --context context:primary-signature -v "${DMG}" 2>&1 | sed 's/^/    /'
shasum -a 256 "${DMG}" | sed 's/^/    /'
