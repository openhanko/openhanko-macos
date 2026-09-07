#!/bin/bash
# Installs the PAM module for sudo. Run with sudo.
set -euo pipefail

# ---------------------------------------------------------------------------
# DO NOT INSTALL THIS. It is kept as a reference implementation and for the
# standalone tester next to it, which still works and is still useful.
#
# Two independent reasons, both measured on macOS 26.6:
#
#   1. It cannot load. AMFI refuses to map a third-party library into a
#      platform binary, and /usr/bin/sudo is one:
#
#        Library Validation failed: Rejecting pam_smartcard_presence.so
#        (Team ID: 6W25N2CW6H, platform: no) for process 'sudo' (platform:
#        yes), reason: mapping process is a platform binary, but mapped file
#        is not
#
#      The verdict is `platform: no`, not the team, so signing does not fix
#      it — the rejection is identical ad-hoc signed and Developer ID signed.
#      Installed, it costs a failed mmap on every single sudo and does nothing.
#
#   2. It is not needed. Apple's own pam_smartcard reaches CryptoTokenKit,
#      which calls this project's token driver, which answers with a
#      PC_to_RDR_Secure request. `sudo -k && sudo -v` completes on a touch
#      with no PIN prompt while this module is being rejected on every
#      invocation — so the seamless path is Apple's, not ours.
#
# Verified on the device's own trace: SELECT, 87 11 9a -> 6982, the beginAuth
# breadcrumb 6a82, CCID 69 Secure, EVENT FINGER, 87 11 9a -> 9000.
# ---------------------------------------------------------------------------
echo "refusing to install: see the comment at the top of this script" >&2
echo "sudo already authenticates on a touch through Apple's pam_smartcard;" >&2
echo "this module cannot be loaded into sudo and would do nothing." >&2
exit 1

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
