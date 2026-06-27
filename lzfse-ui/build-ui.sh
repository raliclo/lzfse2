#!/bin/bash

# Build script for LZFSE_UI
# Run from: lzfse-ui/   (this directory)
# Requires: ../lzfse-cli.swift  (project root)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_NAME="LZFSE_UI"
BUNDLE_ID="com.lzfse.ui"
VERSION="1.0"
MIN_MACOS="13.0"
ICON_PNG="${SCRIPT_DIR}/AppIcon.png"
ICON_ICNS="${SCRIPT_DIR}/AppIcon.icns"
ICON_WORK_DIR="${TMPDIR:-/tmp}/lzfse-ui-icon-$$"
SWIFT_MODULE_CACHE_DIR="${SCRIPT_DIR}/.swift-module-cache"

echo "Building LZFSE_UI..."

# Create app bundle structure
echo "Creating app bundle structure..."
mkdir -p "${SCRIPT_DIR}/${APP_NAME}.app/Contents/MacOS"
mkdir -p "${SCRIPT_DIR}/${APP_NAME}.app/Contents/Resources"
mkdir -p "$SWIFT_MODULE_CACHE_DIR"

# Generate AppIcon.icns from the checked-in PNG when available.
if [ -f "$ICON_PNG" ]; then
    echo "Generating app icon..."
    rm -rf "$ICON_WORK_DIR"
    mkdir -p "$ICON_WORK_DIR"
    sips -z 16 16     "$ICON_PNG" --out "$ICON_WORK_DIR/icp4.png" >/dev/null
    sips -z 32 32     "$ICON_PNG" --out "$ICON_WORK_DIR/icp5.png" >/dev/null
    sips -z 64 64     "$ICON_PNG" --out "$ICON_WORK_DIR/icp6.png" >/dev/null
    sips -z 128 128   "$ICON_PNG" --out "$ICON_WORK_DIR/ic07.png" >/dev/null
    sips -z 256 256   "$ICON_PNG" --out "$ICON_WORK_DIR/ic08.png" >/dev/null
    sips -z 512 512   "$ICON_PNG" --out "$ICON_WORK_DIR/ic09.png" >/dev/null
    sips -z 1024 1024 "$ICON_PNG" --out "$ICON_WORK_DIR/ic10.png" >/dev/null
    python3 - "$ICON_WORK_DIR" "$ICON_ICNS" <<'PY'
import pathlib
import struct
import sys

work = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
chunks = []
for icon_type in ("icp4", "icp5", "icp6", "ic07", "ic08", "ic09", "ic10"):
    data = (work / f"{icon_type}.png").read_bytes()
    chunks.append(icon_type.encode("ascii") + struct.pack(">I", len(data) + 8) + data)
body = b"".join(chunks)
out.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
PY
    cp "$ICON_ICNS" "${SCRIPT_DIR}/${APP_NAME}.app/Contents/Resources/AppIcon.icns"
    rm -rf "$ICON_WORK_DIR"
else
    echo "Warning: AppIcon.png not found; using default macOS app icon."
fi

# Strip the top-level runCLI() entry point (not valid in multi-file @main builds)
TEMP_CLI="/tmp/lzfse-cli-lib-$$.swift"
grep -v "^runCLI()$" "${PROJECT_ROOT}/lzfse-cli.swift" > "$TEMP_CLI"
trap "rm -f '$TEMP_CLI'" EXIT

# Compile the Swift files
echo "Compiling Swift code..."
swiftc -O \
    -module-cache-path "$SWIFT_MODULE_CACHE_DIR" \
    "$TEMP_CLI" \
    "${SCRIPT_DIR}/lzfse-ui.swift" \
    -o "${SCRIPT_DIR}/${APP_NAME}.app/Contents/MacOS/LZFSE_UI" \
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
    <string>LZFSE_UI</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
