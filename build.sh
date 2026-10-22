#!/bin/sh
# Builds fixmon.app (a bundle, so the Accessibility grant sticks to the app rather than your terminal).
set -e
cd "$(dirname "$0")"
APP=fixmon.app
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/fixmon"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.fixmon</string>
  <key>CFBundleName</key><string>fixmon</string>
  <key>CFBundleExecutable</key><string>fixmon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# Stable identity keeps the Accessibility grant across rebuilds; falls back to ad-hoc.
ID="fixmon local signing"
security find-identity -p codesigning | grep -q "$ID" || ID=-
codesign --force --sign "$ID" "$APP"
echo "Built $APP — run: open $APP"
