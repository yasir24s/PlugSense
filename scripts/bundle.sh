#!/bin/bash
# Builds dist/PlugSense.app (a menu bar app: LSUIElement, no Dock icon) and dist/plugsense (the
# command-line tool) as universal binaries, ad-hoc signed. PlugSense reads only the I/O Registry,
# IOPowerSources and, for iPhones and iPads, lockdown: it needs no entitlements or privacy grants.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${VERSION:-0.1.0}"

arch=(-c release --arch arm64 --arch x86_64)
swift build "${arch[@]}" --product PlugSenseApp
swift build "${arch[@]}" --product plugsense
products=$(swift build "${arch[@]}" --show-bin-path)   # where it lands differs between SwiftPM versions

app=dist/PlugSense.app
rm -rf "$app" dist/plugsense
mkdir -p "$app/Contents/MacOS"
cp "$products/PlugSenseApp" "$app/Contents/MacOS/PlugSense"
cp "$products/plugsense" dist/plugsense
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>PlugSense</string>
    <key>CFBundleIdentifier</key>          <string>com.plugsense.app</string>
    <key>CFBundleExecutable</key>          <string>PlugSense</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>$version</string>
    <key>CFBundleVersion</key>             <string>$version</string>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
codesign --force --sign - dist/plugsense
echo "built $app and dist/plugsense: $version, $(lipo -archs dist/plugsense)"
