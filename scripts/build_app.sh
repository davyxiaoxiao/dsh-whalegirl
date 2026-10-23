#!/bin/bash
# Build WhaleGirl.app — a tiny always-on-top DSH desktop pet.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/WhaleGirl.app"
CACHE="$ROOT/.build/ModuleCache"
TMP="$ROOT/.build/tmp"
mkdir -p "$CACHE" "$TMP" "$ROOT/build"

echo "==> cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> zstd helper"
clang -O2 -mmacosx-version-min=13.0 -I/opt/homebrew/opt/zstd/include \
    "$ROOT/scripts/zstd_helper.c" \
    /opt/homebrew/opt/zstd/lib/libzstd.a \
    -o "$APP/Contents/MacOS/zstd-helper"

echo "==> assets"
cp "$ROOT"/Assets/pet_*.png "$APP/Contents/Resources/"

echo "==> icon"
ICONSET="$ROOT/build/AppIcon.iconset"
if [ ! -f "$ICONSET/icon_512x512@2x.png" ]; then
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ROOT/Assets/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z "$((size * 2))" "$((size * 2))" "$ROOT/Assets/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
fi
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> swift"
TMPDIR="$TMP" swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path "$CACHE" \
    -framework AppKit -framework QuartzCore -framework ApplicationServices \
    "$ROOT"/Sources/BlueFish/*.swift \
    -o "$APP/Contents/MacOS/WhaleGirl"

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleDisplayName</key><string>鲸鱼娘</string>
    <key>CFBundleExecutable</key><string>WhaleGirl</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.daiwei.bluefish</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>鲸鱼娘</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.1</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.daiwei.bluefish</string>
            <key>CFBundleURLSchemes</key>
            <array><string>bluefish</string></array>
        </dict>
    </array>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>LSMultipleInstancesProhibited</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Made for DSH · local only</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> signing (ad-hoc)"
codesign --force --sign - "$APP/Contents/MacOS/zstd-helper" >/dev/null 2>&1 || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "==> done: $APP"
