#!/usr/bin/env python3
"""Generates the app icon set and the disk image background.

Run from the project root:  python3 tools/make_assets.py
Only needed when the artwork changes; the results are committed.
"""

import math
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "Resources", "AppIcon.iconset")
DMG_BG = os.path.join(ROOT, "Resources", "dmg-background.png")

SLATE_TOP = (46, 52, 64)
SLATE_BOTTOM = (26, 30, 38)
GLOW = (255, 82, 62)
GLYPH = (255, 245, 240)


def rounded_mask(size, radius, supersample=4):
    big = size * supersample
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, big - 1, big - 1], radius=radius * supersample, fill=255
    )
    return mask.resize((size, size), Image.LANCZOS)


def vertical_gradient(size, top, bottom):
    grad = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(1, size - 1)
        grad.putpixel(
            (0, y),
            tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)),
        )
    return grad.resize((size, size), Image.BICUBIC)


def power_glyph(size, colour, width_ratio=0.085):
    """The IEC power symbol: a broken ring with a bar rising out of the gap."""
    ss = 4
    big = size * ss
    layer = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    stroke = max(2, int(big * width_ratio))
    radius = big * 0.255
    cx = cy = big / 2
    box = [cx - radius, cy - radius, cx + radius, cy + radius]

    # Ring, open at the top: 60 degrees of gap centred on 12 o'clock.
    draw.arc(box, start=-60, end=240, fill=colour, width=stroke)

    # The bar, with rounded ends to match the arc caps.
    bar_top = cy - radius * 1.36
    bar_bottom = cy - radius * 0.10
    draw.line([(cx, bar_top), (cx, bar_bottom)], fill=colour, width=stroke)
    r = stroke / 2
    draw.ellipse([cx - r, bar_top - r, cx + r, bar_top + r], fill=colour)
    draw.ellipse([cx - r, bar_bottom - r, cx + r, bar_bottom + r], fill=colour)

    return layer.resize((size, size), Image.LANCZOS)


def build_icon(size=1024):
    # macOS icons sit inside the canvas with a margin rather than filling it.
    margin = int(size * 0.09)
    body = size - 2 * margin

    base = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    plate = vertical_gradient(body, SLATE_TOP, SLATE_BOTTOM).convert("RGBA")
    plate.putalpha(rounded_mask(body, int(body * 0.225)))

    # A soft drop shadow, the way macOS renders app icons.
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 110), (margin, margin + int(size * 0.012)), plate.split()[3])
    shadow = shadow.filter(ImageFilter.GaussianBlur(size * 0.018))
    base.alpha_composite(shadow)
    base.alpha_composite(plate, (margin, margin))

    # Glow behind the glyph, then the glyph itself.
    glow = power_glyph(size, GLOW + (170,), width_ratio=0.10)
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.022))
    base.alpha_composite(glow)
    base.alpha_composite(power_glyph(size, GLYPH + (255,)))

    return base


def write_iconset(master):
    os.makedirs(ICONSET, exist_ok=True)
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            master.resize((px, px), Image.LANCZOS).save(os.path.join(ICONSET, name))
    print(f"iconset -> {ICONSET}")


def load_font(size, bold=False):
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans%s.ttf" % ("-Bold" if bold else ""),
        "/usr/share/fonts/truetype/liberation/LiberationSans%s.ttf"
        % ("-Bold" if bold else "-Regular"),
    ]
    for path in candidates:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def build_dmg_background(width=620, height=420):
    """Drawn at 2x and downscaled, so it stays crisp on Retina displays."""
    s = 2
    img = Image.new("RGB", (width * s, height * s), (246, 246, 248))
    draw = ImageDraw.Draw(img)

    # A very soft wash so the window does not read as flat white.
    wash = Image.new("RGB", (width * s, height * s), (232, 234, 240))
    mask = Image.new("L", (width * s, height * s), 0)
    ImageDraw.Draw(mask).ellipse(
        [-width * s * 0.3, height * s * 0.25, width * s * 1.3, height * s * 1.9],
        fill=120,
    )
    img.paste(wash, (0, 0), mask.filter(ImageFilter.GaussianBlur(60)))

    title = load_font(21 * s, bold=True)
    caption = load_font(13 * s)

    draw.text(
        (width * s / 2, 44 * s),
        "AutoShutdown",
        font=title,
        fill=(28, 28, 32),
        anchor="mm",
    )
    draw.text(
        (width * s / 2, 74 * s),
        "Drag the app onto Applications, then open it once.",
        font=caption,
        fill=(110, 110, 120),
        anchor="mm",
    )

    # The arrow, spanning the gap between the two icon positions below.
    y = 195 * s
    x0, x1 = 258 * s, 362 * s
    draw.line([(x0, y), (x1 - 13 * s, y)], fill=(168, 170, 180), width=3 * s)
    draw.polygon(
        [(x1, y), (x1 - 15 * s, y - 8 * s), (x1 - 15 * s, y + 8 * s)],
        fill=(168, 170, 180),
    )

    draw.text(
        (width * s / 2, 372 * s),
        "It lives in the menu bar and starts at login.",
        font=caption,
        fill=(140, 140, 150),
        anchor="mm",
    )

    os.makedirs(os.path.dirname(DMG_BG), exist_ok=True)
    img.resize((width, height), Image.LANCZOS).save(DMG_BG)

    # The @2x companion that Finder picks up on Retina displays.
    img.save(DMG_BG.replace(".png", "@2x.png"))
    print(f"background -> {DMG_BG}")


if __name__ == "__main__":
    master = build_icon()
    write_iconset(master)
    master.resize((512, 512), Image.LANCZOS).save(
        os.path.join(ROOT, "Resources", "icon-preview.png")
    )
    build_dmg_background()
