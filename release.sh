#!/bin/bash
# Builds Hum.app, zips it, and publishes a GitHub Release.
# Usage: ./release.sh 0.2.0 ["Release notes"]
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?Usage: ./release.sh <version> [notes]}"
NOTES="${2:-}"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
./build.sh

rm -f build/Hum.zip
ditto -c -k --keepParent build/Hum.app build/Hum.zip

if [[ -n $(git status --porcelain Resources/Info.plist) ]]; then
    git commit -m "Release v$VERSION" Resources/Info.plist
    git push
fi

gh release create "v$VERSION" build/Hum.zip --title "Hum v$VERSION" --notes "$NOTES"
