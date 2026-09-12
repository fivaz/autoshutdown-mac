#!/bin/bash
# Local install without building a disk image: compile, copy to Applications, launch.
# The app registers its own login item the first time it runs.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

"$DIR/build.sh"

if [ -w /Applications ]; then
    DEST="/Applications/AutoShutdown.app"
else
    mkdir -p "$HOME/Applications"
    DEST="$HOME/Applications/AutoShutdown.app"
fi

pkill -f "AutoShutdown.app/Contents/MacOS/AutoShutdown" 2>/dev/null || true
sleep 1

rm -rf "$DEST"
cp -R "$DIR/build/AutoShutdown.app" "$DEST"

open "$DEST"

echo "Installed to $DEST and launched."
echo "Look for the power icon in the menu bar; Settings opens by itself on first run."
