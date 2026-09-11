#!/bin/bash
set -e

APP_NAME="WillChat"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

rm -rf "${BUILD_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources/Fonts"

echo "Compilando..."
xcrun swiftc \
    -parse-as-library \
    -o "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" \
    src/*.swift \
    -framework AppKit \
    -framework Foundation \
    -framework CoreText

cp Info.plist "${APP_BUNDLE}/Contents/Info.plist"
cp Resources/Fonts/*.ttf "${APP_BUNDLE}/Contents/Resources/Fonts/"
cp Resources/Icon/AppIcon.icns "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

echo "Firmando app..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "Listo: ${APP_BUNDLE}"