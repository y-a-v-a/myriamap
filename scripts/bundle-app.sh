#!/usr/bin/env bash
# Builds the SwiftUI app in release mode and assembles dist/Myriamap.app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Myriamap.app"
cd "$ROOT"

swift build -c release --product MyriamapApp
swift build -c release --product myriamap
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MyriamapApp" "$APP/Contents/MacOS/Myriamap"
# Data files are looked up in the main bundle first.
cp Sources/ZoneAtlas/Resources/timezones.geojson Sources/ZoneAtlas/Resources/land.geojson "$APP/Contents/Resources/"

# Icon: a square crop of the rendered map around the Atlantic and Africa.
ICONWORK="$(mktemp -d)"
"$BIN/myriamap" render --no-labels --width 2048 --center 10 --date 2026-06-21T12:00:00Z -o "$ICONWORK/map.png" >/dev/null
sips --cropToHeightWidth 1000 1000 "$ICONWORK/map.png" --out "$ICONWORK/square.png" >/dev/null
mkdir -p "$ICONWORK/AppIcon.iconset"
for size in 16 32 64 128 256 512; do
  sips -z $size $size "$ICONWORK/square.png" --out "$ICONWORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$ICONWORK/square.png" --out "$ICONWORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONWORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONWORK"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Myriamap</string>
  <key>CFBundleDisplayName</key><string>Myriamap</string>
  <key>CFBundleIdentifier</key><string>app.myriamap.Myriamap</string>
  <key>CFBundleExecutable</key><string>Myriamap</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.reference</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Timezones © OpenStreetMap contributors (ODbL) via timezone-boundary-builder; land from Natural Earth.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
