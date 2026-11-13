#!/bin/sh
# Prints the section of CHANGELOG.md for one version, without its heading:
#
#   scripts/release-notes.sh 1.2.0
#
# The release job uses it as the text of the release page. Fails when the
# section is missing or empty, so no release goes out without notes.
set -eu
cd "$(dirname "$0")/.."

VERSION=${1:?Usage: scripts/release-notes.sh <version>}
NOTES=$(awk -v version="$VERSION" '
  /^## / { if (found) exit; found = ($2 == version); next }
  found
' CHANGELOG.md)

if ! printf '%s' "$NOTES" | grep -q '[^[:space:]]'; then
  echo "CHANGELOG.md hat keinen Abschnitt „## ${VERSION}“." >&2
  exit 1
fi
printf '%s\n' "$NOTES" | sed -e '/./,$!d'
