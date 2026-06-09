# MacSanity

A lean macOS menu-bar app that does two things well:

1. **Reverse scrolling** — reverses the scroll direction of attached **mice** while
   leaving the **trackpad** scrolling natural.
2. **Keep Awake** — prevents your Mac from sleeping while it's on, optionally for a
   set duration.

It's a modern Swift rewrite that replaces two aging Objective-C utilities
(Scroll Reverser and Caffeine) with a single ~17 MB agent.

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
- **Reverse Scrolling** needs two TCC permissions (System Settings → Privacy & Security):
  - **Accessibility** — to modify scroll events.
  - **Input Monitoring** — to observe input at the session level.

  Turn on *Reverse Scrolling* from the menu and MacSanity will prompt for, and
  deep-link you to, whatever is missing. Once both are granted, reversal starts
  automatically (and resumes by itself if a permission is later re-granted).

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
                   Permissions, Defaults, LaunchAtLogin, Settings
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

## Credits

The scroll-reversal mechanism and the private SPI declarations are derived from
[Scroll Reverser](https://pilotmoon.com/scrollreverser/) (Apache-2.0); the
keep-awake approach is inspired by Caffeine. MacSanity keeps only the core of
each, rebuilt in modern Swift.
