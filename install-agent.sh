#!/bin/bash
# User-level install: LaunchAgent in ~/Library/LaunchAgents.
#
# Run as YOURSELF, not with sudo. Everything lives under $HOME except one thing:
# the agent cannot write power settings on its own, so this also installs a
# sudoers rule scoped to exactly two commands. That single step needs root.
# If you would rather not have a sudoers rule at all, use ./install.sh instead.
set -euo pipefail

LABEL="com.ondrasek.powerbank-low-power-mode"
SRC="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin/powerbank-lpm"
CONF="$HOME/.config/powerbank-lpm.conf"
SUPPORT="$HOME/Library/Application Support/powerbank-lpm"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/powerbank-lpm.log"
SUDOERS="/etc/sudoers.d/powerbank-lpm"

[ "$(id -u)" -ne 0 ] || { echo "Run this as yourself, NOT with sudo." >&2; exit 1; }

# The rule is deliberately two exact command lines. sudoers matches the full
# argument vector, so this grants the ability to toggle Low Power Mode and
# nothing else — not `pmset` in general, which can also schedule wakes and
# change hibernation behaviour.
RULE="$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1"

echo "This installs:"
echo "  $BIN"
echo "  $CONF"
echo "  $PLIST"
echo "  $SUDOERS  (requires sudo — the only privileged part)"
echo
echo "The sudoers rule will be exactly:"
echo "  $RULE"
echo
if [ "${1:-}" != "--yes" ]; then
    printf 'Proceed? [y/N] '
    read -r reply
    case "$reply" in [yY]*) ;; *) echo "Aborted."; exit 1 ;; esac
fi

mkdir -p "$HOME/.local/bin" "$HOME/.config" "$SUPPORT" \
         "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 755 "$SRC/bin/powerbank-lpm" "$BIN"
[ -f "$CONF" ] && echo "Keeping existing $CONF" \
    || install -m 644 "$SRC/powerbank-lpm.conf.sample" "$CONF"

# Validate before installing: a malformed sudoers file can lock you out of sudo.
tmp="$(mktemp)"
printf '%s\n' "$RULE" > "$tmp"
if ! visudo -cf "$tmp" >/dev/null; then
    echo "Generated sudoers rule failed validation — refusing to install it." >&2
    rm -f "$tmp"; exit 1
fi
sudo install -m 440 -o root -g wheel "$tmp" "$SUDOERS"
rm -f "$tmp"
sudo visudo -c >/dev/null || { echo "sudoers validation failed after install!" >&2; exit 1; }

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>watch</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>POWERBANK_LPM_CONFIG</key>
        <string>$CONF</string>
        <key>POWERBANK_LPM_STATE</key>
        <string>$SUPPORT/state</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST_EOF

plutil -lint "$PLIST" >/dev/null
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/$LABEL"

echo
echo "Installed as a user agent. Next:"
echo "  1. Plug in the power bank:  $BIN identify"
echo "  2. Add its vid:pid to BANK_DEVICES in $CONF"
echo "  3. Reload: launchctl kickstart -k gui/$(id -u)/$LABEL"
echo "  Logs: $LOG"
