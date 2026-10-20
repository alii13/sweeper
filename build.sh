#!/bin/bash
# Builds Sweeper.app, signs it, and installs it to /Applications (or $1 to only build into that folder).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
if [ ! -f Resources/AppIcon.icns ]; then
  tmp=$(mktemp -d)
  swift scripts/make-icon.swift "$tmp/icon.png"
  mkdir -p "$tmp/AppIcon.iconset" Resources
  for s in 16 32 128 256 512; do
    sips -z $s $s "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$tmp/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$tmp"
fi
dest="${1:-/Applications}"
app="$dest/Sweeper.app"
version=$(cat VERSION)
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Sweeper "$app/Contents/MacOS/Sweeper"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Sweeper</string>
<key>CFBundleDisplayName</key><string>Sweeper</string>
<key>CFBundleIdentifier</key><string>com.sweeper.app</string>
<key>CFBundleExecutable</key><string>Sweeper</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# A stable Developer ID keeps macOS's Full Disk Access grant across rebuilds; ad-hoc signing resets it every build.
identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')}"
if [ -n "$identity" ]; then
  codesign --force --options runtime --timestamp --sign "$identity" "$app"
else
  echo "No Developer ID found, signing ad-hoc" >&2
  codesign --force --sign - "$app"
fi
echo "$app"
