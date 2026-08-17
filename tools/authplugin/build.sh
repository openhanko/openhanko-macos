#!/bin/bash
# Builds the authorization plugin bundle.
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE=build/SmartCardPresence.bundle
rm -rf build
mkdir -p "${BUNDLE}/Contents/MacOS"

clang -O2 -Wall -bundle -o "${BUNDLE}/Contents/MacOS/SmartCardPresence" \
    plugin.c -framework Security -framework CoreFoundation
cp Info.plist "${BUNDLE}/Contents/Info.plist"

# Signing is not strictly required for a plugin in /Library, but an ad-hoc
# signature keeps codesign --verify happy and matches what the system expects.
codesign --force --sign - "${BUNDLE}" 2>/dev/null || true

echo "built ${BUNDLE}"
