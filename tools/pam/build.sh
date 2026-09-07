#!/bin/bash
# Builds the standalone tester and the PAM module.
set -euo pipefail
cd "$(dirname "$0")"

FRAMEWORKS="-framework CoreFoundation -framework Security -framework OpenDirectory"

echo "==> standalone tester"
clang -O2 -Wall -o smartcard-auth smartcard-auth.c token_auth.c $FRAMEWORKS

echo "==> privilege-dropped helper"
clang -O2 -Wall -o smartcard-auth-helper smartcard-auth-helper.c token_auth.c $FRAMEWORKS

echo "==> PAM module"
# PAM modules on macOS are shared libraries, loaded by absolute path from
# /etc/pam.d because /usr/lib/pam is SIP-restricted.
clang -O2 -Wall -shared -o pam_smartcard_presence.so \
    pam_smartcard_presence.c $FRAMEWORKS -lpam

# Sign the helper and the module.
#
# This does NOT make the module loadable by sudo, which was the reason it was
# added: AMFI's objection is `platform: no`, not the team, so a Developer ID
# signature is rejected exactly as the ad-hoc one was. Nothing a third party can
# sign will load into a platform binary. See install.sh, which refuses.
#
# Kept because the helper is a real executable that Gatekeeper will judge, and
# an ad-hoc signature is the wrong thing to ship regardless.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | sed 's/.*"\(.*\)"/\1/')}"
if [ -n "${IDENTITY}" ]; then
    echo "==> signing as ${IDENTITY}"
    codesign --force --timestamp=none --sign "${IDENTITY}" pam_smartcard_presence.so
    codesign --force --timestamp=none --sign "${IDENTITY}" smartcard-auth-helper
else
    echo "!! no Developer ID Application identity; the module will stay ad-hoc"
    echo "   signed and sudo will refuse to load it."
fi

echo "==> built:"
ls -l smartcard-auth smartcard-auth-helper pam_smartcard_presence.so | sed 's/^/    /'
