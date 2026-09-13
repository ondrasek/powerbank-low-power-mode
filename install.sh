#!/bin/bash
# Installs powerbank-lpm as a root LaunchDaemon. Run with sudo.
set -euo pipefail

LABEL="com.ondrasek.powerbank-low-power-mode"
SRC="$(cd "$(dirname "$0")" && pwd)"
BIN="/usr/local/bin/powerbank-lpm"
CONF="/usr/local/etc/powerbank-lpm.conf"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

# Refuse to install onto a system where the setting this tool writes is unproven.
if ! "$SRC/bin/powerbank-lpm" doctor; then
    echo
    echo "doctor reported problems (see above). Fix them, or re-run with FORCE=1." >&2
    [ "${FORCE:-0}" = "1" ] || exit 1
    echo "FORCE=1 set — continuing anyway." >&2
fi

install -d -m 755 /usr/local/bin /usr/local/etc
install -m 755 -o root -g wheel "$SRC/bin/powerbank-lpm" "$BIN"

if [ -f "$CONF" ]; then
    echo "Keeping existing $CONF"
else
    install -m 644 -o root -g wheel "$SRC/powerbank-lpm.conf.sample" "$CONF"
    echo "Wrote $CONF — add your power bank's fingerprint before it will do anything."
fi

install -m 644 -o root -g wheel "$SRC/launchd/$LABEL.plist" "$PLIST"

# bootout before bootstrap: `launchctl load -w` is deprecated and silently keeps
# the previously loaded job definition on reinstall.
launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
launchctl enable "system/$LABEL"

echo
echo "Installed. Next:"
echo "  1. Plug in the power bank:  powerbank-lpm identify"
echo "  2. Add the fingerprint to:  $CONF"
echo "  3. Reload:                  sudo launchctl kickstart -k system/$LABEL"
echo "  Logs: /var/log/powerbank-lpm.log"
