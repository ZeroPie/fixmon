#!/bin/sh
# Builds fixmon.app (a bundle, so the Accessibility grant sticks to the app rather than your terminal).
#   ./build.sh           build ./fixmon.app
#   ./build.sh install   build, then install to /Applications and relaunch from there
#   ./build.sh dmg       build, then package dist/fixmon-<version>.dmg (drag-to-Applications)
set -e
cd "$(dirname "$0")"
APP=fixmon.app
VERSION=1.2

# App icon: regenerated only when the drawing script changes.
ICNS=icon/AppIcon.icns
if [ ! -f "$ICNS" ] || [ icon/make_icon.swift -nt "$ICNS" ]; then
  SET=icon/AppIcon.iconset
  rm -rf "$SET" && mkdir -p "$SET"
  swift icon/make_icon.swift "$SET/icon_512x512@2x.png" >/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s "$SET/icon_512x512@2x.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    [ $s -lt 512 ] && sips -z $d $d "$SET/icon_512x512@2x.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$ICNS"
  rm -rf "$SET"
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/fixmon"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.fixmon</string>
  <key>CFBundleName</key><string>fixmon</string>
  <key>CFBundleDisplayName</key><string>fixmon</string>
  <key>CFBundleExecutable</key><string>fixmon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>fixmon — fences off a damaged display strip</string>
</dict></plist>
EOF
# Stable identity keeps the Accessibility grant across rebuilds; falls back to ad-hoc.
ID="fixmon local signing"
security find-identity -p codesigning | grep -q "$ID" || ID=-
codesign --force --sign "$ID" "$APP"
echo "Built $APP $VERSION"

case "$1" in
install)
  pkill -x fixmon || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  open "/Applications/$APP"
  echo "Installed to /Applications and launched"
  ;;
dmg)
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  mkdir -p dist
  DMG="dist/fixmon-$VERSION.dmg"
  rm -f "$DMG"
  hdiutil create -quiet -volname "fixmon $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
  rm -rf "$STAGE"
  echo "Packaged $DMG"
  ;;
*)
  echo "Run: open $APP   (or ./build.sh install / ./build.sh dmg)"
  ;;
esac
