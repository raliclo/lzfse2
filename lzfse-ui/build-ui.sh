#!/bin/bash

# Build script for LZFSE UI
# Run from: lzfse-ui/   (this directory)
# Requires: ../lzfse-cli.swift  (project root)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_NAME="LZFSE UI"
BUNDLE_ID="com.lzfse.ui"
VERSION="1.0"
MIN_MACOS="13.0"

echo "Building LZFSE UI..."

# Create app bundle structure
echo "Creating app bundle structure..."
mkdir -p "${SCRIPT_DIR}/${APP_NAME}.app/Contents/MacOS"
mkdir -p "${SCRIPT_DIR}/${APP_NAME}.app/Contents/Resources"

# Compile the Swift files
echo "Compiling Swift code..."
swiftc -O \
    "${PROJECT_ROOT}/lzfse-cli.swift" \
    "${SCRIPT_DIR}/lzfse-ui.swift" \
    -o "${SCRIPT_DIR}/${APP_NAME}.app/Contents/MacOS/LZFSE UI" \
    -framework SwiftUI \
    -target arm64-apple-macos${MIN_MACOS}

# Create Info.plist
echo "Creating Info.plist..."
cat > "${SCRIPT_DIR}/${APP_NAME}.app/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>LZFSE UI</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Create PkgInfo
echo "APPL????" > "${SCRIPT_DIR}/${APP_NAME}.app/Contents/PkgInfo"

echo ""
echo "✓ Build complete!"
echo "Application bundle created: ${SCRIPT_DIR}/${APP_NAME}.app"
echo ""
echo "To run the app:"
echo "  open '${SCRIPT_DIR}/${APP_NAME}.app'"
echo ""
echo "To install to Applications folder:"
echo "  cp -r '${SCRIPT_DIR}/${APP_NAME}.app' /Applications/"
echo ""
