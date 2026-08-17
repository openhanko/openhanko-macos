#!/bin/bash
# Installs the plugin and inserts its mechanism into the `authenticate` right.
# Run with sudo.
#
# `authenticate` is the shared rule that every class=user right delegates to —
# System Settings unlocks, admin elevations, and so on. That is a wide blast
# radius, so the right's current definition is backed up verbatim first and
# uninstall.sh restores it.
#
# The mechanism is inserted FIRST, before builtin:authenticate, which is the
# whole point: it can grant authorization before the password UI appears.
# Returning anything but Allow lets evaluation fall through to the builtins, so
# a failure just gets the usual prompt.
set -euo pipefail
cd "$(dirname "$0")"

# ---------------------------------------------------------------------------
# DO NOT INSTALL THIS. It is kept only as a reference implementation.
#
# Two independent reasons:
#
#   1. It does nothing. macOS 26 routes GUI authentication through
#      LocalAuthentication, not the authorization database, so this mechanism is
#      never invoked. Measured: authorizationhost ran zero mechanisms while
#      unlocking Privacy & Security and Users & Groups.
#
#   2. It locked a machine out. The mechanism sits in the *shared* `authenticate`
#      right, which the lock screen evaluates. Every unlock attempt ran it first,
#      where it blocked for up to 20 seconds waiting for a button press before
#      falling through — so a correct password came back "incorrect", and Touch
#      ID was rejected too. Recovery needed a reboot, because the initial login
#      window uses system.login.console, which this does not touch.
#
# Returning Undefined rather than Deny was not enough. The fallthrough was
# correct; the latency was fatal. Any mechanism in an authentication path must
# return promptly, always.
# ---------------------------------------------------------------------------
echo "refusing to install: see the comment at the top of this script" >&2
echo "this plugin is never invoked on macOS 26, and installing it has locked a machine out" >&2
exit 1

PLUGINS=/Library/Security/SecurityAgentPlugins
MECHANISM="SmartCardPresence:presence"
BACKUP=/usr/local/share/smartcard-authenticate-right.backup.plist

if [ "$(id -u)" != "0" ]; then echo "run with sudo" >&2; exit 1; fi
[ -d build/SmartCardPresence.bundle ] || { echo "build it first: ./build.sh" >&2; exit 1; }
[ -x /usr/local/libexec/smartcard-auth-helper ] || {
    echo "the helper is missing; run tools/pam/install.sh first" >&2; exit 1; }

echo "==> installing the plugin bundle"
mkdir -p "${PLUGINS}"
rm -rf "${PLUGINS}/SmartCardPresence.bundle"
cp -R build/SmartCardPresence.bundle "${PLUGINS}/"

echo "==> backing up the authenticate right to ${BACKUP}"
mkdir -p "$(dirname "${BACKUP}")"
[ -f "${BACKUP}" ] || security authorizationdb read authenticate > "${BACKUP}" 2>/dev/null

echo "==> inserting ${MECHANISM} ahead of the builtins"
security authorizationdb read authenticate > /tmp/authenticate.plist 2>/dev/null
python3 - "${MECHANISM}" <<'PY'
import plistlib, sys
mechanism = sys.argv[1]
with open("/tmp/authenticate.plist", "rb") as handle:
    right = plistlib.load(handle)
mechanisms = [m for m in right.get("mechanisms", []) if m != mechanism]
right["mechanisms"] = [mechanism] + mechanisms
with open("/tmp/authenticate.plist", "wb") as handle:
    plistlib.dump(right, handle)
print("   mechanisms now:", right["mechanisms"])
PY
security authorizationdb write authenticate < /tmp/authenticate.plist
rm -f /tmp/authenticate.plist

echo
echo "Test by unlocking something in System Settings."
echo "To undo:  sudo ./uninstall.sh"
