#!/usr/bin/env bash
set -euo pipefail

# Build the "Time Tracker" macOS .app bundle from the SwiftPM executable.
#
#   ./Scripts/build.sh            build "Time Tracker.app" into the project root
#   ./Scripts/build.sh --install  also copy it to /Applications

APP_DISPLAY_NAME="Time Tracker"
EXECUTABLE="TimeTracker"
BUNDLE_ID="com.almax.timetracker"
VERSION="1.0.0"
BUILD_NUMBER="1"
MIN_MACOS="14.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "▶ Building release binary…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
APP_DIR="$ROOT/${APP_DISPLAY_NAME}.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

echo "▶ Assembling ${APP_DISPLAY_NAME}.app…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "$BIN_PATH/$EXECUTABLE" "$MACOS_DIR/$EXECUTABLE"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>${APP_DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key>        <string>${APP_DISPLAY_NAME}</string>
    <key>CFBundleExecutable</key>         <string>${EXECUTABLE}</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>CFBundleIdentifier</key>         <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>            <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>     <string>${MIN_MACOS}</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSPrincipalClass</key>           <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>  <string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "▶ Ad-hoc code signing…"
codesign --force --sign - "$APP_DIR"

# Re-register with LaunchServices so the Dock / Stage Manager pick up the current icon
# (rebuilding in place otherwise serves a stale cached icon).
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$APP_DIR" >/dev/null 2>&1 || true

echo "✅ Built ${APP_DIR}"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/${APP_DISPLAY_NAME}.app"
    echo "▶ Installing to ${DEST}…"
    rm -rf "$DEST"
    cp -R "$APP_DIR" "$DEST"
    echo "✅ Installed ${DEST}"
fi
