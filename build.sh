#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="PlugPilot"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"

swift build -c release

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Library/LaunchDaemons"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$BUILD_DIR/PlugPilotHelper" "$APP_BUNDLE/Contents/MacOS/PlugPilotHelper"
cp Resources/com.amgg.plugpilot.helper.plist "$APP_BUNDLE/Contents/Library/LaunchDaemons/"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp -R Resources/es.lproj Resources/en.lproj "$APP_BUNDLE/Contents/Resources/"

codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/PlugPilotHelper"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Listo: $APP_BUNDLE"
echo "Ejecuta con: open $APP_BUNDLE"
