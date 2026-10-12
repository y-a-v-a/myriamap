#!/usr/bin/env bash
# Downloads the raw boundary data and produces the simplified GeoJSON
# resources bundled with the ZoneAtlas target.
#
#   timezones.geojson  timezone-boundary-builder "with oceans, now" release
#                      (one feature per distinct clock, oceans included)
#   land.geojson       Natural Earth 1:50m land polygons
#
# Requires curl, unzip and node/npx (for mapshaper, which simplifies while
# preserving shared borders between neighbouring zones).
set -euo pipefail

TBB_RELEASE="${TBB_RELEASE:-2026e}"
ZONES_KEEP="${ZONES_KEEP:-1%}"
LAND_KEEP="${LAND_KEEP:-40%}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW="$ROOT/data/raw"
OUT="$ROOT/Sources/ZoneAtlas/Resources"
MAPSHAPER="npx -y mapshaper@0.6"

mkdir -p "$RAW/tbb" "$OUT"

tbb_zip="$RAW/tbb/timezones-with-oceans-now.geojson.zip"
if [[ ! -f "$tbb_zip" ]]; then
  curl -sSfL -o "$tbb_zip" \
    "https://github.com/evansiroky/timezone-boundary-builder/releases/download/$TBB_RELEASE/timezones-with-oceans-now.geojson.zip"
fi
if [[ ! -f "$RAW/tbb/combined-with-oceans-now.json" ]]; then
  unzip -o -q "$tbb_zip" -d "$RAW/tbb"
fi

land_raw="$RAW/ne_50m_land.geojson"
if [[ ! -f "$land_raw" ]]; then
  curl -sSfL -o "$land_raw" \
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_land.geojson"
fi

# The source has overlapping polygons in disputed areas (e.g. Asia/Urumqi
# over Xinjiang); -clean hands each overlap to the larger zone so every
# point on Earth belongs to exactly one region.
$MAPSHAPER -i "$RAW/tbb/combined-with-oceans-now.json" \
  -simplify "$ZONES_KEEP" keep-shapes \
  -clean overlap-rule=max-area \
  -filter-fields tzid \
  -o precision=0.0001 format=geojson "$OUT/timezones.geojson"

$MAPSHAPER -i "$land_raw" \
  -simplify "$LAND_KEEP" keep-shapes \
  -filter-fields featurecla \
  -o precision=0.001 format=geojson "$OUT/land.geojson"

echo "tbb release $TBB_RELEASE" > "$OUT/SOURCES.txt"
echo "zones simplified to $ZONES_KEEP and cleaned (overlaps to the larger zone)," >> "$OUT/SOURCES.txt"
echo "land (Natural Earth 50m) simplified to $LAND_KEEP" >> "$OUT/SOURCES.txt"
ls -la "$OUT"
