#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════
# Torbo Base — Release Build, Sign, DMG, Notarize
# ═══════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Torbo Base"
BUNDLE_ID="com.perceptualart.torbobase"
TEAM_ID="${TORBO_TEAM_ID:-}"
SIGNING_IDENTITY="${TORBO_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${TORBO_NOTARY_PROFILE:-notarytool}"

# Auto-detect signing identity if not set
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)
    if [ -z "$SIGNING_IDENTITY" ]; then
        echo "✗ No Developer ID Application certificate found."
        echo "  Set TORBO_SIGNING_IDENTITY or install a Developer ID cert."
        exit 1
    fi
    TEAM_ID=$(echo "$SIGNING_IDENTITY" | grep -o '([A-Z0-9]*)' | tr -d '()')
fi

DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
DMG_NAME="TorboBase"
DMG_PATH="$DIST_DIR/$DMG_NAME.dmg"
VERSION=$(date +"%Y.%m.%d")

echo "═══════════════════════════════════════════"
echo "  Building $APP_NAME v$VERSION"
echo "═══════════════════════════════════════════"
echo ""

# ─── 1. Clean & Build Release ───
echo "▸ Building release binary..."
cd "$PROJECT_DIR"
swift build -c release 2>&1 | tail -3
BINARY="$PROJECT_DIR/.build/release/TorboBase"

if [ ! -f "$BINARY" ]; then
    echo "✗ Build failed — binary not found"
    exit 1
fi
echo "✓ Binary built: $(du -h "$BINARY" | awk '{print $1}')"

# ─── 2. Create App Bundle ───
echo ""
echo "▸ Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_DIR/Contents/MacOS/TorboBase"

# Copy icon if it exists
ICON_SRC="$DIST_DIR/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
    ICON_LINE="<key>CFBundleIconFile</key>
	<string>AppIcon</string>"
else
    ICON_LINE=""
    echo "  ⚠ No AppIcon.icns found — using default icon"
fi

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>TorboBase</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>LSUIElement</key>
	<false/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Torbo Base needs microphone access for voice chat transcription.</string>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Torbo Base uses the local network to serve AI requests to your devices.</string>
	<key>NSBonjourServices</key>
	<array>
		<string>_torbobase._tcp</string>
	</array>
	$ICON_LINE
</dict>
</plist>
PLIST

echo "✓ App bundle created"

# ─── 3. Code Sign ───
echo ""
echo "▸ Code signing with: $SIGNING_IDENTITY"

# Sign the binary with hardened runtime + entitlements
cat > /tmp/torbobase-entitlements.plist << 'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
	<true/>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.device.audio-input</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
</dict>
</plist>
ENT

codesign --force --options runtime \
    --sign "$SIGNING_IDENTITY" \
    --entitlements /tmp/torbobase-entitlements.plist \
    --timestamp \
    "$APP_DIR"

# Verify
codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>&1 | tail -3
echo "✓ Code signed"

# ─── 4. Create DMG ───
echo ""
echo "▸ Creating DMG..."
rm -f "$DMG_PATH"

# Create a temporary DMG with the app + Applications symlink
STAGING="$DIST_DIR/.dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH" 2>&1 | tail -2

rm -rf "$STAGING"

# Sign the DMG
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
echo "✓ DMG created: $(du -h "$DMG_PATH" | awk '{print $1}')"

# ─── 5. Notarize ───
echo ""
echo "▸ Submitting for notarization..."
echo "  (This can take 2-10 minutes)"

SUBMIT_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait 2>&1) || true

echo "$SUBMIT_OUTPUT" | tail -5

# Check if notarization succeeded
if echo "$SUBMIT_OUTPUT" | grep -q "status: Accepted"; then
    echo ""
    echo "▸ Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"
    echo "✓ Notarized and stapled"
else
    echo ""
    echo "⚠ Notarization may have failed. Check output above."
    echo "  To check status: xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
    echo "  You can still distribute the DMG — macOS will check notarization online."
fi

# ─── Done ───
echo ""
echo "═══════════════════════════════════════════"
echo "  ✓ $APP_NAME v$VERSION"
echo "  ✓ DMG: $DMG_PATH"
echo "  ✓ Size: $(du -h "$DMG_PATH" | awk '{print $1}')"
echo "═══════════════════════════════════════════"
