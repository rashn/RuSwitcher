#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="RuSwitcher"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
BUILD_DIR="$PROJECT_DIR/.build/release"
VERSION_JSON="$PROJECT_DIR/version.json"

# version.json — единый источник правды. Значения в Info.plist в репо
# игнорируются: скрипт штампует CFBundleShortVersionString и CFBundleVersion
# в копию Info.plist внутри собранного бандла.
SHORT_VERSION=$(/usr/bin/python3 -c "import json,sys;print(json.load(open('$VERSION_JSON'))['version'])")
BUILD_VERSION=$(/usr/bin/python3 -c "import json,sys;print(json.load(open('$VERSION_JSON')).get('build','1'))")

if [ -z "$SHORT_VERSION" ]; then
    echo "ERROR: could not read version from $VERSION_JSON"
    exit 1
fi

echo "=== Building $APP_NAME v$SHORT_VERSION (build $BUILD_VERSION) ==="

# 1. Собираем release
echo "→ swift build --configuration release..."
cd "$PROJECT_DIR"
swift build --configuration release

# 2. Создаём .app bundle
echo "→ Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 3. Копируем бинарник
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# 4. Копируем Info.plist и штампуем версию из version.json
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP_BUNDLE/Contents/Info.plist"
echo "→ Stamped Info.plist: CFBundleShortVersionString=$SHORT_VERSION CFBundleVersion=$BUILD_VERSION"

# 5. Копируем иконку
cp "$PROJECT_DIR/RuSwitcher.icns" "$APP_BUNDLE/Contents/Resources/RuSwitcher.icns"

# 6. Создаём PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# 7. Подписываем Developer ID (разрешения macOS привязаны к подписи —
#    при одинаковой подписи разрешения сохраняются между обновлениями)
SIGN_ID="Developer ID Application: Rashid Nasibulin (9GEWCZ59HK)"
echo "→ Code signing with Developer ID..."
codesign --force --deep --sign "$SIGN_ID" \
    --options runtime \
    --entitlements "$PROJECT_DIR/RuSwitcher.entitlements" \
    "$APP_BUNDLE"

echo ""
echo "=== Done! ==="
echo "App bundle: $APP_BUNDLE"
echo "Signed with: $SIGN_ID"
echo ""
echo "To install:"
echo "  cp -R $APP_BUNDLE /Applications/"
