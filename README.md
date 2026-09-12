# AutoShutdown

A menu bar app that shuts down this Mac at the same time every day, with warnings you cannot talk your way out of.

It is a self-contained app bundle. Dragging it to Applications is the whole installation: it writes nothing outside itself, registers its own login item, and leaves nothing behind when you drag it to the Trash.

## Behaviour

- Counts down to a configurable daily shutdown time (default 23:00).
- Warns at **15 minutes**, **5 minutes**, **1 minute** and **30 seconds** with a floating panel and a beep.
- The 15, 5 and 1 minute warnings offer **Add 15 minutes**, usable **once per calendar day**. After that the remaining time can only shrink.
- Changing the shutdown time to an *earlier* moment applies immediately. Changing it to a *later* moment only takes effect the next day, so settings cannot be used to buy time.
- If the Mac was asleep past the deadline (within 2 hours), it wakes into a 60 second countdown and then shuts down. Longer than that and the day is skipped.
- Shutdown is performed with `System Events` "shut down", the same path as the Apple menu, so apps get a chance to quit.

### Turning the Mac back on

Booting again after an automatic shutdown is expected and nothing tries to stop it. The day's deadline is recorded and flushed to disk just before the machine goes down, so if you power back on at 23:05 the app simply shows tomorrow's countdown. It will not shut you down a second time that evening.

The app is a discipline tool, not a kill switch. Quitting it from its menu stops it until your next login.

## Commitment lock

In Settings you can pick a date and hour to lock the settings until, for example 3 November at 18:00. While the lock holds:

- The shutdown time can only be moved **earlier**, never later. "Earlier" is judged on the next time each candidate actually comes round, so at 20:00 a move from 23:00 to 00:30 counts as later and is refused.
- The lock date can only be pushed **further out**, never pulled back.
- **Enabled** and **Start at login** are both greyed out, so the app cannot be switched off and cannot be stopped from coming back tomorrow.
- The daily +15 minute extension still works. That allowance is unaffected by the lock.

Locking asks for confirmation first, because it cannot be undone from inside the app. It is stored in `defaults`, so it is escapable from Terminal by someone determined. That is deliberate: this is a commitment device, not security.

## Build

```sh
./build.sh          # produces build/AutoShutdown.app
open build/AutoShutdown.app
```

Requires the Xcode command line tools (`xcode-select --install`).

## Disk image

```sh
cp signing.env.example signing.env    # once, fill in your Developer ID
./make-dmg.sh                         # produces build/AutoShutdown-1.0.dmg
```

Opening the image gives you the app next to an Applications shortcut with an arrow between them. Drag it across, open it once, and it registers itself to start at every login. Settings opens by itself on that first launch.

`make-dmg.sh` degrades rather than failing:

| Available | Result |
| --- | --- |
| Developer ID + notary credentials | Signed, notarised, stapled. Opens cleanly on any Mac. |
| Developer ID only | Signed image, notarisation skipped with instructions printed. |
| Neither | Unsigned image. Works locally; other Macs will warn. |

The image carries the app's icon in two places: the mounted volume, through a `.VolumeIcon.icns` at its root, and the `.dmg` file itself, set with `tools/seticon.swift` after signing and stapling. The file icon lives in the resource fork, which survives copying and Time Machine but is stripped by most uploads and by zipping, so a `.dmg` downloaded from a web server shows the generic icon again. Nothing to be done about that; it is how the format works.

`SKIP_NOTARIZE=1` signs without the round trip to Apple. `SKIP_ICON=1` leaves the generic disk image icon. `PLAIN_DMG=1` skips the Finder window styling, which is worth trying if the layout step is refused: arranging icons means scripting Finder, and macOS may ask for permission or simply decline in a headless session. The image works either way, it just opens with the default layout.

Notary credentials are stored once:

```sh
xcrun notarytool store-credentials autoshutdown-notary \
    --apple-id you@example.com --team-id TEAMID --password APP-SPECIFIC-PASSWORD
```

## Releasing

There is nothing to tag and no version to bump. Push to `main` and the commit messages decide what happens, the way `semantic-release` works for npm packages.

| Commits since the last release | Result |
| --- | --- |
| a `!` marker or a `BREAKING CHANGE` body | major, 1.4.2 becomes 2.0.0 |
| any `feat:` | minor, 1.4.2 becomes 1.5.0 |
| any `fix:` or `perf:` | patch, 1.4.2 becomes 1.4.3 |
| only `docs:`, `chore:`, `refactor:`, `test:`, `style:`, `ci:` | no release |

A releasable push builds, signs, notarises, creates the tag, and publishes a GitHub release with the disk image attached. A push of documentation or tidying finishes in seconds on a free Linux runner and says in the job summary why it stopped, so the expensive macOS runner only starts when there is something to ship.

`tools/next-version.sh` does the arithmetic and can be run locally to see what the next push would produce:

```sh
./tools/next-version.sh
version=1.5.0
previous=v1.4.2
bump=minor
release=true
```

The tag is the source of truth for the version. `CFBundleShortVersionString` in `Info.plist` is only a placeholder for local builds; CI overwrites it before compiling, so there is no version to keep in sync by hand and no bot commit landing on `main`.

### One-time setup

Five repository secrets, under Settings, Secrets and variables, Actions:

| Secret | Where it comes from |
| --- | --- |
| `DEVELOPER_ID_P12` | base64 of your exported certificate, see below |
| `DEVELOPER_ID_P12_PASSWORD` | the password you chose when exporting |
| `APPLE_ID` | the Apple ID holding the developer membership |
| `APPLE_TEAM_ID` | ten characters, the part in brackets in your certificate name |
| `APPLE_APP_PASSWORD` | app-specific password from appleid.apple.com |

Exporting the certificate: open Keychain Access, find **Developer ID Application**, expand it with the triangle so both the certificate and its private key are selected, right-click, Export 2 items, save as `.p12` with a password. Then:

```sh
base64 -i certificate.p12 | pbcopy
```

and paste that as `DEVELOPER_ID_P12`. Delete the `.p12` afterwards. The private key now exists in two places, so treat the secret accordingly.

### The window layout in CI

GitHub's macOS runners have no desktop, so Finder cannot be scripted there and the pretty window cannot be recorded. Instead it is recorded once on your own Mac and committed:

```sh
FORCE_STYLE=1 ./make-dmg.sh     # records the layout
git add Resources/dmg-DS_Store
git commit -m "build: commit the disk image window layout"
```

Every later build, local or CI, reuses that file. The workflow warns in the job summary if it is missing. Note that this commit is a `build:` one, so on its own it releases nothing.

### Release notes

`tools/release-notes.sh` groups your conventional commits under 💥 Breaking changes, ✨ Features, 🐛 Fixes, ⚡ Performance, ♻️ Internal changes, 📝 Documentation, 📦 Build and packaging and 🧹 Housekeeping. Each line carries its scope in bold and links to the commit. Commits that follow no convention still appear, under 📋 Other, so nothing disappears quietly. Installation instructions and a compare link to the previous release are appended.

Run it by hand to preview what the next release will say:

```sh
./tools/release-notes.sh HEAD v1.5.0
```

## Other ways in and out

```sh
./install.sh                    # build, copy to /Applications, launch
./make-pkg.sh                   # wizard-style .pkg, for fleet deployment
./uninstall.sh                  # remove everything, settings included
./uninstall.sh --keep-settings  # remove the app but keep the time and any lock
```

Use `--keep-settings` when upgrading. A plain uninstall erases the commitment lock along with everything else, which is the one escape hatch the app deliberately leaves open.

## Permission to shut down

The app is signed with the hardened runtime, so telling System Events to shut down requires the Automation permission. The app asks for it at launch rather than at 23:00, when a silent failure would be worst. If the permission is missing the menu shows a warning that opens the right pane of System Settings.

## Login item

On macOS 13 and later this is `SMAppService`, which registers the bundle itself and appears in System Settings under General > Login Items. On macOS 12 it falls back to a LaunchAgent in your own Library.

Older versions of this project installed a LaunchAgent from a script or a package. If one is still on disk the app detects it, declines to register itself on top of it, and says so in its menu, so you can never end up with two countdowns running at once. `./uninstall.sh` clears it.

## Settings

Stored in `defaults` domain `com.fivaz.autoshutdown`:

| Key | Meaning |
| --- | --- |
| `shutdownHour`, `shutdownMinute` | Configured daily time |
| `enabled` | Master switch |
| `extensionUsedDay` | Day on which the single +15 was spent |
| `overrideDay`, `overrideTime` | Today's effective deadline when it differs from the configured time |
| `handledDay` | Last day whose deadline was dealt with, so a reboot does not re-trigger it |
| `lockUntil` | Commitment lock expiry, if one is set |
| `firstRunDone` | Whether the login item has been registered once |

## Testing without powering off

```sh
AUTOSHUTDOWN_DRY_RUN=1 ./build/AutoShutdown.app/Contents/MacOS/AutoShutdown
```

Set the shutdown time a few minutes ahead and the full warning sequence runs, ending with a panel instead of a shutdown.

## Layout

```
Sources/main.swift        scheduling, menu bar item, lock rules, shutdown
Sources/UI.swift          warning panel and settings window
Sources/LoginItem.swift   login item registration and legacy detection
Info.plist                bundle metadata (LSUIElement: no Dock icon)
AutoShutdown.entitlements Apple Events entitlement for the hardened runtime
Resources/AppIcon.iconset app icon, assembled into .icns at build time
Resources/dmg-background  disk image window artwork
tools/make_assets.py      regenerates the icon and the artwork
build.sh                  compiles the .app
make-dmg.sh               signed + notarised drag-and-drop disk image
make-pkg.sh               signed + notarised installer package
signing.env.example       template for your Developer ID and notary profile
install.sh                build and install locally, no image
uninstall.sh              removes everything
```
