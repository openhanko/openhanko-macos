#!/bin/bash
# Restores the authenticate right and removes the plugin. Run with sudo.
set -euo pipefail
BACKUP=/usr/local/share/smartcard-authenticate-right.backup.plist

if [ "$(id -u)" != "0" ]; then echo "run with sudo" >&2; exit 1; fi

if [ -f "${BACKUP}" ]; then
    echo "==> restoring the authenticate right from backup"
    security authorizationdb write authenticate < "${BACKUP}"
else
    echo "==> no backup found; removing our mechanism by name"
    security authorizationdb read authenticate > /tmp/authenticate.plist
    python3 - <<'PY'
import plistlib
with open("/tmp/authenticate.plist", "rb") as handle:
    right = plistlib.load(handle)
right["mechanisms"] = [m for m in right.get("mechanisms", []) if "SmartCardPresence" not in m]
with open("/tmp/authenticate.plist", "wb") as handle:
    plistlib.dump(right, handle)
PY
    security authorizationdb write authenticate < /tmp/authenticate.plist
    rm -f /tmp/authenticate.plist
fi

rm -rf /Library/Security/SecurityAgentPlugins/SmartCardPresence.bundle
echo "==> removed; GUI authorization is back to password only"
security authorizationdb read authenticate 2>/dev/null | plutil -p - | grep -A5 mechanisms
