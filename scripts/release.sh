#!/bin/bash
# Builds Delta.app in Release mode, signs it and packages it into dist/Delta-<version>.dmg.
#
# Environment (all optional):
#   VERSION         version number (defaults to MARKETING_VERSION in project.yml)
#   SIGN_IDENTITY   "Developer ID Application: …" certificate; ad-hoc signing ("-") when unset
#   NOTARY_PROFILE  notarytool keychain profile; notarizes and staples the .dmg when set
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
DERIVED="$HOME/Library/Caches/Delta/DerivedData"
APP="$DERIVED/Build/Products/Release/Delta.app"
DMG="dist/Delta-$VERSION.dmg"

echo "==> Building Delta $VERSION"
xcodegen generate --quiet
xcodebuild -project Delta.xcodeproj -scheme Delta -configuration Release \
  -derivedDataPath "$DERIVED" MARKETING_VERSION="$VERSION" build | tail -1

echo "==> Signing ($([ "$SIGN_IDENTITY" = "-" ] && echo ad-hoc || echo "$SIGN_IDENTITY"))"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "==> Packaging $DMG"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Delta.app"
ln -s /Applications "$STAGING/Applications"
mkdir -p dist
rm -f "$DMG"
hdiutil create -quiet -volname "Delta — Diff Viewer" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Notarizing"
  codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1))"
