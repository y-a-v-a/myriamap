#!/usr/bin/env bash
# Builds Myriamap.app signed with a Developer ID, has Apple notarize it,
# staples the ticket, zips it and publishes the ZIP as a GitHub release.
#
#   scripts/release.sh 1.0.0
#
# Needs a "Developer ID Application" certificate in the keychain, the gh CLI
# logged in, and a notarytool keychain profile for the team. Profiles aren't
# tied to one app, so the one made for Mould works. To create one (use an
# app-specific password from https://account.apple.com):
#
#   xcrun notarytool store-credentials mould-notary \
#     --apple-id you@example.com --team-id HFFHH9CJYF
#
#   NOTARY_PROFILE   keychain profile (default mould-notary)
#   SIGN_IDENTITY    codesign identity (default "Developer ID Application")
#   PUBLISH=0        stop after notarizing; leave the ZIP in dist/
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
TAG="v$VERSION"
NOTARY_PROFILE="${NOTARY_PROFILE:-mould-notary}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PUBLISH="${PUBLISH:-1}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Myriamap.app"
ZIP="$ROOT/dist/Myriamap-$VERSION.zip"
cd "$ROOT"

fail() { echo "release: $*" >&2; exit 1; }

if [[ "$PUBLISH" == 1 ]]; then
  [[ -z "$(git status --porcelain)" ]] || fail "the working tree has uncommitted changes"
  git fetch --quiet origin
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse '@{u}')" ]] || fail "HEAD is not the pushed upstream commit"
  ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "tag $TAG already exists"
  ! gh release view "$TAG" >/dev/null 2>&1 || fail "release $TAG already exists on GitHub"
fi

# Fail before the slow build if the notary credentials aren't there (or the keychain is locked).
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 ||
  fail "can't use notary profile '$NOTARY_PROFILE'; create it (see the top of this script), unlock the login keychain or set NOTARY_PROFILE"

VERSION="$VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" scripts/bundle-app.sh
codesign --verify --strict --deep --verbose=2 "$APP"

# Notarize the signed app (notarytool takes a ZIP), then staple the ticket to
# the app so Gatekeeper accepts it offline, and zip the stapled app.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto -c -k --keepParent "$APP" "$WORK/upload.zip"
xcrun notarytool submit "$WORK/upload.zip" --keychain-profile "$NOTARY_PROFILE" \
  --wait --output-format json > "$WORK/notary.json"
STATUS="$(plutil -extract status raw "$WORK/notary.json")"
if [[ "$STATUS" != "Accepted" ]]; then
  ID="$(plutil -extract id raw "$WORK/notary.json")"
  xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  fail "notarization finished with status $STATUS"
fi
xcrun stapler staple "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# Check what a downloader gets: the app from the ZIP, stapled and accepted.
ditto -x -k "$ZIP" "$WORK/check"
xcrun stapler validate "$WORK/check/Myriamap.app"
spctl --assess --type execute --verbose=2 "$WORK/check/Myriamap.app"

SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "Notarized $ZIP"
echo "SHA-256 $SHA"
[[ "$PUBLISH" == 1 ]] || exit 0

git tag -a "$TAG" -m "Myriamap $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --verify-tag --title "Myriamap $VERSION" --notes-file - <<NOTES
A timezone map on the myriahedral projection: the globe is cut open along the
timezone borders and unfolded flat, every zone labelled with its live clock.

**Download** \`Myriamap-$VERSION.zip\`, unzip it and move **Myriamap.app** to
Applications. It runs on macOS 14 or later, on Apple silicon and Intel Macs,
and is signed with a Developer ID and notarized by Apple.

- the unfolded map, drawn with Metal, with pinch, ⌘-scroll, drag and double-click zoom
- hover cards with local time, abbreviation, UTC offset and coordinates
- a sidebar of every zone's live clock, sorted by offset
- a time scrubber (±24 h) to watch day and night move
- a fold slider and a globe ⇄ map animation
- light and dark appearances in three colour schemes, SVG/PNG export

SHA-256 of the ZIP: \`$SHA\`

Timezones © OpenStreetMap contributors (ODbL) via timezone-boundary-builder;
land from Natural Earth.
NOTES
