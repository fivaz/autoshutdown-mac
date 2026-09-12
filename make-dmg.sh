#!/bin/bash
# Builds a signed, notarised drag-and-drop disk image.
#
#   ./make-dmg.sh                  build, sign, notarise, staple
#   SKIP_NOTARIZE=1 ./make-dmg.sh  sign but do not submit to Apple
#   PLAIN_DMG=1 ./make-dmg.sh      skip the Finder window styling
#
# Identities and notary credentials come from ./signing.env (see signing.env.example).
# Anything missing degrades gracefully rather than failing the build.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
APP="$BUILD/AutoShutdown.app"
VOLNAME="AutoShutdown"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DIR/Info.plist")"
OUT="$BUILD/AutoShutdown-$VERSION.dmg"

STAGE="$BUILD/dmg-stage"
RW="$BUILD/rw.dmg"

# shellcheck disable=SC1091
[ -f "$DIR/signing.env" ] && source "$DIR/signing.env"

: "${DEVELOPER_ID_APP:=}"
: "${NOTARY_PROFILE:=autoshutdown-notary}"
: "${SKIP_NOTARIZE:=0}"
: "${PLAIN_DMG:=0}"

if [ -z "$DEVELOPER_ID_APP" ]; then
    DEVELOPER_ID_APP="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
fi

echo "==> Building app"
"$DIR/build.sh"

# --- Sign the app -----------------------------------------------------------

if [ -n "$DEVELOPER_ID_APP" ]; then
    echo "==> Signing app as: $DEVELOPER_ID_APP"
    codesign --force --options runtime --timestamp \
        --entitlements "$DIR/AutoShutdown.entitlements" \
        --sign "$DEVELOPER_ID_APP" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
else
    echo "!!  No Developer ID Application identity found."
    echo "    The app keeps its ad-hoc signature and will warn on other Macs."
fi

# --- Stage the image contents ----------------------------------------------

echo "==> Staging disk image"
rm -rf "$STAGE" "$RW" "$OUT"
mkdir -p "$STAGE/.background"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

if [ -f "$DIR/Resources/dmg-background.png" ]; then
    cp "$DIR/Resources/dmg-background.png" "$STAGE/.background/background.png"
    [ -f "$DIR/Resources/dmg-background@2x.png" ] && \
        cp "$DIR/Resources/dmg-background@2x.png" "$STAGE/.background/background@2x.png"
fi

# A read/write image first, so Finder can record the window layout inside it.
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" \
    -fs HFS+ -format UDRW -ov "$RW" >/dev/null

# --- Lay out the Finder window ---------------------------------------------

if [ "$PLAIN_DMG" != "1" ]; then
    echo "==> Styling the window"
    MOUNT_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW")"
    DEVICE="$(echo "$MOUNT_OUT" | grep '^/dev/' | head -1 | awk '{print $1}')"
    MOUNTPOINT="/Volumes/$VOLNAME"

    # Finder scripting can be refused (no permission, no session). Not fatal:
    # the image still works, it just opens with the default icon layout.
    if ! osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, 820, 560}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set background picture of opts to file ".background:background.png"
        set position of item "AutoShutdown.app" of container window to {165, 195}
        set position of item "Applications" of container window to {455, 195}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
    then
        echo "!!  Finder styling was refused; falling back to the default layout."
        echo "    Grant Terminal control of Finder in System Settings > Privacy & Security > Automation,"
        echo "    or run with PLAIN_DMG=1 to skip this step entirely."
    fi

    sync
    hdiutil detach "$DEVICE" >/dev/null || hdiutil detach "$MOUNTPOINT" -force >/dev/null
fi

# --- Compress ---------------------------------------------------------------

echo "==> Compressing"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -f "$RW"
rm -rf "$STAGE"

# --- Sign and notarise the image -------------------------------------------

if [ -n "$DEVELOPER_ID_APP" ]; then
    echo "==> Signing disk image"
    codesign --force --sign "$DEVELOPER_ID_APP" "$OUT"
fi

if [ "$SKIP_NOTARIZE" = "1" ]; then
    echo "==> Skipping notarisation (SKIP_NOTARIZE=1)"
elif [ -z "$DEVELOPER_ID_APP" ]; then
    echo "==> Skipping notarisation: nothing is signed."
elif ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "==> Skipping notarisation: no credentials for profile '$NOTARY_PROFILE'."
    echo "    Store them once with:"
    echo "      xcrun notarytool store-credentials $NOTARY_PROFILE \\"
    echo "          --apple-id YOU@EXAMPLE.COM --team-id TEAMID --password APP-SPECIFIC-PASSWORD"
else
    echo "==> Notarising (this takes a few minutes)"
    xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT"
    xcrun stapler validate "$OUT"
fi

echo
echo "Disk image ready: $OUT"
echo "Open it, drag AutoShutdown to Applications, then open the app once."
