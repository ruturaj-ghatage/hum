#!/bin/bash
# Builds Hum.app into ./build. Pass "install" to also copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Hum.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Hum "$APP/Contents/MacOS/Hum"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier com.ruturaj.hum "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/Hum.app
    cp -R "$APP" ~/Applications/
    echo "Installed to ~/Applications/Hum.app"
fi
