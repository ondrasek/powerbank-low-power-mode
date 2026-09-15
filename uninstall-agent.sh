#!/bin/bash
# Removes the user-level agent, its sudoers rule, and restores Low Power Mode.
set -euo pipefail
LABEL="com.ondrasek.powerbank-low-power-mode"
STATE="$HOME/Library/Application Support/powerbank-lpm/state"

[ "$(id -u)" -ne 0 ] || { echo "Run this as yourself, NOT with sudo." >&2; exit 1; }

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/powerbank-lpm"

if [ -f "$STATE" ]; then
    prev="$(head -1 "$STATE")"
    [ -n "$prev" ] && sudo -n /usr/bin/pmset -a lowpowermode "$prev" 2>/dev/null || true
    rm -f "$STATE"
fi

sudo rm -f /etc/sudoers.d/powerbank-lpm
echo "Removed. Config kept at $HOME/.config/powerbank-lpm.conf"
