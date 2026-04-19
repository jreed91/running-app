#!/usr/bin/env python3
"""Generate RunningApp icon PNGs – pure Python stdlib, no external deps."""
import struct, zlib, os, math

OUTDIR = "RunningApp/Resources/Assets.xcassets/AppIcon.appiconset"

# ── PNG writer ────────────────────────────────────────────────────────────────

def write_png(path, data, w, h):
    def chunk(tag, body):
        crc = zlib.crc32(tag + body) & 0xFFFFFFFF
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", crc)

    raw = bytearray()
    stride = w * 3
    for y in range(h):
        raw.append(0)
        raw += data[y * stride:(y + 1) * stride]

    out = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(out)


# ── Geometry helpers ──────────────────────────────────────────────────────────

def _seg_dist2(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    len2 = dx * dx + dy * dy
    if len2 == 0:
        return (px - ax) ** 2 + (py - ay) ** 2
    t = ((px - ax) * dx + (py - ay) * dy) / len2
    if t < 0.0: t = 0.0
    elif t > 1.0: t = 1.0
    cx, cy = ax + t * dx, ay + t * dy
    return (px - cx) ** 2 + (py - cy) ** 2


# ── Icon renderer ─────────────────────────────────────────────────────────────
# All shape coordinates are defined on a 1024×1024 canvas, then scaled.
#
# Running figure pose: leaning forward, right arm forward, left arm back,
# right knee lifted, left leg pushing off.

HEAD = (545, 192, 92)  # (cx, cy, r)

# Capsule limbs: (ax, ay, bx, by, r)
PARTS = [
    # ── torso (forward lean) ──────────────────────────────────────────────────
    (545, 284, 503, 578, 62),
    # ── right arm upper (swings forward-down) ─────────────────────────────────
    (523, 428, 668, 542, 44),
    # ── right forearm ─────────────────────────────────────────────────────────
    (668, 542, 714, 676, 39),
    # ── left arm upper (swings back-up) ──────────────────────────────────────
    (523, 428, 384, 322, 44),
    # ── left forearm ─────────────────────────────────────────────────────────
    (384, 322, 352, 208, 39),
    # ── right thigh (forward, knee high) ─────────────────────────────────────
    (503, 578, 612, 758, 54),
    # ── right shin (bent forward) ────────────────────────────────────────────
    (612, 758, 570, 934, 49),
    # ── left thigh (back, push-off) ──────────────────────────────────────────
    (503, 578, 352, 748, 54),
    # ── left shin ────────────────────────────────────────────────────────────
    (352, 748, 292, 908, 49),
]

# Background gradient: brand orange top → deep orange-red bottom
BG_TOP = (255, 112, 36)   # #FF7024
BG_BOT = (204,  56,  6)   # #CC3806


def _lerp_int(a, b, t):
    return int(a + (b - a) * t)


def generate(size):
    sc = size / 1024.0
    aa = max(0.6, sc * 1.2)          # anti-alias half-width in pixels

    hcx = HEAD[0] * sc
    hcy = HEAD[1] * sc
    hr  = HEAD[2] * sc

    sparts = [(ax*sc, ay*sc, bx*sc, by*sc, r*sc) for ax, ay, bx, by, r in PARTS]

    # Pre-compute bounding boxes for early rejection (padded by r+aa)
    bboxes = []
    for ax, ay, bx, by, r in sparts:
        pad = r + aa + 1
        bboxes.append((min(ax,bx)-pad, min(ay,by)-pad, max(ax,bx)+pad, max(ay,by)+pad))
    # Head bbox
    hpad = hr + aa + 1
    head_bbox = (hcx-hpad, hcy-hpad, hcx+hpad, hcy+hpad)

    pixels = bytearray(size * size * 3)

    for y in range(size):
        t = y / max(size - 1, 1)
        bgr = _lerp_int(BG_TOP[0], BG_BOT[0], t)
        bgg = _lerp_int(BG_TOP[1], BG_BOT[1], t)
        bgb = _lerp_int(BG_TOP[2], BG_BOT[2], t)

        row = y * size * 3

        for x in range(size):
            # ── compute SDF (min signed distance to figure surface) ───────────
            # Negative = inside shape, positive = outside.

            # Fast reject: if outside all bounding boxes, skip SDF computation
            near = False
            if head_bbox[0] <= x <= head_bbox[2] and head_bbox[1] <= y <= head_bbox[3]:
                near = True
            if not near:
                for bx0, by0, bx1, by1 in bboxes:
                    if bx0 <= x <= bx1 and by0 <= y <= by1:
                        near = True
                        break

            if not near:
                idx = row + x * 3
                pixels[idx] = bgr; pixels[idx+1] = bgg; pixels[idx+2] = bgb
                continue

            # Head SDF
            min_d = math.sqrt((x - hcx)**2 + (y - hcy)**2) - hr

            # Parts SDF (union = minimum)
            for ax, ay, bx, by, r in sparts:
                d2 = _seg_dist2(x, y, ax, ay, bx, by)
                d  = math.sqrt(d2) - r
                if d < min_d:
                    min_d = d
                    if min_d < -aa:   # already deep inside, no need to keep checking
                        break

            # ── blend ─────────────────────────────────────────────────────────
            idx = row + x * 3
            if min_d <= -aa:
                pixels[idx] = 255; pixels[idx+1] = 255; pixels[idx+2] = 255
            elif min_d >= aa:
                pixels[idx] = bgr; pixels[idx+1] = bgg; pixels[idx+2] = bgb
            else:
                a = (aa - min_d) / (2 * aa)
                a = a * a * (3 - 2 * a)   # smoothstep
                pixels[idx]   = int(bgr + (255 - bgr) * a)
                pixels[idx+1] = int(bgg + (255 - bgg) * a)
                pixels[idx+2] = int(bgb + (255 - bgb) * a)

    return pixels


# ── Main ──────────────────────────────────────────────────────────────────────

SIZES = [
    ("Icon-20x20.png",   20),
    ("Icon-29x29.png",   29),
    ("Icon-40x40.png",   40),
    ("Icon-58x58.png",   58),
    ("Icon-60x60.png",   60),
    ("Icon-76x76.png",   76),
    ("Icon-80x80.png",   80),
    ("Icon-87x87.png",   87),
    ("Icon-120x120.png", 120),
    ("Icon-152x152.png", 152),
    ("Icon-167x167.png", 167),
    ("Icon-180x180.png", 180),
    ("Icon-1024x1024.png", 1024),
]

if __name__ == "__main__":
    os.makedirs(OUTDIR, exist_ok=True)
    for fname, sz in SIZES:
        path = os.path.join(OUTDIR, fname)
        print(f"  {fname} ({sz}×{sz})…", end=" ", flush=True)
        data = generate(sz)
        write_png(path, data, sz, sz)
        print("done")
    print("All icons generated.")
