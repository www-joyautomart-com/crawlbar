#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/CrawlBar.app"
STAGING_APP_DIR="$DIST_DIR/.CrawlBar.app.tmp.$$"
CONTENTS_DIR="$STAGING_APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
swift build -c release --product CrawlBar >&2
swift build -c release --product crawlbarctl >&2

rm -rf "$STAGING_APP_DIR"
trap 'rm -rf "$STAGING_APP_DIR"' EXIT
mkdir -p "$MACOS_DIR" "$HELPERS_DIR" "$RESOURCES_DIR"

cp ".build/release/CrawlBar" "$MACOS_DIR/CrawlBar"
cp ".build/release/crawlbarctl" "$HELPERS_DIR/crawlbar"
RESOURCE_BUNDLE=".build/release/CrawlBar_CrawlBar.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/CrawlBar_CrawlBar.bundle"
  if ! find "$RESOURCES_DIR/CrawlBar_CrawlBar.bundle" -type f -print -quit | grep -q .; then
    echo "SwiftPM resource bundle is empty: $RESOURCE_BUNDLE" >&2
    exit 1
  fi
else
  echo "missing SwiftPM resource bundle: $RESOURCE_BUNDLE" >&2
  exit 1
fi
Scripts/generate_app_icon.swift "$RESOURCES_DIR/CrawlBar.icns"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>CrawlBar</string>
  <key>CFBundleIdentifier</key>
  <string>com.vincentkoc.CrawlBar</string>
  <key>CFBundleName</key>
  <string>CrawlBar</string>
  <key>CFBundleIconFile</key>
  <string>CrawlBar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.4.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$STAGING_APP_DIR" >/dev/null
fi

rm -rf "$APP_DIR"
mv "$STAGING_APP_DIR" "$APP_DIR"
echo "$APP_DIR"
