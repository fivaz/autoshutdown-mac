#!/bin/bash
# Builds a signed, notarised drag-and-drop disk image.
#
#   ./make-dmg.sh                  build, sign, notarise, staple
#   SKIP_NOTARIZE=1 ./make-dmg.sh  sign but do not submit to Apple
#   SKIP_ICON=1 ./make-dmg.sh      leave the generic disk image icon
#   PLAIN_DMG=1 ./make-dmg.sh      no window styling at all
#   FORCE_STYLE=1 ./make-dmg.sh    re-record the layout from Finder, ignoring
#                                  the committed template
#
# Identities and notary credentials come from ./signing.env (see
# signing.env.example) or, in CI, from whatever is already in the keychain.
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
TEMPLATE="$DIR/Resources/dmg-DS_Store"

# shellcheck disable=SC1091
[ -f "$DIR/signing.env" ] && source "$DIR/signing.env"

: "${DEVELOPER_ID_APP:=}"
: "${NOTARY_PROFILE:=autoshutdown-notary}"
: "${SKIP_NOTARIZE:=0}"
: "${SKIP_ICON:=0}"
: "${PLAIN_DMG:=0}"
: "${FORCE_STYLE:=0}"

if [ -z "$DEVELOPER_ID_APP" ]; then
    DEVELOPER_ID_APP="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
fi

echo "==> Building app $VERSION"
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

# The mounted volume takes the app's icon rather than the generic disk icon.
ICNS="$APP/Contents/Resources/AppIcon.icns"
[ -f "$ICNS" ] && cp "$ICNS" "$STAGE/.VolumeIcon.icns"

if [ -f "$DIR/Resources/dmg-background.png" ]; then
    cp "$DIR/Resources/dmg-background.png" "$STAGE/.background/background.png"
    [ -f "$DIR/Resources/dmg-background@2x.png" ] && \
        cp "$DIR/Resources/dmg-background@2x.png" "$STAGE/.background/background@2x.png"
fi

# The window layout lives in a .DS_Store. There are two ways to get one:
# a committed template, which needs no desktop and is what CI uses, or Finder
# scripting on a real Mac, which is how the template gets made in the first place.
USE_TEMPLATE=0
if [ "$PLAIN_DMG" != "1" ] && [ "$FORCE_STYLE" != "1" ] && [ -f "$TEMPLATE" ]; then
    USE_TEMPLATE=1
    cp "$TEMPLATE" "$STAGE/.DS_Store"
    echo "    using the committed window layout"
fi

# A read/write image first, so the volume can be adjusted before compression.
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" \
    -fs HFS+ -format UDRW -ov "$RW" >/dev/null

# --- Adjust the mounted volume ---------------------------------------------

if [ "$PLAIN_DMG" != "1" ]; then
    echo "==> Preparing the volume"

    # A volume from an earlier run still mounted would claim the name, macOS would
    # mount this one as "AutoShutdown 1", and Finder would style the wrong disk.
    for STALE in /Volumes/"$VOLNAME"*; do
        [ -d "$STALE" ] || continue
        echo "    ejecting stale volume $STALE"
        hdiutil detach "$STALE" -force >/dev/null 2>&1 || true
    done

    MOUNT_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW")"
    DEVICE="$(echo "$MOUNT_OUT" | grep '^/dev/' | head -1 | awk '{print $1}')"
    MOUNTPOINT="$(echo "$MOUNT_OUT" | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | head -1)"
    VOL_ACTUAL="$(basename "$MOUNTPOINT")"
    echo "    mounted \"$VOL_ACTUAL\" at $MOUNTPOINT"

    STYLED=1

    if [ "$USE_TEMPLATE" != "1" ]; then
        # Finder scripting needs a desktop session. It is refused on CI runners
        # and can be refused locally without Automation permission.
        osascript <<APPLESCRIPT || STYLED=0
tell application "Finder"
    tell disk "$VOL_ACTUAL"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, 820, 560}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 12
        set background picture of opts to file ".background:background.png"
        set position of item "AutoShutdown.app" of container window to {165, 195}
        set position of item "Applications" of container window to {455, 195}
        update without registering applications
        delay 3
        close
    end tell
end tell
APPLESCRIPT
    fi

    # Tell Finder the volume carries its own icon. SetFile ships with Xcode; the
    # fallback sets the same kHasCustomIcon bit directly in the Finder info.
    if [ -f "$MOUNTPOINT/.VolumeIcon.icns" ]; then
        if command -v SetFile >/dev/null 2>&1; then
            SetFile -a C "$MOUNTPOINT" 2>/dev/null || true
        else
            python3 - "$MOUNTPOINT" <<'PYEOF' 2>/dev/null || true
import os, sys
path = sys.argv[1]
try:
    info = bytearray(os.getxattr(path, "com.apple.FinderInfo"))
except OSError:
    info = bytearray(32)
info = info.ljust(32, b"\0")
info[8] |= 0x04          # kHasCustomIcon, high byte of the big-endian flags
os.setxattr(path, "com.apple.FinderInfo", bytes(info))
PYEOF
        fi
        echo "    volume icon set"
    fi

    # Finder writes .DS_Store lazily, so confirm it actually landed rather than
    # trusting that the script returned without an error.
    sync
    sleep 2
    if [ -f "$MOUNTPOINT/.DS_Store" ]; then
        echo "    layout present ($(stat -f %z "$MOUNTPOINT/.DS_Store") bytes)"
        if [ "$USE_TEMPLATE" != "1" ] && [ "$STYLED" = "1" ]; then
            cp "$MOUNTPOINT/.DS_Store" "$TEMPLATE"
            echo "    layout saved to Resources/dmg-DS_Store — commit it so CI can reuse it"
        fi
    else
        STYLED=0
    fi

    if [ "$STYLED" != "1" ]; then
        cat <<'WARNEOF'
!!  The window layout was NOT saved. The image still works, it just opens
    with the default icon arrangement instead of the background and arrow.
    On a Mac with a desktop: the program running this script probably cannot
    control Finder. Open System Settings > Privacy & Security > Automation,
    find the app you ran it from, and turn on Finder underneath it.
    On a CI runner there is no desktop at all: commit Resources/dmg-DS_Store,
    produced by running this script once on your own Mac.
WARNEOF
    fi

    sync
    hdiutil detach "$DEVICE" >/dev/null 2>&1 || hdiutil detach "$MOUNTPOINT" -force >/dev/null
fi

# --- Compress ---------------------------------------------------------------

echo "==> Compressing"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -f "$RW"
rm -rf "$STAGE"

# --- Verify what actually ended up inside -----------------------------------

echo "==> Verifying contents"
VERIFY="$(hdiutil attach -readonly -noverify -noautoopen "$OUT" \
    | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | head -1)"
if [ -n "$VERIFY" ]; then
    [ -d "$VERIFY/AutoShutdown.app" ] && echo "    app present" || echo "!!  app MISSING"
    [ -L "$VERIFY/Applications" ] && echo "    Applications shortcut present" \
        || echo "!!  Applications shortcut MISSING"
    [ -f "$VERIFY/.background/background.png" ] && echo "    background present" \
        || echo "!!  background MISSING"
    if [ -f "$VERIFY/.DS_Store" ]; then
        echo "    window layout present"
    else
        echo "!!  window layout MISSING: the image will open with default icons"
    fi
    hdiutil detach "$VERIFY" >/dev/null 2>&1 || true
fi

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

# --- Give the .dmg file itself the app's icon -------------------------------

# Done last, after signing and stapling, so nothing downstream rewrites the file.
if [ "$SKIP_ICON" != "1" ] && [ -f "$ICNS" ]; then
    echo "==> Setting the disk image icon"
    if swiftc -O -o "$BUILD/seticon" "$DIR/tools/seticon.swift" 2>/dev/null \
        && "$BUILD/seticon" "$ICNS" "$OUT"; then
        echo "    icon applied"
        # The icon lives in the file's resource fork, outside the signed image
        # data, so the signature should survive. Confirm rather than assume.
        if [ -n "$DEVELOPER_ID_APP" ]; then
            if codesign --verify --verbose=1 "$OUT" >/dev/null 2>&1; then
                echo "    signature still valid"
            else
                echo "!!  signature broke; re-run with SKIP_ICON=1 and report this"
            fi
        fi
    else
        echo "!!  could not set the icon; the image works, it just looks generic"
    fi
fi

echo
echo "Disk image ready: $OUT"
echo "Open it, drag AutoShutdown to Applications, then open the app once."
