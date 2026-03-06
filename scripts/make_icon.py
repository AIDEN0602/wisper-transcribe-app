#!/usr/bin/env python3
"""Generate ClassTranscribe app icon — quokka in dark suit style."""
import math, os, subprocess, sys, shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets"
ASSETS.mkdir(exist_ok=True)

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "pillow", "-q"])
    from PIL import Image, ImageDraw, ImageFont


def lerp_color(c1, c2, t):
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))


def make_icon(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # ── background: dark navy rounded square ─────────────────────────────────
    bg = (13, 20, 40, 255)
    r = size // 5
    m = 0
    draw.rounded_rectangle([m, m, size - m, size - m], radius=r, fill=bg)

    # ── green audio waveform bars (bottom 45%) ────────────────────────────────
    green      = (34, 197, 94, 255)
    green_dim  = (22, 130, 62, 180)
    n_bars = 13
    bar_w  = max(3, size // (n_bars * 3))
    gap    = max(2, size // (n_bars * 4))
    total  = n_bars * bar_w + (n_bars - 1) * gap
    x0     = (size - total) // 2
    cy     = int(size * 0.72)
    max_h  = int(size * 0.35)
    heights = [0.30, 0.50, 0.70, 0.55, 0.90, 0.65, 1.00,
               0.65, 0.90, 0.55, 0.70, 0.50, 0.30]
    for i, h_r in enumerate(heights):
        h   = max(int(max_h * h_r), bar_w)
        x   = x0 + i * (bar_w + gap)
        col = lerp_color(green_dim, green, h_r)
        rr  = bar_w // 2
        draw.rounded_rectangle([x, cy - h // 2, x + bar_w, cy + h // 2],
                                radius=rr, fill=col)

    # ── quokka face (simple + cute) ───────────────────────────────────────────
    brown      = (180, 120,  60, 255)
    dark_brown = (120,  75,  30, 255)
    cream      = (240, 210, 170, 255)
    eye_col    = ( 30,  20,  10, 255)
    suit_dark  = ( 25,  35,  60, 255)  # navy suit
    tie_col    = (200, 160,  20, 255)  # gold tie

    fc  = size * 0.50   # face centre x
    fcy = size * 0.38   # face centre y
    fr  = size * 0.175  # face radius

    # Ears (behind face)
    ear_r = fr * 0.55
    for ex in [fc - fr * 0.82, fc + fr * 0.82]:
        draw.ellipse([ex - ear_r, fcy - fr * 0.9 - ear_r,
                      ex + ear_r, fcy - fr * 0.9 + ear_r], fill=dark_brown)
        draw.ellipse([ex - ear_r * 0.55, fcy - fr * 0.9 - ear_r * 0.55,
                      ex + ear_r * 0.55, fcy - fr * 0.9 + ear_r * 0.55], fill=brown)

    # Body / suit
    body_w = fr * 2.4
    body_h = fr * 1.8
    bx = fc - body_w / 2
    by = fcy + fr * 0.85
    draw.ellipse([bx, by, bx + body_w, by + body_h], fill=suit_dark)
    # Tie
    tw = fr * 0.28
    draw.polygon([
        (fc, by + body_h * 0.05),
        (fc - tw, by + body_h * 0.50),
        (fc, by + body_h * 0.80),
        (fc + tw, by + body_h * 0.50),
    ], fill=tie_col)
    # Shirt collar
    draw.polygon([
        (fc - fr * 0.5, by),
        (fc, by + body_h * 0.18),
        (fc - fr * 0.1, by),
    ], fill=(240, 240, 240, 255))
    draw.polygon([
        (fc + fr * 0.5, by),
        (fc, by + body_h * 0.18),
        (fc + fr * 0.1, by),
    ], fill=(240, 240, 240, 255))

    # Face circle
    draw.ellipse([fc - fr, fcy - fr, fc + fr, fcy + fr], fill=brown)
    # Muzzle
    mzr = fr * 0.52
    draw.ellipse([fc - mzr, fcy - mzr * 0.1,
                  fc + mzr, fcy + mzr * 1.1], fill=cream)

    # Eyes
    eye_r = fr * 0.145
    for ex in [fc - fr * 0.42, fc + fr * 0.42]:
        ey = fcy - fr * 0.15
        # white
        draw.ellipse([ex - eye_r * 1.3, ey - eye_r * 1.3,
                      ex + eye_r * 1.3, ey + eye_r * 1.3], fill=(255, 255, 255, 255))
        # pupil
        draw.ellipse([ex - eye_r, ey - eye_r,
                      ex + eye_r, ey + eye_r], fill=eye_col)
        # highlight
        draw.ellipse([ex + eye_r * 0.2, ey - eye_r * 0.6,
                      ex + eye_r * 0.7, ey - eye_r * 0.1],
                     fill=(255, 255, 255, 200))

    # Nose
    nw, nh = fr * 0.22, fr * 0.14
    nx, ny = fc, fcy + fr * 0.1
    draw.ellipse([nx - nw, ny - nh, nx + nw, ny + nh], fill=dark_brown)

    # Smile
    smile_r = fr * 0.38
    bb = [fc - smile_r, fcy + fr * 0.22,
          fc + smile_r, fcy + fr * 0.22 + smile_r * 1.2]
    draw.arc(bb, start=20, end=160, fill=dark_brown, width=max(2, size // 80))

    # Microphone
    mic_x = int(fc + fr * 1.45)
    mic_y = int(fcy + fr * 0.1)
    ms = int(fr * 0.55)
    # handle
    draw.rounded_rectangle([mic_x - ms // 5, mic_y,
                             mic_x + ms // 5, mic_y + ms * 2],
                            radius=ms // 10, fill=(180, 180, 200, 255))
    # head
    draw.rounded_rectangle([mic_x - ms // 2, mic_y - ms,
                             mic_x + ms // 2, mic_y + ms // 4],
                            radius=ms // 4, fill=(210, 215, 230, 255))
    # grille lines on mic
    for gi in range(3):
        gy = mic_y - ms + ms * gi // 2
        draw.line([mic_x - ms // 2 + 3, gy + ms // 6,
                   mic_x + ms // 2 - 3, gy + ms // 6],
                  fill=(150, 150, 170, 180), width=max(1, size // 200))

    # Baseball cap (simple half-circle + brim)
    cap_col  = (20, 30, 55, 255)
    brim_col = (15, 22, 45, 255)
    cap_cy   = fcy - fr * 0.75
    cap_r    = fr * 0.85
    draw.pieslice([fc - cap_r, cap_cy - cap_r, fc + cap_r, cap_cy + cap_r],
                  start=200, end=340, fill=cap_col)
    # Brim
    draw.ellipse([fc - cap_r * 1.1, cap_cy - cap_r * 0.05,
                  fc + cap_r * 0.2,  cap_cy + cap_r * 0.2], fill=brim_col)
    # Goggle / sunglasses
    gl_col = (40, 50, 90, 210)
    gl_r   = fr * 0.28
    for gx in [fc - fr * 0.45, fc + fr * 0.38]:
        gy = fcy - fr * 0.38
        draw.ellipse([gx - gl_r, gy - gl_r * 0.7,
                      gx + gl_r, gy + gl_r * 0.7], fill=gl_col)
    draw.line([fc - fr * 0.17, fcy - fr * 0.38,
               fc + fr * 0.10, fcy - fr * 0.38], fill=gl_col, width=max(2, size // 100))

    return img


# ── build iconset ─────────────────────────────────────────────────────────────
iconset = ASSETS / "ClassTranscribe.iconset"
iconset.mkdir(exist_ok=True)

sizes = [16, 32, 64, 128, 256, 512, 1024]
for s in sizes:
    img = make_icon(s)
    img.save(iconset / f"icon_{s}x{s}.png")
    if s <= 512:
        img2 = make_icon(s * 2)
        img2.save(iconset / f"icon_{s}x{s}@2x.png")

# Save a plain PNG preview too
make_icon(1024).save(ASSETS / "icon_preview.png")
print(f"Iconset saved to {iconset}")

# ── convert to .icns with iconutil (macOS only) ───────────────────────────────
icns = ASSETS / "ClassTranscribe.icns"
try:
    subprocess.check_call(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)])
    print(f"Icon saved: {icns}")
except Exception as e:
    print(f"iconutil failed ({e}), trying sips…")
    try:
        subprocess.check_call([
            "sips", "-s", "format", "icns",
            str(ASSETS / "icon_512x512.png"), "--out", str(icns)
        ])
        print(f"Icon saved (sips): {icns}")
    except Exception as e2:
        print(f"sips also failed: {e2}")
