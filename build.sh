#!/bin/bash
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/MemBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MemBar "$APP/Contents/MacOS/MemBar"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>MemBar</string>
<key>CFBundleIdentifier</key><string>com.local.membar</string>
<key>CFBundleExecutable</key><string>MemBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>MemBar lists and closes Chrome tabs.</string>
</dict></plist>
PLIST
KC="$HOME/Library/Keychains/membar-signing.keychain-db"
if [ -f "$KC" ]; then
  # Stable signature (see setup-signing.sh) so macOS keeps your permission grants.
  security unlock-keychain -p "" "$KC"
  codesign --force --sign "MemBar Local Signing" --keychain "$KC" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
