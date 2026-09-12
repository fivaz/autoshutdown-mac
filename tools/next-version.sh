#!/bin/bash
# Works out the next version from the conventional commits since the last release,
# the way semantic-release does for npm packages.
#
#   breaking change  ->  major   2.3.1 becomes 3.0.0
#   feat             ->  minor   2.3.1 becomes 2.4.0
#   fix or perf      ->  patch   2.3.1 becomes 2.3.2
#   anything else    ->  no release
#
# A breaking change is a "!" before the colon, as in feat!: or feat(lock)!:, or a
# BREAKING CHANGE line in the commit body.
#
# Prints key=value lines, which is exactly the shape a GitHub Actions step output
# wants, so CI can do: ./tools/next-version.sh >> "$GITHUB_OUTPUT"
set -euo pipefail

LAST="$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || true)"

# No tags yet: this is the first release, and the version in Info.plist seeds it.
if [ -z "$LAST" ]; then
    SEED="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist 2>/dev/null \
        || python3 -c "import plistlib;print(plistlib.load(open('Info.plist','rb'))['CFBundleShortVersionString'])" \
        2>/dev/null || echo 1.0)"
    case "$SEED" in
        *.*.*) ;;               # already x.y.z
        *.*)   SEED="$SEED.0" ;;
        *)     SEED="$SEED.0.0" ;;
    esac
    echo "version=$SEED"
    echo "previous="
    echo "bump=initial"
    echo "release=true"
    exit 0
fi

SUBJECTS="$(git log --no-merges --pretty=format:'%s' "$LAST..HEAD" || true)"
BODIES="$(git log --no-merges --pretty=format:'%b' "$LAST..HEAD" || true)"

BUMP=none
if printf '%s\n' "$SUBJECTS" | grep -qE '^[a-z]+(\([^)]+\))?!:'; then
    BUMP=major
elif printf '%s\n' "$BODIES" | grep -q 'BREAKING CHANGE'; then
    BUMP=major
elif printf '%s\n' "$SUBJECTS" | grep -qE '^feat(\([^)]+\))?:'; then
    BUMP=minor
elif printf '%s\n' "$SUBJECTS" | grep -qE '^(fix|perf)(\([^)]+\))?:'; then
    BUMP=patch
fi

if [ "$BUMP" = "none" ]; then
    echo "version="
    echo "previous=$LAST"
    echo "bump=none"
    echo "release=false"
    exit 0
fi

CURRENT="${LAST#v}"
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
MAJOR="${MAJOR:-0}"; MINOR="${MINOR:-0}"; PATCH="${PATCH:-0}"

case "$BUMP" in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
esac

echo "version=$MAJOR.$MINOR.$PATCH"
echo "previous=$LAST"
echo "bump=$BUMP"
echo "release=true"
