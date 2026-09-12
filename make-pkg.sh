#!/bin/bash
# Builds a signed, notarised AutoShutdown installer package.
#
#   ./make-pkg.sh            builds, signs, notarises, staples
#   SKIP_NOTARIZE=1 ./make-pkg.sh    signs but does not submit to Apple
#
# Identities and notary credentials come from ./signing.env (see signing.env.example).
# Anything missing degrades gracefully: the package is still produced, just less trusted.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
APP="$BUILD/AutoShutdown.app"
PKGROOT="$BUILD/pkgroot"
SCRIPTS="$BUILD/scripts"

LABEL="com.fivaz.autoshutdown"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DIR/Info.plist")"
OUT="$BUILD/AutoShutdown-$VERSION.pkg"

# shellcheck disable=SC1091
[ -f "$DIR/signing.env" ] && source "$DIR/signing.env"

: "${DEVELOPER_ID_APP:=}"
: "${DEVELOPER_ID_INSTALLER:=}"
: "${NOTARY_PROFILE:=autoshutdown-notary}"
: "${SKIP_NOTARIZE:=0}"

if [ -z "$DEVELOPER_ID_APP" ]; then
    DEVELOPER_ID_APP="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$DEVELOPER_ID_INSTALLER" ]; then
    DEVELOPER_ID_INSTALLER="$(security find-identity -v \
        | sed -n 's/.*"\(Developer ID Installer:[^"]*\)".*/\1/p' | head -1)"
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
    echo "    The app keeps its ad-hoc signature; the installer will warn on other Macs."
fi

# --- Assemble the payload ---------------------------------------------------

echo "==> Assembling payload"
rm -rf "$PKGROOT" "$SCRIPTS" "$BUILD/component.pkg" "$BUILD/distribution.xml"
mkdir -p "$PKGROOT/Applications" "$SCRIPTS"

cp -R "$APP" "$PKGROOT/Applications/"

# No LaunchAgent: the app registers its own login item through SMAppService the
# first time it runs, so the package installs nothing outside the bundle.

cat > "$SCRIPTS/preinstall" <<'SCRIPTEOF'
#!/bin/bash
LABEL="com.fivaz.autoshutdown"
USER_NAME=$(stat -f %Su /dev/console)
USER_UID=$(id -u "$USER_NAME" 2>/dev/null || echo "")
if [ -n "$USER_UID" ]; then
    launchctl bootout "gui/$USER_UID/$LABEL" 2>/dev/null || true
fi
pkill -f "/Applications/AutoShutdown.app/Contents/MacOS/AutoShutdown" 2>/dev/null || true
exit 0
SCRIPTEOF

cat > "$SCRIPTS/postinstall" <<'SCRIPTEOF'
#!/bin/bash
USER_NAME=$(stat -f %Su /dev/console)
USER_UID=$(id -u "$USER_NAME" 2>/dev/null || echo "")

# Launch it as the person sitting in front of the Mac, not as root.
# On first run the app registers its own login item.
if [ -n "$USER_UID" ] && [ "$USER_NAME" != "root" ]; then
    launchctl asuser "$USER_UID" open -a /Applications/AutoShutdown.app 2>/dev/null || true
fi
exit 0
SCRIPTEOF

chmod +x "$SCRIPTS/preinstall" "$SCRIPTS/postinstall"

# --- Build the package ------------------------------------------------------

echo "==> Building component package"
pkgbuild \
    --root "$PKGROOT" \
    --identifier "$LABEL" \
    --version "$VERSION" \
    --scripts "$SCRIPTS" \
    --install-location / \
    "$BUILD/component.pkg"

cat > "$BUILD/distribution.xml" <<DISTEOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>AutoShutdown</title>
    <welcome file="welcome.html" mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="never" require-scripts="true" hostArchitectures="arm64,x86_64"/>
    <domains enable_localSystem="true" enable_anywhere="false" enable_currentUserHome="false"/>
    <choices-outline>
        <line choice="default">
            <line choice="$LABEL"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$LABEL" visible="false">
        <pkg-ref id="$LABEL"/>
    </choice>
    <pkg-ref id="$LABEL" version="$VERSION" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
DISTEOF

echo "==> Building installer"
rm -f "$OUT"
if [ -n "$DEVELOPER_ID_INSTALLER" ]; then
    echo "    Signing installer as: $DEVELOPER_ID_INSTALLER"
    productbuild \
        --distribution "$BUILD/distribution.xml" \
        --package-path "$BUILD" \
        --resources "$DIR/pkg/Resources" \
        --sign "$DEVELOPER_ID_INSTALLER" \
        "$OUT"
else
    echo "!!  No Developer ID Installer identity found; producing an unsigned package."
    productbuild \
        --distribution "$BUILD/distribution.xml" \
        --package-path "$BUILD" \
        --resources "$DIR/pkg/Resources" \
        "$OUT"
fi

# --- Notarise ---------------------------------------------------------------

if [ "$SKIP_NOTARIZE" = "1" ]; then
    echo "==> Skipping notarisation (SKIP_NOTARIZE=1)"
elif [ -z "$DEVELOPER_ID_INSTALLER" ]; then
    echo "==> Skipping notarisation: the package is not signed."
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
echo "Installer ready: $OUT"
