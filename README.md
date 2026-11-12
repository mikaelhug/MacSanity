# MacSanity

A lean macOS menu-bar app that does four small things well:

1. **Reverse scrolling** — reverses the scroll direction of attached **mice** while
   leaving the **trackpad** scrolling natural.
2. **Keep Awake** — prevents your Mac from sleeping while it's on, optionally for a
   set duration.
3. **Safari back/forward buttons** — makes a mouse's back/forward side buttons
   navigate Safari (which ignores them natively), only while Safari is frontmost.
4. **External monitor brightness** — a hardware brightness slider in the menu for
   each connected monitor that supports **DDC/CI**, added and removed automatically
   as monitors come and go. Real backlight control only — never software dimming.

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
swift run DDCCheck        # run the DDC/CI packet encode/parse checks
```

## Permissions

- **Keep Awake** and **monitor brightness** need no permissions and work immediately.
- **Reverse Scrolling** and **Safari back/forward buttons** need one TCC
  permission: **Accessibility** (System Settings → Privacy & Security →
  Accessibility). These mouse event taps require only Accessibility — Input
  Monitoring gates *keyboard* monitoring, which this app never does.

  Turn either feature on from the menu and MacSanity prompts for it. Once granted,
  it starts automatically (and resumes by itself if the permission is later
  re-granted).

## External monitor brightness (DDC/CI)

MacSanity changes a monitor's **actual backlight** over DDC/CI — the same channel
the monitor's own buttons and on-screen menu control. There is no gamma, overlay
or any other software dimming, ever.

- **Automatic:** at launch, on plug/unplug, and after wake, each external display
  is asked for its current brightness (VCP `0x10`). Any monitor that answers gets a
  slider at the top of the menu, set to its real value. Monitors without DDC get
  nothing. Opening the menu re-reads the value, so changes made with the
  monitor's own buttons show up.
- **Write-only monitors:** a few monitors accept brightness commands but never
  answer reads. A DDC write gives no feedback, so MacSanity can't detect them on its
  own. They're listed under **Other Displays**, where **Enable Brightness Slider
  (Unverified)** adds a slider. Nothing is sent until you move it; if moving it
  does nothing, turn it off again.

**What works** (Apple Silicon): USB-C / Thunderbolt (DP Alt-mode), DisplayPort, and
the built-in HDMI port on most current Macs — provided DDC/CI is enabled in the
monitor's own OSD (often on by default).
**What doesn't:** DisplayLink adapters/docks, the built-in HDMI port of the M1 and
entry M2 Mac mini, most KVM switches, some MST hubs, and Apple displays (Studio
Display / Pro Display XDR use USB, not DDC). Intel Macs aren't supported.

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
| Safari nav buttons | An active tap on `otherMouseDown`/`Up`: while Safari is frontmost, side buttons 3/4 are swallowed and re-posted as ⌘← / ⌘→ (layout-independent). Other apps are untouched. |
| Monitor brightness | DDC/CI over I²C via the private `IOAVService` API on each external display's `DCPAVServiceProxy`, paired with its `CGDirectDisplayID` through CoreDisplay's `IODisplayLocation`. One actor per monitor on its own serial queue; slider moves are coalesced so only the newest value is written. No polling. |
| Launch at login | `SMAppService.mainApp`. |
| Hidden hot path cost | The scroll callback is a C function pointer over plain scalars — no per-event `NSEvent`, no `UserDefaults` reads, no allocations. The menu UI is never on the hot path. |

### Project layout

```
Sources/
  CMacSanitySPI/   C shim: MSReverseScroll, DDC I2C transport + the private SPIs
  MacSanityCore/   Pure logic (ScrollClassifier, DDCPacket) — unit-checkable, no UI
  MacSanity/       The app: AppModel, AppKit status menu, Brightness (DDC),
                   ScrollTap, SafariNav, KeepAwake, Permissions, Defaults,
                   LaunchAtLogin, UpdateChecker
  ClassifierCheck/ Standalone classifier checks (stands in for XCTest)
  DDCCheck/        Standalone DDC packet encode/parse checks
```

`AppModel` (`@MainActor @Observable`) is the single source of truth and the only
writer of side effects; the AppKit status menu (`StatusMenuController`) reads it via
Observation and feature controllers are driven by it.

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
release. Ad-hoc signatures change on every build, so the Accessibility grant must
be re-approved after each rebuild — see below to make it persist.

## Keeping the Accessibility grant across upgrades

macOS ties the Accessibility grant to the app's **code signature**, and an ad-hoc
signature changes on every build — so each rebuild or auto-update looks like a new
app and you have to re-grant. Signing every build (local **and** CI) with one
stable, self-signed certificate keeps the grant:

```sh
# 1. Create the cert once (also exports a base64 .p12 for CI)
Scripts/make-signing-cert.sh

# 2. Sign local builds with it
export MACSANITY_SIGN_IDENTITY="MacSanity Self-Signed"
Scripts/build-app.sh release

# 3. So released / auto-updated builds keep the grant too, add the secrets the
#    script prints (the workflow then signs CI builds with the same cert):
gh secret set MACSANITY_CERT_P12 < ~/macsanity-signing-cert.b64
gh secret set MACSANITY_CERT_PASSWORD --body macsanity
rm ~/macsanity-signing-cert.b64
```

Grant Accessibility once to a build signed this way; every later build with the
same cert — including auto-updates — keeps it. The cert isn't notarized, so
Gatekeeper still warns on first download; for public distribution use a Developer
ID identity (same `MACSANITY_SIGN_IDENTITY` mechanism) and notarize.
