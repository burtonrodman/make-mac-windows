#!/bin/bash
# Builds PCMode and assembles it into a proper .app bundle (a bare SwiftPM
# executable can't get LSUIElement no-dock-icon behavior or a stable identity
# for Accessibility permission grants).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="PCMode"
BUNDLE_ID="com.burtonrodman.pcmode"
BUILD_DIR=".build/release"
APP_BUNDLE="dist/${APP_NAME}.app"

swift build -c release

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Sign with a stable local identity so TCC (Accessibility permission) keeps
# trusting PCMode across rebuilds. Ad-hoc signing (`--sign -`) recomputes a
# brand-new signature every build, which makes macOS treat each rebuild as a
# different, never-approved app and silently stop delivering events to it.
#
# "PCMode Dev Signing" is a self-signed certificate created once via:
#   openssl req -x509 -newkey rsa:2048 -keyout pcmode-dev.key -out pcmode-dev.crt \
#     -days 3650 -nodes -subj "/CN=PCMode Dev Signing" \
#     -addext "keyUsage=critical,digitalSignature" \
#     -addext "extendedKeyUsage=critical,codeSigning" \
#     -addext "basicConstraints=critical,CA:true"
#   openssl pkcs12 -export -out pcmode-dev.p12 -inkey pcmode-dev.key -in pcmode-dev.crt \
#     -passout pass:temporary123 -legacy   # -legacy: macOS needs SHA1/3DES PKCS12
#   security import pcmode-dev.p12 -k ~/Library/Keychains/login.keychain-db \
#     -P temporary123 -T /usr/bin/codesign -A
#   security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db pcmode-dev.crt
SIGNING_IDENTITY="PCMode Dev Signing"
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
