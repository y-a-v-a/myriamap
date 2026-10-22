#!/usr/bin/env bash
# Builds the SwiftUI app in release mode (universal: Apple silicon and Intel)
# and assembles dist/Myriamap.app.
#
#   VERSION         CFBundleShortVersionString (default 1.0)
#   SIGN_IDENTITY   codesign identity; "-" (the default) signs ad hoc, anything
#                   else signs with the hardened runtime and a secure timestamp
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Myriamap.app"
VERSION="${VERSION:-1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
ARCHS=(--arch arm64 --arch x86_64)
cd "$ROOT"

swift build -c release "${ARCHS[@]}" --product MyriamapApp
swift build -c release "${ARCHS[@]}" --product myriamap
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.reference</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Timezones © OpenStreetMap contributors (ODbL) via timezone-boundary-builder; land from Natural Earth.</string>
</dict>
</plist>
PLIST

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"
