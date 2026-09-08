#!/bin/bash
# Removes the PAM module and its sudo_local line. Run with sudo.
set -euo pipefail
LOCAL=/etc/pam.d/sudo_local
TEMPLATE=/etc/pam.d/sudo_local.template

if [ "$(id -u)" != "0" ]; then echo "run with sudo" >&2; exit 1; fi

if [ -f "${LOCAL}" ]; then
    grep -v "pam_smartcard_presence" "${LOCAL}" > "${LOCAL}.tmp" || true

    # Anything left that is not a comment or blank belongs to somebody else —
    # pam_tid.so for Touch ID, most often — so keep the file as it now stands.
    #
    # Matched with a positive pattern rather than `grep -qv '^#'`, because the
    # exit status of an inverted match is not portable: BSD grep reports whether
    # a line was selected, and ugrep — which Homebrew puts ahead of it on PATH —
    # reports whether the pattern matched, so the same file answers 0 under one
    # and 1 under the other. Which grep is installed decided whether this file
    # survived.
    if grep -qE '^[[:space:]]*[^#[:space:]]' "${LOCAL}.tmp"; then
        mv "${LOCAL}.tmp" "${LOCAL}"
        echo "==> removed our line from ${LOCAL}"
    else
        # Otherwise put Apple's template back rather than deleting the file.
        # /etc/pam.d/sudo includes sudo_local unconditionally, and the template
        # is what a machine that never had this installed looks like — deleting
        # it leaves an include pointing at nothing, which is a state nobody
        # chose and one more variable to rule out when sudo misbehaves.
        rm -f "${LOCAL}.tmp"
        if [ -f "${TEMPLATE}" ]; then
            install -m 0644 "${TEMPLATE}" "${LOCAL}"
            echo "==> restored ${LOCAL} from ${TEMPLATE}"
        else
            rm -f "${LOCAL}"
            echo "==> removed ${LOCAL}; no template to restore from"
        fi
    fi
fi

rm -f /usr/local/lib/pam_smartcard_presence.so
rm -f /usr/local/libexec/smartcard-auth-helper

# Not "password only": /etc/pam.d/sudo still lists pam_smartcard.so after the
# include, so a paired card is still offered — as a PIN prompt on the TTY,
# which the device answers when touched.
echo "==> removed the module; sudo falls back to pam_smartcard's PIN prompt"
