#!/bin/bash
# Installs the PAM module for sudo. Run with sudo.
#
# Installed as `auth sufficient` in /etc/pam.d/sudo_local — Apple's documented
# hook, the same one Touch ID uses, and a file that survives system updates.
#
# `sufficient` is what makes this safe: if the module returns anything other
# than success the stack simply continues to the password prompt, exactly as
# today. The worst case is that nothing changes.
set -euo pipefail

MODULE=/usr/local/lib/pam_smartcard_presence.so
HELPER=/usr/local/libexec/smartcard-auth-helper
LOCAL=/etc/pam.d/sudo_local
LINE="auth       sufficient     ${MODULE}"

if [ "$(id -u)" != "0" ]; then echo "run with sudo" >&2; exit 1; fi
cd "$(dirname "$0")"

[ -f pam_smartcard_presence.so ] || { echo "build it first: ./build.sh" >&2; exit 1; }
[ -f smartcard-auth-helper ]      || { echo "build it first: ./build.sh" >&2; exit 1; }

echo "==> installing ${HELPER}"
mkdir -p /usr/local/libexec
install -m 0755 smartcard-auth-helper "${HELPER}"

echo "==> installing ${MODULE}"
mkdir -p /usr/local/lib
install -m 0644 pam_smartcard_presence.so "${MODULE}"

if [ -f "${LOCAL}" ] && grep -q "pam_smartcard_presence" "${LOCAL}"; then
    echo "==> ${LOCAL} already references the module"
else
    if [ -f "${LOCAL}" ]; then
        cp "${LOCAL}" "${LOCAL}.backup.$(date +%s)"
        echo "==> backed up existing ${LOCAL}"
    fi
    # Must come before pam_smartcard/pam_opendirectory, which sudo_local already
    # does: /etc/pam.d/sudo includes it as its first auth line.
    printf '# smart-card presence: touch the sensor instead of typing a PIN.\n%s\n' \
        "${LINE}" >> "${LOCAL}"
    echo "==> added to ${LOCAL}"
fi

echo
echo "current ${LOCAL}:"
sed 's/^/    /' "${LOCAL}"
echo
echo "Test in a NEW terminal, keeping a root shell open in this one:"
echo "    sudo -k && sudo -v"
echo "To undo:  sudo ./uninstall.sh"
