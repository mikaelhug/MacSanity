# MacSanity

A lean macOS menu-bar app that does two things well:

1. **Reverse scrolling** — reverses the scroll direction of attached **mice** while
   leaving the **trackpad** scrolling natural.
2. **Keep Awake** — prevents your Mac from sleeping while it's on, optionally for a
   set duration.

Written in modern Swift, it's a single ~16 MB agent — no Dock icon, and no CPU
use when idle.

## Requirements

- macOS 26 (Tahoe) or later
- Swift 6.2 toolchain (Xcode **or** the Command Line Tools — `xcode-select --install`)

## Build & run

```sh
# Build a runnable, ad-hoc-signed MacSanity.app into ./build
Scripts/build-app.sh release

# Launch it
open build/MacSanity.app
```

The icon appears in the menu bar (no Dock icon — it's an `LSUIElement` agent).

For day-to-day development you can also just use SwiftPM directly:

```sh
swift build              # compile everything
swift run ClassifierCheck # run the mouse-vs-trackpad classifier checks
```

## Permissions

- **Keep Awake** needs no permissions and works immediately.
- **Reverse Scrolling** needs one TCC permission: **Accessibility** (System
  Settings → Privacy & Security → Accessibility). Mouse/scroll event taps require
  only Accessibility — Input Monitoring gates *keyboard* monitoring, which this
  app never does.

  Turn on *Reverse Mouse* (or *Reverse Trackpad*) from the menu and MacSanity
  prompts for it. Once granted, reversal starts automatically (and resumes by
  itself if the permission is later re-granted).

## Updates

**Check for Updates…** in the menu queries the latest GitHub Release and compares
its tag to the running app's version. If a newer one exists, **Update & Relaunch**
downloads the `.zip`, swaps the new app over the running one (via a detached
helper that waits for the app to quit), and relaunches it. If the app lives
somewhere it can't write to, it falls back to revealing the download for a manual
drag. It's manual — triggered only from the menu, no background polling.

Releases are produced by pushing a `v#.#.#` tag (see the build workflow); the
build stamps `CFBundleShortVersionString` from the tag, so the version comparison
stays honest. For the updater to offer an update, the released tag must be higher
than the version of the build you're running.

## How it works

| Concern | Mechanism |
|---|---|
| Scroll reversal | Two session-level `CGEventTap`s — a passive gesture tap counts trackpad touches, an active scroll tap rewrites the deltas. |
| Mouse vs. trackpad | A heuristic (`ScrollClassifier`): non-continuous → mouse; 2+ recent fingers → trackpad; otherwise momentum/timing and last-known source. |
| Reversal write | `MSReverseScroll` (C) flips the CGEvent `Delta`/`FixedPt`/`Point` axes (Delta first, so macOS recomputes the rest) **and** the underlying `IOHIDEvent`. |
| Keep Awake | A single held `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep)`, released on toggle-off or timer expiry. |
| Launch at login | `SMAppService.mainApp`. |
| Hidden hot path cost | The scroll callback is a C function pointer over plain scalars — no per-event `NSEvent`, no `UserDefaults` reads, no allocations. SwiftUI is never on the hot path. |

### Project layout

```
Sources/
  CMacSanitySPI/   C shim: MSReverseScroll + the private IOHID/CGEvent SPIs
  MacSanityCore/   Pure logic (ScrollClassifier) — unit-checkable, no UI
  MacSanity/       The app: AppModel, MenuBarExtra UI, ScrollTap, KeepAwake,
                   Permissions, Defaults, LaunchAtLogin, UpdateChecker
  ClassifierCheck/ Standalone classifier checks (stands in for XCTest)
```

`AppModel` (`@MainActor @Observable`) is the single source of truth and the only
writer of side effects; the SwiftUI scenes read it and feature controllers are
driven by it.

## Distribution

MacSanity is **not sandboxed** (a session-level active event tap and the IOHID
SPIs are incompatible with the App Sandbox), so it ships outside the Mac App
Store, Developer-ID-signed and notarized:

```sh
# 1. Sign with a Developer ID Application identity + hardened runtime
codesign --force --options runtime \
  --sign "Developer ID Application: YOUR NAME (TEAMID)" \
  --entitlements Resources/MacSanity.entitlements \
  build/MacSanity.app

# 2. Notarize
ditto -c -k --keepParent build/MacSanity.app build/MacSanity.zip
xcrun notarytool submit build/MacSanity.zip --keychain-profile "AC_PASSWORD" --wait

# 3. Staple
xcrun stapler staple build/MacSanity.app
```

`Scripts/build-app.sh` ad-hoc signs for local use; swap in the steps above for
release. (Ad-hoc signatures change on every build, so the TCC permission grants
must be re-approved after each local rebuild — expected during development.)
