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

# Sign the module.
#
# clang leaves an ad-hoc, linker-signed binary, and AMFI refuses to map one into
# sudo, which is an Apple platform binary:
#
#   Library Validation failed: Rejecting '/usr/local/lib/pam_smartcard_presence.so'
#   (Team ID: none, platform: no) for process 'sudo' ... reason: mapping process
#   is a platform binary, but mapped file is not
#
# The module then never loads, PAM falls through to pam_smartcard.so, and sudo
# prompts for a PIN on the TTY — which looks exactly like our module declining.
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
