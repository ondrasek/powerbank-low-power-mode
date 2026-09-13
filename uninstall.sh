#!/bin/bash
# Removes the daemon and binary. Leaves the config file and restores Low Power Mode.
set -euo pipefail

LABEL="com.ondrasek.powerbank-low-power-mode"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
STATE="/var/db/powerbank-lpm.state"

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "$PLIST" /usr/local/bin/powerbank-lpm

# Put Low Power Mode back to whatever it was before this tool first touched it.
if [ -f "$STATE" ]; then
    prev="$(head -1 "$STATE")"
    [ -n "$prev" ] && pmset -a lowpowermode "$prev" 2>/dev/null || true
    rm -f "$STATE"
fi

echo "Removed. Config kept at /usr/local/etc/powerbank-lpm.conf"
