#!/bin/bash

# Build the executable
echo "Building Symposium..."
swift build --configuration release

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

# Create app bundle structure
APP_NAME="Symposium"
BUILD_DIR="./.build/arm64-apple-macosx/release"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

echo "Creating app bundle structure..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"

# Copy executable
cp "${BUILD_DIR}/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"

# Copy Info.plist
cp "./Info.plist" "${CONTENTS_DIR}/Info.plist"

# Sign the app bundle
echo "Signing app bundle..."
codesign --sign "Apple Development: niko@alum.mit.edu (S7V42UKLD6)" --force --deep "${APP_BUNDLE}"

if [ $? -eq 0 ]; then
    echo "✅ App bundle created and signed successfully at ${APP_BUNDLE}"
    echo "🚀 You can now run: open \"${APP_BUNDLE}\""
else
    echo "❌ Signing failed!"
    exit 1
fi