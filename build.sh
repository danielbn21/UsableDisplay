#!/bin/bash
# Requires Xcode command line tools: xcode-select --install
set -e
cd "$(dirname "$0")"
APP=UsableDisplay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -import-objc-header Bridging.h main.swift \
  -o "$APP/Contents/MacOS/UsableDisplay"
cp Info.plist "$APP/Contents/Info.plist"

# App icon (.icns generated from AppIcon-1024.png) and menu bar icon
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp MenuIcon.png "$APP/Contents/Resources/MenuIcon.png"

codesign --force --sign - "$APP"
echo "Built $APP  ->  open it with:  open $APP"
