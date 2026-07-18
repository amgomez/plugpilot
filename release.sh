#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="PlugPilot"
APP_BUNDLE="$APP_NAME.app"

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")
ZIP_NAME="$APP_NAME-$VERSION.zip"

rm -f "$ZIP_NAME"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_NAME"

echo "Listo: $ZIP_NAME"
