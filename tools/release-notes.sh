#!/bin/bash
# Turns conventional commits into release notes.
#
#   ./tools/release-notes.sh                    notes for the newest tag
#   ./tools/release-notes.sh v1.2.0             notes for a specific tag
#   ./tools/release-notes.sh HEAD v1.2.0        notes up to HEAD, labelled v1.2.0
#
# The second form is what CI uses: the tag does not exist yet at the moment the
# notes are written, so the range ends at HEAD while the links use the new name.
#
# Commits are grouped by type. Anything that is not a recognised conventional
# commit is listed under "Other", so nothing silently disappears from the notes.
set -euo pipefail

TAG="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo HEAD)}"
NAME="${2:-$TAG}"
PREV="$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || true)"

if [ -n "$PREV" ]; then
    RANGE="$PREV..$TAG"
else
    RANGE="$TAG"
fi

REPO="$(git remote get-url origin 2>/dev/null \
    | sed -e 's/\.git$//' -e 's#git@github.com:#https://github.com/#')"

# subject<TAB>hash, oldest first so the notes read in the order work happened.
COMMITS="$(git log --no-merges --reverse --pretty=format:'%s%x09%h' "$RANGE")"

emit() {
    local pattern="$1" title="$2" lines
    lines="$(printf '%s\n' "$COMMITS" | grep -E "$pattern" || true)"
    [ -z "$lines" ] && return 0

    printf '### %s\n\n' "$title"
    while IFS=$'\t' read -r subject hash; do
        [ -z "$subject" ] && continue
        local text scope
        text="$(printf '%s' "$subject" | sed -E 's/^[a-z]+(\([^)]+\))?!?: *//')"
        scope="$(printf '%s' "$subject" | sed -nE 's/^[a-z]+\(([^)]+)\).*/\1/p')"
        if [ -n "$REPO" ]; then
            text="$text ([\`$hash\`]($REPO/commit/$hash))"
        fi
        if [ -n "$scope" ]; then
            printf -- '- **%s:** %s\n' "$scope" "$text"
        else
            printf -- '- %s\n' "$text"
        fi
    done <<< "$lines"
    printf '\n'
}

# Anything marked breaking goes first, since it is what a reader needs most.
BREAKING="$(printf '%s\n' "$COMMITS" | grep -E '^[a-z]+(\([^)]+\))?!:' || true)"
if [ -n "$BREAKING" ]; then
    printf '### 💥 Breaking changes\n\n'
    while IFS=$'\t' read -r subject hash; do
        [ -z "$subject" ] && continue
        printf -- '- %s\n' "$(printf '%s' "$subject" | sed -E 's/^[a-z]+(\([^)]+\))?!: *//')"
    done <<< "$BREAKING"
    printf '\n'
fi

emit '^feat(\([^)]+\))?!?:'      '✨ Features'
emit '^fix(\([^)]+\))?!?:'       '🐛 Fixes'
emit '^perf(\([^)]+\))?!?:'      '⚡ Performance'
emit '^refactor(\([^)]+\))?!?:'  '♻️ Internal changes'
emit '^docs(\([^)]+\))?!?:'      '📝 Documentation'
emit '^build(\([^)]+\))?!?:'     '📦 Build and packaging'
emit '^(chore|ci|style|test)(\([^)]+\))?!?:' '🧹 Housekeeping'

# Commits that follow no convention at all.
OTHER="$(printf '%s\n' "$COMMITS" \
    | grep -vE '^(feat|fix|perf|refactor|docs|build|chore|ci|style|test)(\([^)]+\))?!?:' || true)"
if [ -n "$OTHER" ]; then
    printf '### 📋 Other\n\n'
    while IFS=$'\t' read -r subject hash; do
        [ -z "$subject" ] && continue
        printf -- '- %s\n' "$subject"
    done <<< "$OTHER"
    printf '\n'
fi

cat <<'INSTALL'
### ⬇️ Installing

1. Download the `.dmg` below and open it.
2. Drag **AutoShutdown** onto the Applications folder.
3. Open it once from Applications. It registers itself to start at every login,
   and its settings window opens so you can choose your shutdown time.

The app is signed and notarised by Apple, so no security warning appears. It
lives in the menu bar and has no Dock icon.
INSTALL

if [ -n "$PREV" ] && [ -n "$REPO" ]; then
    printf '\n**Full changelog:** %s/compare/%s...%s\n' "$REPO" "$PREV" "$NAME"
fi
