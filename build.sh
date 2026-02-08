#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="ORB Base"
BUNDLE_NAME="ORBBase"
VERSION="2.0.0"
BUILD_DIR="${SCRIPT_DIR}/.build"
DIST_DIR="${SCRIPT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
DMG_NAME="ORBBase-${VERSION}"
DMG_PATH="${DIST_DIR}/${DMG_NAME}.dmg"
ENTITLEMENTS="${SCRIPT_DIR}/Resources/ORBBase.entitlements"

echo ""
echo "  ╔═══════════════════════════════════════╗"
echo "  ║   ORB BASE v${VERSION}                    ║"
echo "  ║   Build · Sign · Package              ║"
echo "  ║   © 2026 Perceptual Art LLC           ║"
echo "  ╚═══════════════════════════════════════╝"
echo ""

# ─── Step 1: Compile ─────────────────────────────────────
echo "▸ [1/6] Compiling..."
cd "${SCRIPT_DIR}"
swift build -c release 2>&1 | tail -5
echo "  ✓ Build complete"

# ─── Step 2: Locate binary ──────────────────────────────
BINARY=$(find "${BUILD_DIR}" -name "${BUNDLE_NAME}" -type f -perm +111 2>/dev/null | head -1)
if [[ -z "${BINARY}" ]]; then
    echo "  ✗ Binary not found"; exit 1
fi
echo "  ✓ Binary: $(basename "${BINARY}")"

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

ICON_SCRIPT="${SCRIPT_DIR}/scripts/generate_icon.py"
ICONSET="${DIST_DIR}/ORBBase.iconset"
ICNS="${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

if [[ -f "${ICON_SCRIPT}" ]]; then
    python3 "${ICON_SCRIPT}" "${DIST_DIR}" 2>&1 | sed 's/^/  /'
    if [[ -d "${ICONSET}" ]] && command -v iconutil &>/dev/null; then
        iconutil -c icns "${ICONSET}" -o "${ICNS}" 2>/dev/null && \
            echo "  ✓ AppIcon.icns generated" || \
            echo "  ⚠ iconutil failed — using fallback"
    fi
    rm -rf "${ICONSET}"
else
    # Fallback: inline minimal icon generator
    echo "  ⚠ Icon script missing, using inline generator"
    mkdir -p "${ICONSET}"
    for size in 16 32 64 128 256 512 1024; do
        python3 -c "
import struct, zlib, math
def gen(s):
    px=[]; cx=s/2.0; r=s*0.38
    for y in range(s):
        for x in range(s):
            dx,dy=x-cx,y-cx; d=math.sqrt(dx*dx+dy*dy)
            if d>r*1.3: px.append((0,0,0,0)); continue
            if d>r: t=1-(d-r)/(r*0.3); px.append((0,int(180*t),int(220*t),int(80*t))); continue
            t=d/r; R=int(t*168); G=int(t*85+(1-t)*229); B=int(t*247+(1-t)*255)
            hd=math.sqrt((x-cx+r*0.25)**2+(y-cx+r*0.25)**2)/(r*0.6); hl=max(0,1-hd)
            px.append((min(255,R+int(hl*80)),min(255,G+int(hl*80)),min(255,B+int(hl*80)),255))
    return px
def png(w,h,px):
    raw=b''
    for y in range(h):
        raw+=b'\\x00'
        for x in range(w): raw+=struct.pack('BBBB',*px[y*w+x])
    def c(t,d): z=t+d; return struct.pack('>I',len(d))+z+struct.pack('>I',zlib.crc32(z)&0xffffffff)
    return b'\\x89PNG\\r\\n\\x1a\\n'+c(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+c(b'IDAT',zlib.compress(raw,9))+c(b'IEND',b'')
with open('${ICONSET}/icon_${size}x${size}.png','wb') as f: f.write(png(${size},${size},gen(${size})))
" 2>/dev/null || true
    done
    for size in 16 32 128 256 512; do
        d=$((size*2))
        [[ -f "${ICONSET}/icon_${d}x${d}.png" ]] && cp "${ICONSET}/icon_${d}x${d}.png" "${ICONSET}/icon_${size}x${size}@2x.png"
    done
    if command -v iconutil &>/dev/null; then
        iconutil -c icns "${ICONSET}" -o "${ICNS}" 2>/dev/null || true
    fi
    rm -rf "${ICONSET}"
fi

[[ -f "${ICNS}" ]] && echo "  ✓ App icon ready" || echo "  ⚠ No icon (cosmetic only)"

# ─── Step 5: Code sign ──────────────────────────────────
echo ""
echo "▸ [4/6] Code signing..."

# Try to find a Developer ID first, fall back to ad-hoc
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)

if [[ -n "${IDENTITY}" ]]; then
    echo "  Found: ${IDENTITY}"
    codesign --force --deep --options runtime \
        --entitlements "${ENTITLEMENTS}" \
        --sign "${IDENTITY}" "${APP_BUNDLE}" 2>/dev/null && \
        echo "  ✓ Signed with Developer ID" || {
            echo "  ⚠ Developer ID signing failed, using ad-hoc"
            codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || true
            echo "  ✓ Ad-hoc signed"
        }
else
    if [[ -f "${ENTITLEMENTS}" ]]; then
        codesign --force --deep --entitlements "${ENTITLEMENTS}" --sign - "${APP_BUNDLE}" 2>/dev/null || true
    else
        codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || true
    fi
    echo "  ✓ Ad-hoc signed (no Developer ID found)"
fi

# Verify
codesign --verify --verbose "${APP_BUNDLE}" 2>&1 | tail -1 | sed 's/^/  /' || true

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
║          ORB BASE v2.0.0                 ║
║    Local AI Gateway & Control Center     ║
║    © 2026 Perceptual Art LLC             ║
╚══════════════════════════════════════════╝

INSTALLATION
  Drag "ORB Base" → Applications folder.

FIRST LAUNCH
  1. Open ORB Base from Applications
  2. Accept the EULA and complete Setup Wizard
  3. Install Ollama if not already installed
  4. Pull your first local AI model
  5. Pair your iPhone via the Home tab

REQUIREMENTS
  • macOS 14.0 (Sonoma) or later
  • Apple Silicon or Intel Mac
  • Ollama (https://ollama.com) for local models
  • Optional: Anthropic / OpenAI / Google API keys
    for cloud model routing

WEB CHAT
  http://localhost:4200/chat?token=YOUR_TOKEN

PRIVACY
  ORB Base collects ZERO data.
  All AI processing stays on your device.
  API keys stored in macOS Keychain.

SUPPORT
  https://orbbase.ai
README

# Create writable DMG first
rm -f "${DMG_PATH}"
hdiutil create \
    -volname "ORB Base" \
    -srcfolder "${DMG_STAGING}" \
    -ov -format UDRW \
    "${DMG_TMP}" 2>/dev/null

# Mount and style
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "${DMG_TMP}" 2>/dev/null | grep "/Volumes" | tail -1 | awk '{print $NF}')

if [[ -n "${MOUNT_DIR}" && -d "${MOUNT_DIR}" ]]; then
    # Use AppleScript to style the DMG Finder window
    osascript << APPLESCRIPT 2>/dev/null || true
tell application "Finder"
    tell disk "ORB Base"
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
        set position of item "ORB Base.app" of container window to {160, 190}
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
echo "  Bundle ID: ai.orb.base"
echo "  Min macOS: 14.0"
echo ""
echo "  ╔═══════════════════════════════════════╗"
echo "  ║   BUILD COMPLETE                      ║"
echo "  ╠═══════════════════════════════════════╣"
echo "  ║   App: dist/ORB Base.app              ║"
echo "  ║   DMG: dist/${DMG_NAME}.dmg       ║"
echo "  ╠═══════════════════════════════════════╣"
echo "  ║   open dist/ORB\\ Base.app             ║"
echo "  ║   open dist/${DMG_NAME}.dmg       ║"
echo "  ╚═══════════════════════════════════════╝"
echo ""
