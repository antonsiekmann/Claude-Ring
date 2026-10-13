#!/bin/sh
# Builds a universal release of Claude Ring and packs it into a DMG for
# installing on other Macs: build/dist/ClaudeRing-<version>.dmg
#
# The app is ad-hoc signed, not notarized. On another Mac, macOS asks once to
# allow it (see the instructions file in the DMG).
#
# VERSION and BUILD_NUMBER override the values from the Xcode project; the
# release workflow sets them from the tag and the run number.
set -eu
cd "$(dirname "$0")/.."

BUILD_DIR=build/release
STAGING=build/dmg-staging
MOUNT=build/dmg-mount
DIST=build/dist
APP_NAME="Claude Ring.app"
VOLUME_NAME="Claude Ring"

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

# Staging folder: the app, a link to /Applications and the instructions.
rm -rf "$STAGING" "$MOUNT"
mkdir -p "$STAGING" "$DIST"
ditto "$BUILT_APP" "$STAGING/$APP_NAME"
ln -s /Applications "$STAGING/Programme"
cp "$BUILT_APP/Contents/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
cat > "$STAGING/Bitte zuerst lesen.txt" <<TEXT
Claude Ring $VERSION

Installation
1. „Claude Ring“ auf „Programme“ ziehen.
2. „Claude Ring“ im Ordner „Programme“ öffnen.

Beim ersten Öffnen meldet macOS, dass Apple die App nicht überprüfen kann.
Das liegt daran, dass sie nicht bei Apple notarisiert ist. So gibst du sie
einmalig frei:
   Systemeinstellungen ▸ Datenschutz & Sicherheit ▸ ganz unten bei
   „Claude Ring“ auf „Dennoch öffnen“ klicken und bestätigen.
Alternativ im Terminal:
   xattr -dr com.apple.quarantine "/Applications/Claude Ring.app"

Voraussetzungen
- macOS 26 oder neuer
- Claude Code installiert und angemeldet (einmal „claude“ im Terminal starten)

Claude-Code-Statuspunkt
Rechtsklick auf das Symbol in der Menüleiste ▸ Einstellungen … ▸ Claude Code ▸
Einrichten. Die App sichert ~/.claude/settings.json vorher und lässt andere
Hooks unverändert.

Entfernen
Einstellungen … ▸ Allgemein ▸ „Claude Ring vollständig entfernen“ nimmt alles
wieder heraus, was die App angelegt hat, auch die Hooks, und legt die App in
den Papierkorb.

Claude Ring ist ein inoffizielles Projekt und nicht mit Anthropic verbunden.
Claude und Claude Code sind Marken von Anthropic.
Quellcode und Lizenz (GPL-3.0): https://github.com/antonsiekmann/Claude-Ring
TEXT

# Writable image first, so the volume can get its custom icon.
rm -f "$DMG" build/dmg-temp.dmg
hdiutil create -quiet -srcfolder "$STAGING" -volname "$VOLUME_NAME" -fs HFS+ -format UDRW build/dmg-temp.dmg
mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MOUNT" build/dmg-temp.dmg
SetFile -a C "$MOUNT"
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet build/dmg-temp.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f build/dmg-temp.dmg
rm -rf "$STAGING" "$MOUNT"

hdiutil verify -quiet "$DMG"
echo "Fertig: $DMG ($(du -h "$DMG" | cut -f1))"
