#!/bin/sh
# Builds AgentsUsageBar.app into the given directory (default ~/Applications).
set -eu

dest="${1:-$HOME/Applications}"
cd "$(dirname "$0")"
swift build -c release
bin="$(swift build -c release --show-bin-path)/AgentsUsageBar"

app="$dest/AgentsUsageBar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/AgentsUsageBar"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AgentsUsageBar</string>
    <key>CFBundleIdentifier</key><string>local.agents-usage.bar</string>
    <key>CFBundleName</key><string>AgentsUsageBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "$app"
