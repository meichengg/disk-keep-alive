#!/bin/bash
set -e

APP_NAME="Disk Keep Alive"
BUNDLE_ID="com.local.diskKeepalive"

# Extract version from Swift source
VERSION=$(grep -o 'static let version = "[^"]*"' DiskKeepAlive.swift | cut -d'"' -f2)
if [ -z "$VERSION" ]; then
    echo "❌ Failed to extract version from DiskKeepAlive.swift"
    exit 1
fi

echo "🔨 Building $APP_NAME v$VERSION..."

# Build executable
swiftc -O -o DiskKeepAlive DiskKeepAlive.swift \
    -framework AppKit -framework SwiftUI -framework IOKit

# Create .app bundle structure
rm -rf "$APP_NAME.app"
mkdir -p "$APP_NAME.app/Contents/MacOS"
mkdir -p "$APP_NAME.app/Contents/Resources"

mv DiskKeepAlive "$APP_NAME.app/Contents/MacOS/"

if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$APP_NAME.app/Contents/Resources/"
fi

cat > "$APP_NAME.app/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>DiskKeepAlive</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "✅ App bundle created: $APP_NAME.app"

# Create DMG with HFS+ filesystem (not APFS) to avoid dual mount issue
# ULFO = LZFSE compressed, fast mount
DMG_NAME="DiskKeepAlive-$VERSION"
rm -rf dmg_temp "$DMG_NAME.dmg"

mkdir dmg_temp
cp -R "$APP_NAME.app" dmg_temp/
ln -s /Applications dmg_temp/Applications

# Use HFS+ filesystem explicitly with ULFO compression
hdiutil create -srcfolder dmg_temp -volname "$APP_NAME" -fs HFS+ -format ULFO "$DMG_NAME.dmg"

rm -rf dmg_temp

echo ""
echo "✅ DMG created: $DMG_NAME.dmg (HFS+, LZFSE compressed)"
