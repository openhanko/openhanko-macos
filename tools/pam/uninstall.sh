#!/bin/bash
# Removes the PAM module and its sudo_local line. Run with sudo.
set -euo pipefail
LOCAL=/etc/pam.d/sudo_local

if [ "$(id -u)" != "0" ]; then echo "run with sudo" >&2; exit 1; fi

if [ -f "${LOCAL}" ]; then
    grep -v "pam_smartcard_presence" "${LOCAL}" > "${LOCAL}.tmp" || true
    # An empty sudo_local is harmless, but removing it is tidier.
    if [ -s "${LOCAL}.tmp" ] && grep -qv '^#' "${LOCAL}.tmp"; then
        mv "${LOCAL}.tmp" "${LOCAL}"
    else
        rm -f "${LOCAL}.tmp" "${LOCAL}"
    fi
    echo "==> cleaned ${LOCAL}"
fi
rm -f /usr/local/lib/pam_smartcard_presence.so
rm -f /usr/local/libexec/smartcard-auth-helper
echo "==> removed the module; sudo is back to password only"
