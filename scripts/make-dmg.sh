#!/bin/sh
# Builds a universal release of Claude Ring and packs it into a DMG for
# installing on other Macs: build/dist/ClaudeRing-<version>.dmg
#
# The DMG window shows a background picture with an arrow from the app to
# "Programme" and the steps for the first launch. dmgbuild writes the window
# layout directly, without Finder, so this also runs headless in CI; it is
# installed into build/venv as pinned in scripts/dmg-requirements.txt.
#
# The app is ad-hoc signed, not notarized. On another Mac, macOS asks once to
# allow it; the background picture shows how.
#
# VERSION and BUILD_NUMBER override the values from the Xcode project; the
# release workflow sets them from the tag and the run number. PYTHON picks the
# interpreter for dmgbuild (default python3, at least 3.10).
set -eu
cd "$(dirname "$0")/.."

BUILD_DIR=build/release
ART_DIR=build/dmg
VENV=build/venv
MOUNT=build/dmg-mount
DIST=build/dist
APP_NAME="Claude Ring.app"
VOLUME_NAME="Claude Ring"
# The update function only installs an app with this identifier.
BUNDLE_ID=eu.siekmann.ClaudeRing
REQUIREMENTS=scripts/dmg-requirements.txt
PYTHON=${PYTHON:-python3}

set -- ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO
[ -n "${VERSION:-}" ] && set -- "$@" MARKETING_VERSION="$VERSION"
[ -n "${BUILD_NUMBER:-}" ] && set -- "$@" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

echo "Baue Universal-Release (Apple Silicon und Intel) …"
xcodebuild -quiet \
  -project ClaudeRing.xcodeproj \
  -scheme ClaudeRing \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  "$@" \
  build

BUILT_APP="$BUILD_DIR/Build/Products/Release/ClaudeRing.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT_APP/Contents/Info.plist")
DMG="$DIST/ClaudeRing-$VERSION.dmg"

echo "Architekturen: $(lipo -archs "$BUILT_APP/Contents/MacOS/ClaudeRing")"
codesign --verify --deep --strict "$BUILT_APP"

# dmgbuild in its own venv; it stays until the pins or the interpreter change.
if ! cmp -s "$REQUIREMENTS" "$VENV/requirements.txt" ||
  [ "$("$VENV/bin/python" -V 2>&1)" != "$("$PYTHON" -V 2>&1)" ]; then
  echo "Richte dmgbuild ein …"
  rm -rf "$VENV"
  "$PYTHON" -m venv "$VENV"
  "$VENV/bin/python" -m pip install --quiet --disable-pip-version-check \
    --require-hashes --only-binary=:all: -r "$REQUIREMENTS"
  cp "$REQUIREMENTS" "$VENV/requirements.txt"
fi

# Background picture in 1x and 2x, combined into one TIFF for Finder.
echo "Zeichne den Hintergrund …"
rm -rf "$ART_DIR"
mkdir -p "$ART_DIR" "$DIST"
xcrun swift scripts/render-dmg-background.swift "$ART_DIR"
tiffutil -cathidpicheck "$ART_DIR/background.png" "$ART_DIR/background@2x.png" \
  -out "$ART_DIR/background.tiff"

echo "Packe das DMG …"
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s scripts/dmg-settings.py --detach-retries 10 \
  -D app="$BUILT_APP" \
  -D background="$ART_DIR/background.tiff" \
  -D icon="$BUILT_APP/Contents/Resources/AppIcon.icns" \
  "$VOLUME_NAME" "$DMG"

# Opens the DMG with the update function's hdiutil flags and checks what it
# relies on, so a release fails here instead of in the app.
echo "Prüfe das DMG …"
rm -rf "$MOUNT"
mkdir -p "$MOUNT"
hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" >/dev/null
trap 'hdiutil detach -quiet "$MOUNT" || hdiutil detach -quiet -force "$MOUNT"' EXIT
fail() {
  echo "Fehler im DMG: $*" >&2
  rm -f "$DMG"
  exit 1
}
MOUNTED_APP="$MOUNT/$APP_NAME"
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$MOUNTED_APP/Contents/Info.plist" 2>/dev/null || true; }
{ [ -d "$MOUNTED_APP" ] && [ ! -L "$MOUNTED_APP" ]; } || fail "„$APP_NAME“ fehlt."
[ "$(plist_value CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "Die Bundle-ID ist nicht $BUNDLE_ID."
[ "$(plist_value CFBundleShortVersionString)" = "$VERSION" ] || fail "Die Version ist nicht $VERSION."
codesign --verify --deep --strict "$MOUNTED_APP" || fail "Die Signatur ist ungültig."
[ "$(readlink "$MOUNT/Programme")" = /Applications ] || fail "„Programme“ zeigt nicht auf /Applications."
[ "$(ls "$MOUNT")" = "$(printf '%s\n%s' "$APP_NAME" Programme)" ] ||
  fail "Unerwartete Einträge: $(ls "$MOUNT" | tr '\n' ' ')"
for file in .DS_Store .background.tiff .VolumeIcon.icns; do
  [ -f "$MOUNT/$file" ] || fail "$file fehlt."
done
hdiutil detach -quiet "$MOUNT"
trap - EXIT
rmdir "$MOUNT"

hdiutil verify -quiet "$DMG"
echo "Fertig: $DMG ($(du -h "$DMG" | cut -f1))"
