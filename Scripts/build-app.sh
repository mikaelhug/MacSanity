#!/bin/bash
#
# Build MacSanity with SwiftPM and assemble a runnable .app bundle.
#
# Usage:
#   Scripts/build-app.sh [debug|release]   (default: release)
#
# Produces: build/MacSanity.app  (ad-hoc signed for local use)
#
# For distribution, replace the ad-hoc signature with a Developer ID identity and
# enable the hardened runtime — see README.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP_NAME="MacSanity"
BUNDLE_ID="com.macsanity.app"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
	echo "error: built binary not found at $BIN" >&2
	exit 1
fi

APP="$ROOT/build/$APP_NAME.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Stamp the version from $MACSANITY_VERSION (CI passes the git tag) so the bundle
# reports its real version and "Check for Updates" compares correctly. Falls back
# to the latest local git tag, else leaves the Info.plist default.
VERSION="${MACSANITY_VERSION:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)}"
VERSION="${VERSION#v}"
if [[ -n "$VERSION" ]]; then
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
	echo "==> Version $VERSION"
fi

# Sign with $MACSANITY_SIGN_IDENTITY when set (a stable identity keeps the
# Accessibility grant across rebuilds/upgrades); otherwise ad-hoc for quick local
# use. See Scripts/make-signing-cert.sh.
IDENTITY="${MACSANITY_SIGN_IDENTITY:-}"
if [[ -n "$IDENTITY" ]]; then
	echo "==> Code signing with identity: $IDENTITY"
	codesign --force --sign "$IDENTITY" \
		--identifier "$BUNDLE_ID" \
		--entitlements "$ROOT/Resources/MacSanity.entitlements" \
		--timestamp=none \
		"$APP"
else
	echo "==> Code signing (ad-hoc)"
	codesign --force --sign - \
		--identifier "$BUNDLE_ID" \
		--entitlements "$ROOT/Resources/MacSanity.entitlements" \
		"$APP"
fi

echo "==> Verifying signature"
codesign --verify --verbose=2 "$APP"

echo "==> Done: $APP"
