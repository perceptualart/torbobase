#!/usr/bin/env python3
"""
Torbo Base — App Icon Generator
Multi-layer orb icon with aurora effects and macOS superellipse mask.
© 2026 Perceptual Art LLC / Michael David Murphy
"""
import struct, zlib, math, sys, os, shutil


def create_png(width, height, pixels):
    raw = b''
    for y in range(height):
        raw += b'\x00'
        for x in range(width):
            r, g, b, a = pixels[y * width + x]
            raw += struct.pack('BBBB', r, g, b, a)

    def chunk(ctype, data):
        c = ctype + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

    sig = b'\x89PNG\r\n\x1a\n'
    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    return sig + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')


def lerp(a, b, t):  return a + (b - a) * t
def clamp(v):        return max(0, min(255, int(v)))

def smoothstep(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0))) if e1 != e0 else 0.0
    return t * t * (3.0 - 2.0 * t)


def generate_orb_icon(size):
    pixels = []
    cx, cy = size / 2.0, size / 2.0
    radius = size * 0.34
    n_exp = 4.8

    for y in range(size):
        for x in range(size):
            nx = (x - cx) / (size * 0.44)
            ny = (y - cy) / (size * 0.44)
            sq = abs(nx) ** n_exp + abs(ny) ** n_exp
            if sq > 1.0:
                pixels.append((0, 0, 0, 0)); continue

            edge_aa = smoothstep(1.0, 0.96, sq)
            dx, dy = x - cx, y - cy
            dist = math.sqrt(dx * dx + dy * dy)
            norm = dist / radius
            angle = math.atan2(dy, dx)

            # Background
            bg_grad = y / size
            fr = lerp(16, 8, bg_grad)
            fg = lerp(16, 10, bg_grad)
            fb = lerp(22, 14, bg_grad)
            cg = max(0, 1.0 - norm * 0.6) ** 2
            fr += cg * 6; fg += cg * 12; fb += cg * 18

            # Aurora ribbons
            colors = [(0,200,240),(30,160,200),(100,60,200),(180,40,160),(220,20,90)]
            for i in range(5):
                wave = math.sin(angle * (2.2 + i*0.6) + i*1.257 + 0.5) * 0.5 + 0.5
                inten = max(0, 1 - abs(norm - (0.55 + i*0.15)) / (0.18 + i*0.04)) * wave * 0.3
                if inten > 0:
                    cr, cgg, cb = colors[i]
                    fr += cr*inten; fg += cgg*inten; fb += cb*inten

            # Core orb
            if norm < 1.0:
                t = norm; fo = smoothstep(1.0, 0.0, t)
                or_ = lerp(20, 110, t) * fo; og = lerp(230, 70, t) * fo; ob = lerp(255, 210, t) * fo
                oa = fo * 0.88
                inn = max(0, 1.0 - norm*3.0)**2
                or_ += inn*60; og += inn*80; ob += inn*40
                fr = lerp(fr, or_, oa); fg = lerp(fg, og, oa); fb = lerp(fb, ob, oa)
            elif norm < 1.35:
                fade = 1.0 - (norm - 1.0) / 0.35
                oa = fade*fade*0.25
                fr = lerp(fr, 0, oa); fg = lerp(fg, 160*fade*fade, oa); fb = lerp(fb, 210*fade*fade, oa)

            # Specular highlights
            hd = math.sqrt((x - cx + radius*0.3)**2 + (y - cy + radius*0.35)**2) / (radius*0.45)
            sp = max(0, 1.0 - hd) ** 3.5
            fr += sp*180; fg += sp*230; fb += sp*255
            hd2 = math.sqrt((x - cx - radius*0.22)**2 + (y - cy - radius*0.28)**2) / (radius*0.6)
            sp2 = max(0, 1.0 - hd2) ** 4
            fr += sp2*100; fg += sp2*30; fb += sp2*140

            # Access ring
            ri, ro = radius*1.05, radius*1.16
            if ri < dist < ro:
                rt = (dist - ri) / (ro - ri)
                ra = math.sin(rt * math.pi) * 0.55
                seg = ((angle + math.pi) / (2*math.pi)) * 6.0
                sf = seg % 1.0
                ra *= smoothstep(0.0, 0.06, sf) * smoothstep(1.0, 0.94, sf)
                fr = lerp(fr, 0, ra); fg = lerp(fg, 220, ra); fb = lerp(fb, 255, ra)

            pixels.append((clamp(fr), clamp(fg), clamp(fb), clamp(255 * edge_aa)))
    return pixels


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dist")
    iconset = os.path.join(out, "TorboBase.iconset")
    os.makedirs(iconset, exist_ok=True)

    for s in [16, 32, 64, 128, 256, 512, 1024]:
        print(f"  {s}x{s} ...", end=" ", flush=True)
        data = create_png(s, s, generate_orb_icon(s))
        with open(os.path.join(iconset, f"icon_{s}x{s}.png"), "wb") as f:
            f.write(data)
        print("\u2713")

    for s in [16, 32, 128, 256, 512]:
        src = os.path.join(iconset, f"icon_{s*2}x{s*2}.png")
        dst = os.path.join(iconset, f"icon_{s}x{s}@2x.png")
        if os.path.exists(src): shutil.copy2(src, dst)

    print(f"\n  Iconset ready: {iconset}")
    print("  Run:  iconutil -c icns ORBBase.iconset -o AppIcon.icns")


if __name__ == "__main__":
    main()
