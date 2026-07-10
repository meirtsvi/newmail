#!/usr/bin/env bash
#
# Publishes a Sparkle update: Release archive → Developer ID export → DMG →
# notarize + staple → EdDSA-sign → GitHub Release → appcast entry pushed.
#
# Usage:
#   Tools/release.sh 0.2.0
#
# One-time prerequisites (already set up on this machine):
#   • Developer ID Application cert in the login keychain
#   • notarytool keychain profile named "notary"
#   • Sparkle EdDSA private key in the login keychain (generate_keys)
#   • gh CLI authenticated for meirtsvi/newmail
#
# The app checks https://raw.githubusercontent.com/meirtsvi/newmail/main/appcast.xml,
# so an update goes live the moment the appcast commit is pushed — which this
# script does last, after the DMG is downloadable from the GitHub Release.
#
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: Tools/release.sh <version, e.g. 0.2.0>}"
REPO="meirtsvi/newmail"
SCHEME="newmail"
OUT="build/release-$VERSION"
DMG="$OUT/newmail-$VERSION.dmg"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/v$VERSION/newmail-$VERSION.dmg"

if grep -q "sparkle:version=\"$VERSION\"" appcast.xml; then
  echo "error: $VERSION is already in appcast.xml" >&2
  exit 1
fi

# Sparkle's signing tool ships in the SPM artifact bundle Xcode downloaded.
SPARKLE_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path '*artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -1)"
if [[ -z "$SPARKLE_BIN" ]]; then
  echo "error: Sparkle tools not found — open the project once so Xcode resolves packages" >&2
  exit 1
fi

echo "==> Regenerating Xcode project"
xcodegen generate >/dev/null

echo "==> Archiving $VERSION (Release)"
rm -rf "$OUT"
xcodebuild archive \
  -project newmail.xcodeproj -scheme "$SCHEME" -configuration Release \
  -archivePath "$OUT/newmail.xcarchive" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" \
  -quiet

echo "==> Exporting with Developer ID signing"
xcodebuild -exportArchive \
  -archivePath "$OUT/newmail.xcarchive" \
  -exportOptionsPlist Config/ExportOptions.plist \
  -exportPath "$OUT/export" \
  -quiet

echo "==> Building DMG"
STAGING="$OUT/dmg-staging"
mkdir -p "$STAGING"
cp -R "$OUT/export/newmail.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "newmail" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

echo "==> Notarizing (profile: notary)"
xcrun notarytool submit "$DMG" --keychain-profile notary --wait
xcrun stapler staple "$DMG"

echo "==> Signing the update (Sparkle EdDSA)"
# Prints: sparkle:edSignature="…" length="…"
SIGNATURE_ATTRS="$("$SPARKLE_BIN/sign_update" "$DMG")"

echo "==> Creating GitHub release v$VERSION"
# Release notes are the commit subjects since the previous release tag.
NOTES_FILE="$OUT/release-notes.md"
PREV_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [[ -n "$PREV_TAG" ]]; then
  git log "$PREV_TAG..HEAD" --no-merges --pretty='- %s' > "$NOTES_FILE"
else
  echo "newmail $VERSION" > "$NOTES_FILE"
fi
gh release create "v$VERSION" "$DMG" \
  --repo "$REPO" \
  --title "newmail $VERSION" \
  --notes-file "$NOTES_FILE"

echo "==> Adding $VERSION to appcast.xml and pushing"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
# The item goes through a file: BSD awk rejects multiline strings passed via -v.
ITEM_FILE="$OUT/appcast-item.xml"
cat > "$ITEM_FILE" <<EOF
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure url="$DOWNLOAD_URL" $SIGNATURE_ATTRS type="application/octet-stream"/>
    </item>
EOF
# Insert the new item right after <language> so the newest release is first.
awk -v itemfile="$ITEM_FILE" '{
  print
  if ($0 ~ /<language>/) { while ((getline line < itemfile) > 0) print line }
}' appcast.xml > appcast.xml.tmp
mv appcast.xml.tmp appcast.xml

git add appcast.xml
git commit -m "Release $VERSION"
git push

echo "==> Done: $DOWNLOAD_URL is live; installed apps will offer $VERSION on their next check."
