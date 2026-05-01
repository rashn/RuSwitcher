#!/bin/bash
set -e

APP_NAME="RuSwitcher"
# Единый источник версии — version.json в корне репозитория.
VERSION=$(/usr/bin/python3 -c "import json;print(json.load(open('version.json'))['version'])")
BUILD_VERSION=$(/usr/bin/python3 -c "import json;print(json.load(open('version.json')).get('build','1'))")
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
# Keychain profile used for Apple notarization. Override with NOTARIZE_PROFILE=<name>.
# Skip notarization entirely with SKIP_NOTARIZE=1.
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-notarytool-studio}"
DMG_TEMP="${APP_NAME}-temp.dmg"
VOL_NAME="${APP_NAME}"
BACKGROUND="dmg_background.png"
APP_PATH="${APP_NAME}.app"
DMG_SIZE="10m"

echo "=== Creating styled DMG ==="

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: $APP_PATH not found. Build the app first: ./build_app.sh"
    exit 1
fi

APP_INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [ ! -f "$APP_INFO_PLIST" ]; then
    echo "ERROR: $APP_INFO_PLIST not found"
    exit 1
fi

APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_INFO_PLIST" 2>/dev/null || true)
APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_INFO_PLIST" 2>/dev/null || true)

if [ "$APP_VERSION" != "$VERSION" ] || [ "$APP_BUILD" != "$BUILD_VERSION" ]; then
    echo "ERROR: App bundle version mismatch."
    echo "  version.json expects: $VERSION (build $BUILD_VERSION)"
    echo "  $APP_PATH contains:   ${APP_VERSION:-?} (build ${APP_BUILD:-?})"
    echo "Rebuild app before packaging: ./build_app.sh"
    exit 1
fi

# Clean up
rm -f "$DMG_NAME" "$DMG_TEMP"

# 1. Create temporary writable DMG
echo "→ Creating temp DMG..."
hdiutil create -volname "$VOL_NAME" -fs HFS+ \
    -size "$DMG_SIZE" -layout NONE "$DMG_TEMP"

# 2. Mount it
echo "→ Mounting..."
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "$DMG_TEMP" | grep "/Volumes/" | sed 's/.*\(\/Volumes\/.*\)/\1/')
echo "   Mounted at: $MOUNT_DIR"

# 3. Copy app and create Applications symlink
echo "→ Copying app..."
cp -R "$APP_PATH" "$MOUNT_DIR/"
ln -sf /Applications "$MOUNT_DIR/Applications"

# 4. Create .background directory and copy background image
mkdir -p "$MOUNT_DIR/.background"
cp "$BACKGROUND" "$MOUNT_DIR/.background/background.png"

# 5. Apply Finder settings via AppleScript
echo "→ Configuring Finder view..."
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 760, 500}

        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set text size of theViewOptions to 13
        set background picture of theViewOptions to file ".background:background.png"

        -- Position: app icon on left, Applications on right
        set position of item "$APP_NAME.app" of container window to {170, 210}
        set position of item "Applications" of container window to {490, 210}

        close
        open

        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

# 6. Set volume icon
if [ -f "${APP_NAME}.icns" ]; then
    cp "${APP_NAME}.icns" "$MOUNT_DIR/.VolumeIcon.icns"
    SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns" 2>/dev/null || true
    SetFile -a C "$MOUNT_DIR" 2>/dev/null || true
fi

# 7. Finalize permissions
chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true
sync

# 8. Unmount
echo "→ Unmounting..."
hdiutil detach "$MOUNT_DIR" -quiet

# 9. Convert to compressed read-only DMG
echo "→ Compressing..."
hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_NAME"
rm -f "$DMG_TEMP"

# 10. Notarize with Apple (required for Gatekeeper to accept the DMG on end-user Macs).
# Signed-but-unnotarized DMGs trigger "Apple could not verify [app] is free of malware".
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "→ SKIP_NOTARIZE=1 — skipping notarization (DMG will NOT pass Gatekeeper on other Macs)"
else
    echo "→ Submitting to Apple notary service (profile: $NOTARIZE_PROFILE)..."
    xcrun notarytool submit "$DMG_NAME" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait

    echo "→ Stapling notarization ticket..."
    xcrun stapler staple "$DMG_NAME"
    xcrun stapler validate "$DMG_NAME"
fi

echo ""
echo "=== Done! ==="
echo "DMG: $(pwd)/$DMG_NAME ($(du -h "$DMG_NAME" | cut -f1))"
echo "SHA256: $(shasum -a 256 "$DMG_NAME" | awk '{print $1}')"
