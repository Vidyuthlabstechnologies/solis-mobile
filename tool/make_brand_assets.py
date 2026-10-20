"""Generate every SOLIS brand asset from one set of geometry.

    python tool/make_brand_assets.py

Writes:
  assets/brand/            SVG masters and PNG exports (mark, glyph, wordmark)
  android/app/src/main/res launcher icons (adaptive + legacy), splash mark,
                           colors, vector foreground and monochrome layers

Needs only Python 3 and Pillow. No fonts are used: the wordmark letters are
drawn from the same circles and bars as the mark, so the whole identity is
original geometry with no third-party license attached.

The mark ("Split Sun"): one sun disc cut along the horizon. The upper half
stays where it rose; the lower half slides left by the same distance. Read
as a picture it is a sunrise and its reflection; read as a letter it is an S.
The meaning for the product: what was said (above the line) and what was
written down (below the line) are the same disc, shifted, nothing added.

If you change a number here, also change lib/widgets/solis_brand.dart
(_SplitSunPainter), which draws the same geometry at runtime.
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
BRAND_DIR = ROOT / "assets" / "brand"
RES = ROOT / "android" / "app" / "src" / "main" / "res"

# ---------------------------------------------------------------- colors
# SOLIS Orchid ramp (OKLCH hue 335; tones 70-90 at hue 325). Tone 40 is the brand color.
ORCHID = {
    10: "#2F0029",
    20: "#4E0044",
    30: "#6F0061",
    40: "#980F86",
    50: "#B435A0",
    60: "#CA58B5",
    70: "#D180D6",
    80: "#E5A3E8",
    90: "#F1CAF3",
    95: "#FDE2F6",
    99: "#FFF8FD",
}
BRAND = ORCHID[40]
BRAND_NIGHT = ORCHID[20]  # splash background when the OS is in dark mode
INK = "#0F172A"           # wordmark text on light backgrounds
WHITE = "#FFFFFF"

# ---------------------------------------------------------------- geometry
# All mark coordinates are fractions of the tile side (tile = 1 x 1).
TILE_RADIUS = 0.23   # corner radius of the app tile
SUN_R = 0.23         # radius of the sun disc
SHIFT = 0.08         # each half moves this far from center (total slide 0.16)
GAP = 0.025          # each half moves this far from the horizon (gap 0.05)
CX, CY = 0.5, 0.5

DOME = (CX + SHIFT, CY - GAP, SUN_R, "top")      # upper half, risen, right
BOWL = (CX - SHIFT, CY + GAP, SUN_R, "bottom")   # lower half, written, left
MARK = [("half",) + DOME, ("half",) + BOWL]

# Start angle of each half, degrees clockwise from +x in screen space.
_START = {"top": 180, "bottom": 0, "left": 90, "right": 270}


def _pt(cx, cy, r, deg):
    a = math.radians(deg)
    return cx + r * math.cos(a), cy + r * math.sin(a)


# ---------------------------------------------------------------- wordmark
# Cap height 1. Stroke W. Letters: S O L I S, geometric, no font.
W = 0.18
RC = (0.5 - W / 2) / 2           # centerline radius of each S bowl
S_A = RC + W / 2                 # x of the top bowl center
S_B = S_A + 2 * SHIFT / (2 * SUN_R) * (2 * RC)  # same slide ratio as the mark
S_WIDTH = S_B + RC + W / 2
O_WIDTH = 1.0
L_WIDTH = 0.6
TRACK = 0.16                     # space between letters


def glyph_s(x0):
    top_cy = W / 2 + RC
    bot_cy = 0.5 + RC
    return [
        ("halfring", x0 + S_A, top_cy, RC + W / 2, RC - W / 2, "left"),
        ("halfring", x0 + S_B, bot_cy, RC + W / 2, RC - W / 2, "right"),
        ("rect", x0 + S_A, 0, x0 + S_WIDTH, W),
        ("rect", x0 + S_A, 0.5 - W / 2, x0 + S_B, 0.5 + W / 2),
        ("rect", x0, 1 - W, x0 + S_B, 1),
    ]


def glyph_o(x0):
    return [("ring", x0 + 0.5, 0.5, 0.5, 0.5 - W)]


def glyph_l(x0):
    return [("rect", x0, 0, x0 + W, 1), ("rect", x0, 1 - W, x0 + L_WIDTH, 1)]


def glyph_i(x0):
    return [("rect", x0, 0, x0 + W, 1)]


def wordmark_letters():
    shapes, x = [], 0.0
    for fn, width in ((glyph_s, S_WIDTH), (glyph_o, O_WIDTH), (glyph_l, L_WIDTH), (glyph_i, W), (glyph_s, S_WIDTH)):
        shapes += fn(x)
        x += width + TRACK
    return shapes, x - TRACK


# ---------------------------------------------------------------- rendering
def _transform(shape, scale, ox, oy):
    kind, *v = shape
    if kind == "rect":
        x0, y0, x1, y1 = v
        return (kind, ox + x0 * scale, oy + y0 * scale, ox + x1 * scale, oy + y1 * scale)
    if kind == "half":
        cx, cy, r, side = v
        return (kind, ox + cx * scale, oy + cy * scale, r * scale, side)
    if kind in ("halfring", "ring"):
        cx, cy, ro, ri, *side = v
        return (kind, ox + cx * scale, oy + cy * scale, ro * scale, ri * scale, *side)
    raise ValueError(kind)


def raster_mask(shapes, size_px, ss=8):
    """Union of shapes (already in pixel units at 1x) as an antialiased L mask."""
    w, h = size_px
    big = Image.new("L", (w * ss, h * ss), 0)
    for shape in shapes:
        layer = Image.new("L", big.size, 0)
        d = ImageDraw.Draw(layer)
        kind, *v = shape
        s = lambda t: t * ss  # noqa: E731
        if kind == "rect":
            x0, y0, x1, y1 = map(s, v)
            d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=255)
        elif kind == "half":
            cx, cy, r, side = v
            a0 = _START[side]
            d.pieslice([s(cx - r), s(cy - r), s(cx + r), s(cy + r)], a0, a0 + 180, fill=255)
        elif kind == "halfring":
            cx, cy, ro, ri, side = v
            a0 = _START[side]
            d.pieslice([s(cx - ro), s(cy - ro), s(cx + ro), s(cy + ro)], a0, a0 + 180, fill=255)
            d.ellipse([s(cx - ri), s(cy - ri), s(cx + ri), s(cy + ri)], fill=0)
        elif kind == "ring":
            cx, cy, ro, ri = v
            d.ellipse([s(cx - ro), s(cy - ro), s(cx + ro), s(cy + ro)], fill=255)
            d.ellipse([s(cx - ri), s(cy - ri), s(cx + ri), s(cy + ri)], fill=0)
        big = ImageChops.lighter(big, layer)
    return big.resize((w, h), Image.LANCZOS)


def tile_image(px, radius=TILE_RADIUS, inset=0.0, color=BRAND, mark_color=WHITE, ss=8):
    """Brand tile with the mark. inset shrinks the tile inside the canvas (legacy icons)."""
    img = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    side = px * (1 - 2 * inset)
    off = px * inset
    big = Image.new("L", (px * ss, px * ss), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        [off * ss, off * ss, (off + side) * ss - 1, (off + side) * ss - 1], radius=side * radius * ss, fill=255
    )
    tile_mask = big.resize((px, px), Image.LANCZOS)
    img.paste(Image.new("RGBA", (px, px), color), (0, 0), tile_mask)
    mark = raster_mask([_transform(sh, side, off, off) for sh in MARK], (px, px), ss)
    img.paste(Image.new("RGBA", (px, px), mark_color), (0, 0), mark)
    return img


def glyph_image(px, color=WHITE, box=1.0):
    """The mark alone on transparency. box = fraction of the canvas the 1x1 tile frame takes."""
    side = px * box
    off = (px - side) / 2
    mask = raster_mask([_transform(sh, side, off, off) for sh in MARK], (px, px))
    img = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    img.paste(Image.new("RGBA", (px, px), color), (0, 0), mask)
    return img


# ---------------------------------------------------------------- SVG
def _f(v):
    return f"{v:.3f}".rstrip("0").rstrip(".")


def svg_path(shape):
    kind, *v = shape
    if kind == "rect":
        x0, y0, x1, y1 = v
        return f"M{_f(x0)} {_f(y0)}H{_f(x1)}V{_f(y1)}H{_f(x0)}Z"
    if kind == "half":
        cx, cy, r, side = v
        a0 = _START[side]
        x0, y0 = _pt(cx, cy, r, a0)
        x1, y1 = _pt(cx, cy, r, a0 + 180)
        return f"M{_f(x0)} {_f(y0)}A{_f(r)} {_f(r)} 0 0 1 {_f(x1)} {_f(y1)}Z"
    if kind == "halfring":
        cx, cy, ro, ri, side = v
        a0 = _START[side]
        ox0, oy0 = _pt(cx, cy, ro, a0)
        ox1, oy1 = _pt(cx, cy, ro, a0 + 180)
        ix1, iy1 = _pt(cx, cy, ri, a0 + 180)
        ix0, iy0 = _pt(cx, cy, ri, a0)
        return (
            f"M{_f(ox0)} {_f(oy0)}A{_f(ro)} {_f(ro)} 0 0 1 {_f(ox1)} {_f(oy1)}"
            f"L{_f(ix1)} {_f(iy1)}A{_f(ri)} {_f(ri)} 0 0 0 {_f(ix0)} {_f(iy0)}Z"
        )
    if kind == "ring":
        cx, cy, ro, ri = v
        return (
            f"M{_f(cx - ro)} {_f(cy)}A{_f(ro)} {_f(ro)} 0 1 1 {_f(cx + ro)} {_f(cy)}"
            f"A{_f(ro)} {_f(ro)} 0 1 1 {_f(cx - ro)} {_f(cy)}Z"
            f"M{_f(cx - ri)} {_f(cy)}A{_f(ri)} {_f(ri)} 0 1 0 {_f(cx + ri)} {_f(cy)}"
            f"A{_f(ri)} {_f(ri)} 0 1 0 {_f(cx - ri)} {_f(cy)}Z"
        )
    raise ValueError(kind)


def mark_svg():
    s = 1024
    paths = "".join(svg_path(_transform(sh, s, 0, 0)) for sh in MARK)
    r = _f(s * TILE_RADIUS)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {s} {s}" width="{s}" height="{s}">\n'
        f"  <title>SOLIS</title>\n"
        f'  <rect width="{s}" height="{s}" rx="{r}" fill="{BRAND}"/>\n'
        f'  <path fill="{WHITE}" d="{paths}"/>\n'
        f"</svg>\n"
    )


def glyph_svg():
    s = 1024
    paths = "".join(svg_path(_transform(sh, s, 0, 0)) for sh in MARK)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {s} {s}" width="{s}" height="{s}">\n'
        f"  <title>SOLIS mark, one color</title>\n"
        f'  <path fill="currentColor" d="{paths}"/>\n'
        f"</svg>\n"
    )


def wordmark_layout(tile_px):
    """Shapes for tile + letters, in pixels. Returns (tile_rect, mark_shapes, letter_shapes, width, height)."""
    letters, text_w = wordmark_letters()
    cap = tile_px * 0.40
    gap = tile_px * 0.30
    pad = tile_px * 0.0
    tx = pad + tile_px + gap
    ty = (tile_px - cap) / 2
    letter_px = [_transform(sh, cap, tx, ty) for sh in letters]
    mark_px = [_transform(sh, tile_px, pad, 0) for sh in MARK]
    width = tx + text_w * cap
    return (pad, 0, tile_px), mark_px, letter_px, width, tile_px


def wordmark_svg(dark=False):
    tile_px = 240
    (tx, ty, ts), mark_px, letter_px, w, h = wordmark_layout(tile_px)
    ink = WHITE if dark else INK
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {_f(w)} {_f(h)}" width="{_f(w)}" height="{_f(h)}">\n'
        f"  <title>SOLIS</title>\n"
        f'  <rect x="{_f(tx)}" y="{_f(ty)}" width="{_f(ts)}" height="{_f(ts)}" rx="{_f(ts * TILE_RADIUS)}" fill="{BRAND}"/>\n'
        f'  <path fill="{WHITE}" d="{"".join(svg_path(s) for s in mark_px)}"/>\n'
        f'  <path fill="{ink}" fill-rule="evenodd" d="{"".join(svg_path(s) for s in letter_px)}"/>\n'
        f"</svg>\n"
    )


def wordmark_png(tile_px, dark=False, bg=None):
    (tx, ty, ts), mark_px, letter_px, w, h = wordmark_layout(tile_px)
    pad = int(tile_px * 0.25) if bg else 0
    W_, H_ = math.ceil(w) + 2 * pad, math.ceil(h) + 2 * pad
    img = Image.new("RGBA", (W_, H_), bg or (0, 0, 0, 0))
    tile = tile_image(ts)
    img.alpha_composite(tile, (pad, pad))
    shifted = [_transform(s, 1, pad, pad) for s in letter_px]
    mask = raster_mask(shifted, (W_, H_))
    img.paste(Image.new("RGBA", (W_, H_), WHITE if dark else INK), (0, 0), mask)
    return img


# ---------------------------------------------------------------- Android
def vector_drawable(color, comment):
    """108dp adaptive-icon layer. The 1x1 tile frame maps to the 72dp visible area."""
    paths = "".join(svg_path(_transform(sh, 72, 18, 18)) for sh in MARK)
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f"<!-- {comment} Generated by tool/make_brand_assets.py. -->\n"
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:width="108dp"\n'
        '    android:height="108dp"\n'
        '    android:viewportWidth="108"\n'
        '    android:viewportHeight="108">\n'
        "    <path\n"
        f'        android:fillColor="{color}"\n'
        f'        android:pathData="{paths}" />\n'
        "</vector>\n"
    )


def write(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def save(img: Image.Image, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, optimize=True)


DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def android():
    # Adaptive icon layers (API 26+), monochrome for Android 13 themed icons.
    write(RES / "drawable" / "ic_launcher_foreground.xml", vector_drawable(WHITE, "SOLIS split-sun mark, adaptive foreground."))
    write(RES / "drawable" / "ic_launcher_monochrome.xml", vector_drawable(WHITE, "SOLIS split-sun mark, themed-icon layer."))
    write(
        RES / "values" / "colors.xml",
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!-- SOLIS Orchid. Generated by tool/make_brand_assets.py. -->\n"
        "<resources>\n"
        f'    <color name="solis_brand">{BRAND}</color>\n'
        f'    <color name="ic_launcher_background">{BRAND}</color>\n'
        f'    <color name="solis_splash_background">{BRAND}</color>\n'
        "</resources>\n",
    )
    write(
        RES / "values-night" / "colors.xml",
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!-- Night splash uses the deep tone so launch is not a bright flash in a dark room. -->\n"
        "<resources>\n"
        f'    <color name="solis_splash_background">{BRAND_NIGHT}</color>\n'
        "</resources>\n",
    )
    adaptive = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@drawable/ic_launcher_foreground" />\n'
        '    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />\n'
        "</adaptive-icon>\n"
    )
    write(RES / "mipmap-anydpi-v26" / "ic_launcher.xml", adaptive)

    # Legacy launcher PNGs (pre-API 26): rounded tile with a small inset.
    for name, k in DENSITIES.items():
        px = round(48 * k)
        save(tile_image(px, inset=1 / 48), RES / f"mipmap-{name}" / "ic_launcher.png")
        # Splash mark for the pre-Android-12 launch screen: 160dp box, tile frame 160dp.
        save(glyph_image(round(160 * k)), RES / f"drawable-{name}" / "launch_mark.png")

    launch = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!-- SOLIS launch screen: brand color with the centered mark. Generated by tool/make_brand_assets.py. -->\n"
        '<layer-list xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <item android:drawable="@color/solis_splash_background" />\n'
        "    <item>\n"
        "        <bitmap\n"
        '            android:gravity="center"\n'
        '            android:src="@drawable/launch_mark" />\n'
        "    </item>\n"
        "</layer-list>\n"
    )
    write(RES / "drawable" / "launch_background.xml", launch)
    write(RES / "drawable-v21" / "launch_background.xml", launch)

    for folder, parent in (("values-v31", "Light"), ("values-night-v31", "Black")):
        write(
            RES / folder / "styles.xml",
            '<?xml version="1.0" encoding="utf-8"?>\n'
            "<!-- Android 12+ system splash. Generated by tool/make_brand_assets.py. -->\n"
            "<resources>\n"
            f'    <style name="LaunchTheme" parent="@android:style/Theme.{parent}.NoTitleBar">\n'
            '        <item name="android:windowBackground">@drawable/launch_background</item>\n'
            '        <item name="android:windowSplashScreenBackground">@color/solis_splash_background</item>\n'
            '        <item name="android:windowSplashScreenAnimatedIcon">@drawable/ic_launcher_foreground</item>\n'
            "    </style>\n"
            f'    <style name="NormalTheme" parent="@android:style/Theme.{parent}.NoTitleBar">\n'
            '        <item name="android:windowBackground">?android:colorBackground</item>\n'
            "    </style>\n"
            "</resources>\n",
        )


def brand_assets():
    write(BRAND_DIR / "solis_mark.svg", mark_svg())
    write(BRAND_DIR / "solis_glyph.svg", glyph_svg())
    write(BRAND_DIR / "solis_wordmark.svg", wordmark_svg())
    write(BRAND_DIR / "solis_wordmark_dark.svg", wordmark_svg(dark=True))
    for px in (48, 96, 192, 512, 1024):
        save(tile_image(px), BRAND_DIR / f"solis_mark_{px}.png")
    # Store listing icon: full-bleed square, the store applies its own mask.
    save(tile_image(512, radius=0), BRAND_DIR / "solis_playstore_512.png")
    save(glyph_image(1024, color=BRAND), BRAND_DIR / "solis_glyph_orchid_1024.png")
    save(glyph_image(1024, color=INK), BRAND_DIR / "solis_glyph_ink_1024.png")
    save(wordmark_png(240), BRAND_DIR / "solis_wordmark.png")
    save(wordmark_png(240, dark=True), BRAND_DIR / "solis_wordmark_dark.png")
    save(wordmark_png(240, bg=WHITE), BRAND_DIR / "solis_wordmark_on_white.png")
    save(wordmark_png(240, dark=True, bg="#0B0E14"), BRAND_DIR / "solis_wordmark_on_dark.png")


if __name__ == "__main__":
    brand_assets()
    android()
    print("SOLIS brand assets written to", BRAND_DIR, "and", RES)
