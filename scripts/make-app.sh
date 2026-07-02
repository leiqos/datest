#!/bin/bash
# Builds the release binary and assembles Datest.app in ./build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

# Render the app icon (best effort — the bundle works without it).
if [ ! -f build/AppIcon.icns ]; then
    if swift scripts/render-icon.swift build/icon-1024.png; then
        ICONSET=build/AppIcon.iconset
        rm -rf "$ICONSET" && mkdir -p "$ICONSET"
        for size in 16 32 128 256 512; do
            sips -z $size $size build/icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
            sips -z $((size*2)) $((size*2)) build/icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
        done
        iconutil -c icns "$ICONSET" -o build/AppIcon.icns
        rm -rf "$ICONSET"
    else
        echo "Icon rendering failed; building without an icon."
    fi
fi

APP="build/Datest.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Datest "$APP/Contents/MacOS/Datest"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Datest</string>
    <key>CFBundleDisplayName</key>       <string>Datest</string>
    <key>CFBundleExecutable</key>        <string>Datest</string>
    <key>CFBundleIdentifier</key>        <string>local.jun.datest</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
</dict>
</plist>
PLIST

if [ -f build/AppIcon.icns ]; then
    cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cp scripts/askpass.sh "$APP/Contents/Resources/askpass.sh"
chmod 755 "$APP/Contents/Resources/askpass.sh"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
