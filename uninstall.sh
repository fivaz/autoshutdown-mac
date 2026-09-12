#!/bin/bash
# Removes AutoShutdown, however it was installed.
#
#   ./uninstall.sh                  remove everything, settings included
#   ./uninstall.sh --keep-settings  keep the shutdown time and any commitment lock
set -euo pipefail

LABEL="com.fivaz.autoshutdown"
KEEP_SETTINGS=0
[ "${1:-}" = "--keep-settings" ] && KEEP_SETTINGS=1

APPS=("/Applications/AutoShutdown.app" "$HOME/Applications/AutoShutdown.app")

# Withdraw the login item while the bundle still exists, otherwise a ghost entry
# is left behind in System Settings > General > Login Items.
for APP in "${APPS[@]}"; do
    BIN="$APP/Contents/MacOS/AutoShutdown"
    [ -x "$BIN" ] && "$BIN" --unregister-login-item >/dev/null 2>&1 || true
done

pkill -f "AutoShutdown.app/Contents/MacOS/AutoShutdown" 2>/dev/null || true

# Login items from older versions, which used LaunchAgents.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -e "/Library/LaunchAgents/$LABEL.plist" ] || [ -d "/Applications/AutoShutdown.app" ]; then
    echo "Removing the system-wide install (needs your password)…"
    sudo rm -f "/Library/LaunchAgents/$LABEL.plist"
    sudo rm -rf "/Applications/AutoShutdown.app"
    sudo pkgutil --forget "$LABEL" >/dev/null 2>&1 || true
fi

rm -rf "$HOME/Applications/AutoShutdown.app"

if [ "$KEEP_SETTINGS" = "1" ]; then
    echo "Settings kept. A commitment lock, if you set one, is still in force."
else
    defaults delete "$LABEL" 2>/dev/null || true
    echo "Settings erased, including any commitment lock."
fi

echo "AutoShutdown removed."
