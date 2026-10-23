#!/bin/zsh
# Builds VirtualScreen.app next to this script.
set -e
cd "$(dirname "$0")"

APP=VirtualScreen.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon (same symbol as the menu bar)
ICONSET="$(mktemp -d)/VirtualScreen.iconset"
swift Tools/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/VirtualScreen.icns"
rm -rf "$(dirname "$ICONSET")"

swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  -o "$APP/Contents/MacOS/VirtualScreen" \
  Sources/*.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>VirtualScreen</string>
    <key>CFBundleDisplayName</key><string>VirtualScreen</string>
    <key>CFBundleIdentifier</key><string>com.local.virtualscreen</string>
    <key>CFBundleExecutable</key><string>VirtualScreen</string>
    <key>CFBundleIconFile</key><string>VirtualScreen</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSScreenCaptureUsageDescription</key><string>VirtualScreen shows live views of the windows you pick.</string>
</dict>
</plist>
PLIST

# Sign with a stable local identity so macOS keeps the Screen Recording and Accessibility
# permissions across rebuilds (ad-hoc signatures change with every build).
IDENTITY="VirtualScreen Local Signing"
if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "Creating local code signing identity \"$IDENTITY\" in your login keychain…"
  TMP="$(mktemp -d)"
  cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:vs \
    -out "$TMP/id.p12" >/dev/null 2>&1
  security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P vs -T /usr/bin/codesign >/dev/null
  rm -rf "$TMP"
fi
xattr -cr "$APP"
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $(pwd)/$APP"
