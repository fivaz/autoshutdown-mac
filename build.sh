#!/bin/bash
# Builds AutoShutdown.app into ./build
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/AutoShutdown.app"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc not found. Install the Xcode command line tools: xcode-select --install" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

# The icon, assembled from the committed iconset.
if command -v iconutil >/dev/null 2>&1 && [ -d "$DIR/Resources/AppIcon.iconset" ]; then
    iconutil --convert icns \
        --output "$APP/Contents/Resources/AppIcon.icns" \
        "$DIR/Resources/AppIcon.iconset"
else
    echo "note: iconutil or the iconset is missing; the app will use the generic icon"
fi

swiftc -O \
    -o "$APP/Contents/MacOS/AutoShutdown" \
    "$DIR/Sources/main.swift" \
    "$DIR/Sources/UI.swift" \
    "$DIR/Sources/LoginItem.swift"

# Ad-hoc signature so macOS treats it as a stable app identity.
# make-dmg.sh replaces this with a Developer ID signature.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run it with: open \"$APP\""
