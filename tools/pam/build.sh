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

echo "==> built:"
ls -l smartcard-auth smartcard-auth-helper pam_smartcard_presence.so | sed 's/^/    /'
