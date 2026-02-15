#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════
# Torbo Base — Release Build, Sign, DMG, Notarize
# ═══════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Torbo Base"
BUNDLE_NAME="TorboBase"
BUNDLE_ID="ai.torbo.base"
TEAM_ID="${TORBO_TEAM_ID:-}"
SIGNING_IDENTITY="${TORBO_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${TORBO_NOTARY_PROFILE:-notarytool}"
ENTITLEMENTS="$PROJECT_DIR/Resources/TorboBase.entitlements"
INFO_PLIST_TEMPLATE="$PROJECT_DIR/Resources/Info.plist"

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
echo "  Identity: $SIGNING_IDENTITY"
echo "═══════════════════════════════════════════"
echo ""

# ─── 1. Clean & Build Universal Release ───
echo "▸ [1/5] Building universal binary (arm64 + x86_64)..."
cd "$PROJECT_DIR"
swift build -c release --arch arm64 --arch x86_64 2>&1 | tail -5

# Universal binary is at .build/apple/Products/Release/ (NOT intermediate dirs)
BINARY="$PROJECT_DIR/.build/apple/Products/Release/$BUNDLE_NAME"
if [ ! -f "$BINARY" ]; then
    BINARY=$(find "$PROJECT_DIR/.build" -name "$BUNDLE_NAME" -path "*/Products/*" -type f -perm +111 2>/dev/null | head -1)
fi

if [ -z "$BINARY" ] || [ ! -f "$BINARY" ]; then
    echo "✗ Build failed — binary not found"
    exit 1
fi

# Verify it's universal
ARCHES=$(file "$BINARY" | grep -o 'arm64\|x86_64' | tr '\n' ' ')
echo "✓ Binary built: $(du -h "$BINARY" | awk '{print $1}') [$ARCHES]"

# ─── 2. Create App Bundle ───
echo ""
echo "▸ [2/5] Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_DIR/Contents/MacOS/$BUNDLE_NAME"

# Copy Info.plist from the canonical template (single source of truth)
cp "$INFO_PLIST_TEMPLATE" "$APP_DIR/Contents/Info.plist"

# Inject dynamic version
/usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_DIR/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$VERSION" "$APP_DIR/Contents/Info.plist"

# PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Copy icon if it exists
ICON_SRC="$DIST_DIR/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
    echo "  ✓ App icon copied"
else
    echo "  ⚠ No AppIcon.icns found — removing icon refs from Info.plist"
    /usr/bin/plutil -remove CFBundleIconFile "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
    /usr/bin/plutil -remove CFBundleIconName "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
fi

echo "✓ App bundle created (bundle ID: $BUNDLE_ID)"

# ─── 3. Code Sign (inside-out: binary first, then bundle) ───
echo ""
echo "▸ [3/5] Code signing with: $SIGNING_IDENTITY"

# Sign the binary FIRST (inside-out for hardened runtime)
echo "  Signing binary..."
codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" \
    --timestamp \
    "$APP_DIR/Contents/MacOS/$BUNDLE_NAME"

# Then sign the bundle (seals all resources including Info.plist)
echo "  Signing app bundle..."
codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" \
    --timestamp \
    "$APP_DIR"

# Verify
echo "  Verifying..."
codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>&1 | tail -3
echo "✓ Code signed and verified"

# ─── 4. Create DMG ───
echo ""
echo "▸ [4/5] Creating DMG..."
rm -f "$DMG_PATH"

# Strip xattrs (com.apple.provenance, com.apple.quarantine, com.apple.FinderInfo)
# These cause TCC "Operation not permitted" errors and codesign --strict warnings
xattr -rc "$APP_DIR" 2>/dev/null

# Create staging with clean app + Applications symlink
STAGING="$DIST_DIR/.dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
# Use tar --no-xattrs to copy without carrying over any macOS metadata
cd "$DIST_DIR"
tar cf - --no-xattrs --no-mac-metadata "$APP_NAME.app" | (cd "$STAGING" && tar xf -)
ln -s /Applications "$STAGING/Applications"

# Create DMG using makehybrid (avoids TCC issues with hdiutil create -srcfolder
# which internally mounts a volume and may be blocked by Gatekeeper/TCC)
DMG_RAW="$DIST_DIR/${DMG_NAME}-raw.dmg"
rm -f "$DMG_RAW"
hdiutil makehybrid -hfs -o "$DMG_RAW" "$STAGING" -hfs-volume-name "TorboBase" 2>&1 | tail -2

# Compress to UDZO format (typically 70%+ savings)
hdiutil convert "$DMG_RAW" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" 2>&1 | tail -2
rm -f "$DMG_RAW"
rm -rf "$STAGING"

# Sign the DMG
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
echo "✓ DMG created: $(du -h "$DMG_PATH" | awk '{print $1}')"

# ─── 5. Notarize ───
echo ""
echo "▸ [5/5] Submitting for notarization..."
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
echo "  ✓ Bundle ID: $BUNDLE_ID"
echo "═══════════════════════════════════════════"
