#!/bin/bash
# Builds dist/Sweeper.dmg for sharing. Set NOTARY_PROFILE to a `xcrun notarytool store-credentials` profile to notarize.
set -euo pipefail
cd "$(dirname "$0")"
stage=$(mktemp -d)
./build.sh "$stage" >/dev/null
ln -s /Applications "$stage/Applications"
mkdir -p dist
dmg="dist/Sweeper-$(cat VERSION).dmg"
rm -f "$dmg"
hdiutil create -volname Sweeper -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
rm -rf "$stage"
identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')}"
[ -n "$identity" ] && codesign --force --timestamp --sign "$identity" "$dmg"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
fi
echo "$dmg"
