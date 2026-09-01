#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
APP_PATH="$SCRIPT_DIR/build/Don't sleep.app"

cd "$SCRIPT_DIR"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

for ARCH in arm64 x86_64; do
  swiftc \
    -parse-as-library \
    -swift-version 6 \
    -O \
    -target "${ARCH}-apple-macosx13.0" \
    -module-cache-path "$SCRIPT_DIR/.build/module-cache-${ARCH}" \
    -framework AppKit \
    -framework SwiftUI \
    -framework UserNotifications \
    "$SCRIPT_DIR/Sources/DontSleepGUI/DontSleepApp.swift" \
    -o "$SCRIPT_DIR/.build/DontSleep-${ARCH}"
done

lipo -create \
  "$SCRIPT_DIR/.build/DontSleep-arm64" \
  "$SCRIPT_DIR/.build/DontSleep-x86_64" \
  -output "$APP_PATH/Contents/MacOS/DontSleep"
cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_PATH"

echo "Готово: $APP_PATH"
