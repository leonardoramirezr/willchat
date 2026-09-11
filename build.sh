#!/bin/bash
set -e

APP_NAME="WillChat"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

rm -rf "${BUILD_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
# mkdir -p "${APP_BUNDLE}/Contents/Resources/Fonts"

echo "Compiling..."
xcrun swiftc \
    -parse-as-library \
    -swift-version 5 \
    -O \
    -target arm64-apple-macosx15.0 \
    -o "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" \
    src/*.swift \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation \
    -framework Security \
    -framework CoreText

cp Info.plist "${APP_BUNDLE}/Contents/Info.plist"
# cp Resources/Fonts/*.ttf "${APP_BUNDLE}/Contents/Resources/Fonts/"
# cp Resources/Icon/AppIcon.icns "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

echo "Signing app..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "Done: ${APP_BUNDLE}"