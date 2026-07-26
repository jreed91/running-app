#!/usr/bin/env python3
"""
Generate Stride app icon PNGs.

Design from Stride Design System (app-icon.jsx):
  Background: diagonal linear gradient #FFA056 → #FF6B22 → #D23A12
  Glow:       radial warm overlay at top-left, cx=0.25 cy=0.10 r=0.9
  Shine:      top-half white fade (α 0.32 → 0)
  Motif:      white filled shape on 180×180 viewport
              M36 148 Q66 44 122 28 L140 28 Q86 46 60 150 Z

Emits three appearances at 1024×1024, which is the form the asset catalogue has
wanted since Xcode 14 — one master image per appearance, with the sizes derived at
build time, rather than the thirteen hand-listed slots this used to write:

  light   the design above, unchanged
  dark    the same motif on a darkened backdrop, for the dark home screen
  tinted  greyscale; iOS maps luminance onto the user's chosen tint

Without the last two, iOS 26 derives its dark and tinted icons from the light one,
which is why the tinted variant used to come out as a muddy full-bleed square: the
whole background is saturated orange, so there is nothing for the tint to modulate.

NOTE: these are still flat images. A true Liquid Glass icon is authored as a layered
`.icon` bundle in Icon Composer (a GUI tool that ships with Xcode) and cannot be
generated from this script; that remains open. Appearance variants and layering are
independent — this closes the first without pretending to close the second.
"""
import struct, zlib, os, math

OUTDIR = "Stride/Resources/Assets.xcassets/AppIcon.appiconset"

# ── PNG encoder ───────────────────────────────────────────────────────────────

def write_png(path, rgb, w, h):
    def chunk(tag, body):
        crc = zlib.crc32(tag + body) & 0xFFFFFFFF
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", crc)
    raw = bytearray()
    stride = w * 3
    for y in range(h):
        raw.append(0)
        raw += rgb[y * stride:(y + 1) * stride]
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
                + chunk(b"IEND", b""))


# ── Motif polygon ─────────────────────────────────────────────────────────────
# Path on 180×180 viewport: M36 148 Q66 44 122 28 L140 28 Q86 46 60 150 Z

def _qbez_points(p0, p1, p2, n):
    """Sample n evenly-spaced points on a quadratic Bézier (endpoint excluded)."""
    pts = []
    for i in range(n):
        t = i / n
        u = 1.0 - t
        pts.append((u*u*p0[0] + 2*u*t*p1[0] + t*t*p2[0],
                    u*u*p0[1] + 2*u*t*p1[1] + t*t*p2[1]))
    return pts


def build_motif(size, n_seg=400):
    """Return polygon points scaled to *size* pixels from 180-unit viewport."""
    f = size / 180.0
    def s(x, y): return (x * f, y * f)

    poly  = _qbez_points(s(36,148), s(66,44),  s(122,28), n_seg)
    poly += [s(122,28), s(140,28)]
    poly += _qbez_points(s(140,28), s(86,46),  s(60,150), n_seg)
    poly += [s(60,150)]
    return poly


# ── Scanline polygon fill ─────────────────────────────────────────────────────

def scanfill(poly, w, h):
    """Rasterise *poly* to flat bytearray(w*h): 255=inside, 0=outside."""
    n = len(poly)
    # Build directed edges with y0 < y1, pre-compute slope
    edges = []
    for i in range(n):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % n]
        if abs(y1 - y0) < 1e-9:
            continue
        if y0 > y1:
            x0, y0, x1, y1 = x1, y1, x0, y0
        edges.append((x0, y0, x1, y1, (x1 - x0) / (y1 - y0)))

    buf = bytearray(w * h)
    for y in range(h):
        sy = y + 0.5          # sample at pixel centre
        xs = []
        for x0, y0, x1, y1, slope in edges:
            if y0 <= sy < y1:
                xs.append(x0 + slope * (sy - y0))
        xs.sort()
        row = y * w
        for k in range(0, len(xs) - 1, 2):
            xa, xb = xs[k], xs[k + 1]
            x_lo = max(0, int(xa))
            x_hi = min(w - 1, int(xb) + 1)
            for x in range(x_lo, x_hi + 1):
                buf[row + x] = 255
    return buf


# ── Background compositing ────────────────────────────────────────────────────

# Gradient stops (diagonal, top-left → bottom-right)
_G0 = (0xFF, 0xA0, 0x56)   # #FFA056  stop 0.00
_G1 = (0xFF, 0x6B, 0x22)   # #FF6B22  stop 0.55
_G2 = (0xD2, 0x3A, 0x12)   # #D23A12  stop 1.00

# Glow colour
_GLOW = (0xFF, 0xDC, 0xB4)  # rgba(255,220,180)


def _grad_bg(t):
    if t <= 0.55:
        s = t / 0.55
        return (int(_G0[0] + (_G1[0]-_G0[0])*s),
                int(_G0[1] + (_G1[1]-_G0[1])*s),
                int(_G0[2] + (_G1[2]-_G0[2])*s))
    else:
        s = (t - 0.55) / 0.45
        return (int(_G1[0] + (_G2[0]-_G1[0])*s),
                int(_G1[1] + (_G2[1]-_G1[1])*s),
                int(_G1[2] + (_G2[2]-_G1[2])*s))


def _blend(base, over, a):
    """Alpha-composite *over* onto *base* at opacity *a* ∈ [0,1]."""
    return (int(base[0] + (over[0]-base[0])*a),
            int(base[1] + (over[1]-base[1])*a),
            int(base[2] + (over[2]-base[2])*a))


# ── Full icon render ──────────────────────────────────────────────────────────

def _darken(rgb, factor):
    return (int(rgb[0] * factor), int(rgb[1] * factor), int(rgb[2] * factor))


def _luminance(rgb):
    """Rec. 709 luma. The tinted appearance is greyscale by contract: iOS reads the
    luminance and substitutes the user's tint, so any colour left here is discarded."""
    y = int(0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2])
    return (y, y, y)


def generate(size, appearance="light"):
    """Render one 8-bit RGB icon.

    `appearance` is "light", "dark", or "tinted". The geometry is identical across
    all three — only the palette moves — so the mark stays recognisably the same
    icon however the home screen is configured.
    """
    if appearance not in ("light", "dark", "tinted"):
        raise ValueError(f"unknown appearance: {appearance}")

    # The dark backdrop is the same hue ramp at roughly a third of its luminance:
    # dark-mode icons keep their identity, they do not become a different colour.
    # Glow and shine come down with it, since both exist to lift a bright surface
    # and at full strength they simply grey the dark one out.
    dark = appearance == "dark"
    bg_factor = 0.20 if dark else 1.0
    glow_scale = 0.30 if dark else 1.0
    shine_scale = 0.20 if dark else 1.0
    # Pure white on a dark backdrop glares at small sizes; back it off slightly.
    motif_rgb = (236, 236, 236) if dark else (255, 255, 255)

    motif_mask = scanfill(build_motif(size), size, size)

    # Glow: radialGradient cx=0.25 cy=0.10 r=0.9, stops at 0 and 0.7
    gx = 0.25 * size
    gy = 0.10 * size
    g_r = 0.90 * size         # SVG r=0.9 (fraction of viewport)
    g_stop = 0.7 * g_r        # alpha reaches 0 at offset 0.7

    pixels = bytearray(size * size * 3)
    inv = 1.0 / max(size - 1, 1)

    for y in range(size):
        row = y * size * 3

        # Shine alpha: linear 0.32→0 over top half, 0 below
        shine_a = max(0.0, (0.5 - y * inv) * 2.0) * 0.32 * shine_scale

        # Glow: only worth computing for rows within glow circle
        gd_y2 = (y - gy) ** 2
        glow_row = gd_y2 < (g_stop + 10) ** 2   # cheap row-level guard

        for x in range(size):
            # 1. Diagonal gradient background
            t = (x + y) * inv * 0.5
            rgb = _grad_bg(t)
            if bg_factor != 1.0:
                rgb = _darken(rgb, bg_factor)

            # 2. Radial warm glow (top-left)
            if glow_row:
                gd2 = (x - gx)**2 + gd_y2
                if gd2 < g_stop * g_stop:
                    ga = (1.0 - math.sqrt(gd2) / g_stop) * 0.5 * glow_scale
                    rgb = _blend(rgb, _GLOW, ga)

            # 3. Top-half shine
            if shine_a > 0.0:
                rgb = _blend(rgb, (255, 255, 255), shine_a)

            # 4. Motif
            if motif_mask[y * size + x]:
                rgb = motif_rgb

            # 5. Flatten to luminance for the tinted appearance, last so the mark
            #    keeps the contrast the colour composition gave it.
            if appearance == "tinted":
                rgb = _luminance(rgb)

            idx = row + x * 3
            pixels[idx]     = rgb[0]
            pixels[idx + 1] = rgb[1]
            pixels[idx + 2] = rgb[2]

    return pixels


# ── Entry point ───────────────────────────────────────────────────────────────

MASTER_SIZE = 1024

# (filename, appearance, Contents.json "appearances" entry)
VARIANTS = [
    ("Icon-1024x1024.png",        "light",  None),
    ("Icon-Dark-1024x1024.png",   "dark",   {"appearance": "luminosity", "value": "dark"}),
    ("Icon-Tinted-1024x1024.png", "tinted", {"appearance": "luminosity", "value": "tinted"}),
]

# Written alongside the PNGs so the manifest can never drift from what was rendered.
# Every entry is `universal` / `platform: ios` at 1024 — the single-size form. Xcode
# derives the home-screen, Spotlight, Settings and notification sizes itself.
def build_contents():
    images = []
    for fname, _, appearances in VARIANTS:
        entry = {"filename": fname, "idiom": "universal", "platform": "ios", "size": "1024x1024"}
        if appearances is not None:
            entry["appearances"] = [appearances]
        images.append(entry)
    return {"images": images, "info": {"author": "xcode", "version": 1}}


def prune_legacy_pngs():
    """Remove the per-size PNGs the old thirteen-slot manifest referenced.

    Left in place they are unreferenced files inside the .appiconset, which Xcode
    reports as unassigned children on every build.
    """
    keep = {fname for fname, _, _ in VARIANTS} | {"Contents.json"}
    for name in sorted(os.listdir(OUTDIR)):
        if name not in keep and name.endswith(".png"):
            os.remove(os.path.join(OUTDIR, name))
            print(f"  removed stale {name}")


if __name__ == "__main__":
    import json

    os.makedirs(OUTDIR, exist_ok=True)
    for fname, appearance, _ in VARIANTS:
        path = os.path.join(OUTDIR, fname)
        print(f"  {fname} ({appearance})…", end=" ", flush=True)
        write_png(path, generate(MASTER_SIZE, appearance), MASTER_SIZE, MASTER_SIZE)
        print("ok")

    prune_legacy_pngs()

    with open(os.path.join(OUTDIR, "Contents.json"), "w") as f:
        json.dump(build_contents(), f, indent=2)
        f.write("\n")
    print("  Contents.json")
    print("All icons generated.")
