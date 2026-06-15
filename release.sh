#!/bin/bash
# release.sh — Build a universal binary, bundle as kd100.app, sign with Developer ID,
# notarize, staple, and package (.pkg) for distribution. Mirrors the icloud-keychain
# release flow (minus the provisioning profile / entitlements — kd100 needs neither;
# Input Monitoring is a runtime TCC grant, not a signing entitlement).
#
# Prerequisites:
#   1. "Developer ID Application" + "Developer ID Installer" certs in the keychain
#   2. Notarization credentials stored once:
#        xcrun notarytool store-credentials "notary-profile" \
#          --apple-id "you@example.com" --team-id "RE4JN752MW" --password "APP-SPECIFIC-PW"
#   3. Xcode installed (Swift toolchain)
#
# Usage: ./release.sh        (VERSION is rewritten by the release workflow from the tag)
set -euo pipefail

VERSION="dev"
IDENTITY="Developer ID Application: Otherland Labs sp. z o.o. (RE4JN752MW)"
INSTALLER_IDENTITY="Developer ID Installer: Otherland Labs sp. z o.o. (RE4JN752MW)"
BUNDLE_ID="dev.otherlandlabs.kd100"
NOTARY_PROFILE="notary-profile"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/release-build"
APP="$BUILD_DIR/kd100.app"

echo "==> Building universal binary (arm64 + x86_64)"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
cd "$SCRIPT_DIR"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/kd100"
lipo -info "$BIN" || file "$BIN"

echo "==> Creating .app bundle"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/kd100"
cat > "$APP/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>kd100</string>
    <key>CFBundleName</key><string>kd100</string>
    <key>CFBundleDisplayName</key><string>KD100 Daemon</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright 2026 Piotr Rojek — https://piotrrojek.io</string>
</dict>
</plist>
EOF

echo "==> Signing with Developer ID (hardened runtime)"
codesign -f -s "$IDENTITY" --timestamp --options runtime "$APP/Contents/MacOS/kd100"
codesign -f -s "$IDENTITY" --timestamp --options runtime --identifier "$BUNDLE_ID" "$APP"
codesign -vvv --strict "$APP"

echo "==> Notarizing app"
ditto -c -k --keepParent "$APP" "$BUILD_DIR/kd100.zip"
xcrun notarytool submit "$BUILD_DIR/kd100.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

echo "==> Building installer package"
PKG_ROOT="$BUILD_DIR/pkg-root"; PKG_SCRIPTS="$BUILD_DIR/pkg-scripts"
rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"
mkdir -p "$PKG_ROOT/usr/local/lib" "$PKG_SCRIPTS"
cp -R "$APP" "$PKG_ROOT/usr/local/lib/"
cat > "$PKG_SCRIPTS/postinstall" << 'POSTINSTALL'
#!/bin/bash
mkdir -p /usr/local/bin
ln -sf /usr/local/lib/kd100.app/Contents/MacOS/kd100 /usr/local/bin/kd100
POSTINSTALL
cat > "$PKG_SCRIPTS/preinstall" << 'PREINSTALL'
#!/bin/bash
rm -f /usr/local/bin/kd100
rm -rf /usr/local/lib/kd100.app
exit 0
PREINSTALL
chmod +x "$PKG_SCRIPTS/postinstall" "$PKG_SCRIPTS/preinstall"

PKG="$BUILD_DIR/aerospace-kd100-${VERSION}-macos-universal.pkg"
pkgbuild --root "$PKG_ROOT" --scripts "$PKG_SCRIPTS" \
    --identifier "$BUNDLE_ID" --version "$VERSION" \
    --sign "$INSTALLER_IDENTITY" "$PKG"
rm -rf "$PKG_ROOT" "$PKG_SCRIPTS" "$BUILD_DIR/kd100.zip"

echo "==> Notarizing installer package"
xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$PKG"

echo "==> Done. release-build/ contains kd100.app and $(basename "$PKG")"
