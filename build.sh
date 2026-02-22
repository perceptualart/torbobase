#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Torbo Base"
BUNDLE_NAME="TorboBase"
VERSION="${VERSION:-3.1.0}"
BUILD_DIR="${SCRIPT_DIR}/.build"
DIST_DIR="${SCRIPT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
DMG_NAME="TorboBase-${VERSION}"
DMG_PATH="${DIST_DIR}/${DMG_NAME}.dmg"
ENTITLEMENTS="${SCRIPT_DIR}/Resources/TorboBase.entitlements"

echo ""
echo "  ╔═══════════════════════════════════════╗"
echo "  ║   TORBO BASE v${VERSION}                  ║"
echo "  ║   Build · Sign · Package              ║"
echo "  ║   © 2026 Perceptual Art LLC           ║"
echo "  ╚═══════════════════════════════════════╝"
echo ""

# ─── Step 1: Compile (Universal Binary) ────────────────────
echo "▸ [1/6] Compiling universal binary (arm64 + x86_64)..."
cd "${SCRIPT_DIR}"
swift build -c release --arch arm64 --arch x86_64 2>&1 | tail -5
echo "  ✓ Universal build complete"

# ─── Step 2: Locate universal binary ─────────────────────
# The universal binary is at .build/apple/Products/Release/ — NOT in the
# architecture-specific intermediate dirs. Use the Products path first.
BINARY="${BUILD_DIR}/apple/Products/Release/${BUNDLE_NAME}"
if [[ ! -f "${BINARY}" ]]; then
    # Fallback: search for any executable
    BINARY=$(find "${BUILD_DIR}" -name "${BUNDLE_NAME}" -path "*/Products/*" -type f -perm +111 2>/dev/null | head -1)
fi
if [[ -z "${BINARY}" || ! -f "${BINARY}" ]]; then
    echo "  ✗ Binary not found"; exit 1
fi
# Verify it's universal
ARCHES=$(file "${BINARY}" | grep -o 'arm64\|x86_64' | tr '\n' '+' | sed 's/+$//')
echo "  ✓ Binary: $(basename "${BINARY}") [${ARCHES}] ($(du -h "${BINARY}" | awk '{print $1}'))"

# ─── Step 3: App bundle ─────────────────────────────────
echo ""
echo "▸ [2/6] Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
cp "${BINARY}" "${APP_BUNDLE}/Contents/MacOS/${BUNDLE_NAME}"
cp "${SCRIPT_DIR}/Resources/Info.plist" "${APP_BUNDLE}/Contents/"
echo -n "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"
echo "  ✓ ${APP_NAME}.app created"

# ─── Step 4: App icon ───────────────────────────────────
echo ""
echo "▸ [3/6] Generating app icon..."

ICON_SOURCE="${SCRIPT_DIR}/Resources/AppIcon-source.png"
ICONSET="${DIST_DIR}/TorboBase.iconset"
ICNS="${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

if [[ -f "${ICON_SOURCE}" ]]; then
    # Use the real orb image — resize with sips to all required sizes
    rm -rf "${ICONSET}"
    mkdir -p "${ICONSET}"
    for size in 16 32 64 128 256 512 1024; do
        sips -z ${size} ${size} "${ICON_SOURCE}" --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null 2>&1
        echo "  ${size}x${size} ✓"
    done
    # Create @2x retina variants (just copies of the 2x resolution)
    for size in 16 32 128 256 512; do
        d=$((size*2))
        [[ -f "${ICONSET}/icon_${d}x${d}.png" ]] && cp "${ICONSET}/icon_${d}x${d}.png" "${ICONSET}/icon_${size}x${size}@2x.png"
    done
    # Compile iconset to icns
    if command -v iconutil &>/dev/null; then
        iconutil -c icns "${ICONSET}" -o "${ICNS}" 2>/dev/null && \
            echo "  ✓ AppIcon.icns compiled from orb image" || \
            echo "  ⚠ iconutil failed"
    fi
    # Also copy to dist for reuse
    [[ -f "${ICNS}" ]] && cp "${ICNS}" "${DIST_DIR}/AppIcon.icns"
    rm -rf "${ICONSET}"
else
    # Fallback: use procedural generator
    echo "  ⚠ AppIcon-source.png missing, falling back to procedural icon"
    ICON_SCRIPT="${SCRIPT_DIR}/scripts/generate_icon.py"
    if [[ -f "${ICON_SCRIPT}" ]]; then
        python3 "${ICON_SCRIPT}" "${DIST_DIR}" 2>&1 | sed 's/^/  /'
        ICONSET="${DIST_DIR}/TorboBase.iconset"
        if [[ -d "${ICONSET}" ]] && command -v iconutil &>/dev/null; then
            iconutil -c icns "${ICONSET}" -o "${ICNS}" 2>/dev/null || true
        fi
        rm -rf "${ICONSET}"
    fi
fi

if [[ -f "${ICNS}" ]]; then
    echo "  ✓ App icon ready"
else
    echo "  ⚠ No icon generated — removing CFBundleIconFile from Info.plist to prevent signature issues"
    # Remove icon references so codesign doesn't expect a missing resource
    /usr/bin/plutil -remove CFBundleIconFile "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null || true
    /usr/bin/plutil -remove CFBundleIconName "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null || true
fi

# ─── Step 5: Code sign ──────────────────────────────────
echo ""
echo "▸ [4/6] Code signing..."

# Try to find a Developer ID Application identity
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" \
    | head -1 \
    | sed 's/.*"\(.*\)"/\1/' || true)

SIGN_OK=false

if [[ -n "${IDENTITY}" ]]; then
    echo "  Found: ${IDENTITY}"

    # Sign the binary FIRST (inside-out signing for hardened runtime)
    echo "  Signing binary..."
    if [[ -f "${ENTITLEMENTS}" ]]; then
        codesign --force --options runtime \
            --entitlements "${ENTITLEMENTS}" \
            --sign "${IDENTITY}" \
            "${APP_BUNDLE}/Contents/MacOS/${BUNDLE_NAME}" 2>&1 | sed 's/^/  /' && SIGN_OK=true || true
    fi

    # Then sign the bundle (seals all resources)
    if ${SIGN_OK}; then
        echo "  Signing app bundle..."
        codesign --force --options runtime \
            --entitlements "${ENTITLEMENTS}" \
            --sign "${IDENTITY}" \
            "${APP_BUNDLE}" 2>&1 | sed 's/^/  /' && \
            echo "  ✓ Signed with Developer ID (hardened runtime)" || {
                echo "  ⚠ Bundle signing failed"
                SIGN_OK=false
            }
    fi

    if ! ${SIGN_OK}; then
        echo "  ⚠ Developer ID signing failed, falling back to ad-hoc"
    fi
fi

# Ad-hoc fallback
if ! ${SIGN_OK}; then
    echo "  Using ad-hoc signing (Gatekeeper will warn users)..."
    if [[ -f "${ENTITLEMENTS}" ]]; then
        codesign --force --deep --entitlements "${ENTITLEMENTS}" --sign - "${APP_BUNDLE}" 2>/dev/null || true
    else
        codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || true
    fi
    echo "  ✓ Ad-hoc signed (users will need to right-click → Open on first launch)"
fi

# Verify signature
echo "  Verifying..."
codesign --verify --verbose=2 "${APP_BUNDLE}" 2>&1 | sed 's/^/  /'
if [[ $? -ne 0 ]]; then
    echo "  ⚠ Signature verification reported issues (may still work)"
fi

# ─── Step 6: DMG ────────────────────────────────────────
echo ""
echo "▸ [5/6] Creating DMG installer..."

DMG_STAGING="${DIST_DIR}/dmg-staging"
DMG_TMP="${DIST_DIR}/${DMG_NAME}-tmp.dmg"
rm -rf "${DMG_STAGING}" "${DMG_TMP}"
mkdir -p "${DMG_STAGING}"

cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"

# Hidden metadata dir for background
mkdir -p "${DMG_STAGING}/.background"

# Generate DMG background image
python3 -c "
import struct, zlib, math
def lerp(a,b,t): return a+(b-a)*t
def clamp(v): return max(0,min(255,int(v)))
def png(w,h,px):
    raw=b''
    for y in range(h):
        raw+=b'\\x00'
        for x in range(w): raw+=struct.pack('BBBB',*px[y*w+x])
    def c(t,d): z=t+d; return struct.pack('>I',len(d))+z+struct.pack('>I',zlib.crc32(z)&0xffffffff)
    return b'\\x89PNG\\r\\n\\x1a\\n'+c(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+c(b'IDAT',zlib.compress(raw,9))+c(b'IEND',b'')
w,h=660,400; px=[]
for y in range(h):
    for x in range(w):
        t=y/h; r=lerp(14,8,t); g=lerp(14,10,t); b=lerp(22,14,t)
        dx=(x-w/2)/w; dy=(y-h*0.3)/h; rd=max(0,1-math.sqrt(dx*dx+dy*dy)*1.8)
        r+=rd*10; g+=rd*16; b+=rd*22
        if y<h*0.35:
            wt=y/(h*0.35); wv=math.sin(x/w*6+1.5)*0.5+0.5; a=wv*(1-wt)*0.12
            g+=a*70; b+=a*90
        px.append((clamp(r),clamp(g),clamp(b),255))
with open('${DMG_STAGING}/.background/bg.png','wb') as f: f.write(png(w,h,px))
" 2>/dev/null || echo "  ⚠ Background generation skipped"

# Create README
cat > "${DMG_STAGING}/README.txt" << 'README'
╔══════════════════════════════════════════╗
║          TORBO BASE v3.0.0               ║
║    Local AI Gateway & Control Center     ║
║    © 2026 Perceptual Art LLC             ║
╚══════════════════════════════════════════╝

INSTALLATION
  Drag "Torbo Base" → Applications folder.

FIRST LAUNCH
  1. Open Torbo Base from Applications
  2. Accept the EULA and complete Setup Wizard
  3. Install Ollama if not already installed
  4. Pull your first local AI model
  5. Pair your iPhone via the Home tab

REQUIREMENTS
  • macOS 13.0 (Ventura) or later
  • Apple Silicon or Intel Mac
  • Ollama (https://ollama.com) for local models
  • Optional: Anthropic / OpenAI / Google API keys
    for cloud model routing

WEB CHAT
  http://localhost:4200/chat?token=YOUR_TOKEN

PRIVACY
  Torbo Base collects ZERO data.
  All AI processing stays on your device.
  API keys stored in macOS Keychain.

SUPPORT
  https://torbobase.ai
README

# Create writable DMG first
rm -f "${DMG_PATH}"
hdiutil create \
    -volname "Torbo Base" \
    -srcfolder "${DMG_STAGING}" \
    -ov -format UDRW \
    "${DMG_TMP}" 2>/dev/null

# Mount and style
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "${DMG_TMP}" 2>/dev/null | grep "/Volumes" | tail -1 | awk '{print $NF}')

if [[ -n "${MOUNT_DIR}" && -d "${MOUNT_DIR}" ]]; then
    # Use AppleScript to style the DMG Finder window
    osascript << APPLESCRIPT 2>/dev/null || true
tell application "Finder"
    tell disk "Torbo Base"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 860, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 80
        try
            set background picture of theViewOptions to file ".background:bg.png"
        end try
        set position of item "Torbo Base.app" of container window to {160, 190}
        set position of item "Applications" of container window to {500, 190}
        try
            set position of item "README.txt" of container window to {330, 330}
        end try
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
    echo "  ✓ DMG window styled"

    # Eject
    sync
    hdiutil detach "${MOUNT_DIR}" 2>/dev/null || hdiutil detach "${MOUNT_DIR}" -force 2>/dev/null || true
fi

# Convert to compressed read-only DMG
hdiutil convert "${DMG_TMP}" -format UDBZ -o "${DMG_PATH}" 2>/dev/null
rm -f "${DMG_TMP}"
rm -rf "${DMG_STAGING}"

if [[ -f "${DMG_PATH}" ]]; then
    DMG_SIZE=$(du -h "${DMG_PATH}" | awk '{print $1}')
    echo "  ✓ DMG: ${DMG_PATH} (${DMG_SIZE})"
else
    echo "  ✗ DMG creation failed"; exit 1
fi

# ─── Summary ────────────────────────────────────────────
echo ""
echo "▸ [6/6] Verifying..."
APP_SIZE=$(du -sh "${APP_BUNDLE}" | awk '{print $1}')
echo "  App size: ${APP_SIZE}"
echo "  Bundle ID: ai.torbo.base"
echo "  Min macOS: 13.0"
echo ""
echo "  ╔═══════════════════════════════════════╗"
echo "  ║   BUILD COMPLETE                      ║"
echo "  ╠═══════════════════════════════════════╣"
echo "  ║   App: dist/Torbo Base.app            ║"
echo "  ║   DMG: dist/${DMG_NAME}.dmg       ║"
echo "  ╠═══════════════════════════════════════╣"
echo "  ║   open dist/Torbo\\ Base.app           ║"
echo "  ║   open dist/${DMG_NAME}.dmg       ║"
echo "  ╚═══════════════════════════════════════╝"
echo ""
