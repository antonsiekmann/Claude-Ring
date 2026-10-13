#!/bin/sh
# Builds a release version of Claude Ring and installs it to /Applications.
# Only an installed copy can open at login; a build in DerivedData moves on
# every build.
set -eu
cd "$(dirname "$0")/.."

BUILD_DIR=build/release
TARGET="/Applications/Claude Ring.app"

echo "Baue Release-Version …"
xcodebuild -quiet \
  -project ClaudeRing.xcodeproj \
  -scheme ClaudeRing \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  build

# Quit a running copy, from /Applications or from Xcode.
pkill -x ClaudeRing 2>/dev/null || true
sleep 1

ditto "$BUILD_DIR/Build/Products/Release/ClaudeRing.app" "$TARGET"
echo "Installiert: $TARGET"
open "$TARGET"
