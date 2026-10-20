"""Builds web images for the SOLIS site from the real app renders and brand files.

Run from anywhere:  python marketing/site/tools/images.py
Writes to marketing/site/src/assets/img/.
"""
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[3]          # solis_mobile
OUT = ROOT / "marketing" / "site" / "src" / "assets" / "img"
SHOTS = ROOT / "screenshots" / "out"
BRAND = ROOT / "assets" / "brand"
OUT.mkdir(parents=True, exist_ok=True)

for png in sorted(SHOTS.glob("*.png")):
    im = Image.open(png).convert("RGB")
    for w in (360, 720):
        h = round(im.height * w / im.width)
        im.resize((w, h), Image.LANCZOS).save(OUT / f"{png.stem}-{w}.webp", "WEBP", quality=84, method=6)

card = Image.open(ROOT / "assets" / "demo_cards" / "insurance_front.jpg").convert("RGB")
for w in (520, 1012):
    h = round(card.height * w / card.width)
    card.resize((w, h), Image.LANCZOS).save(OUT / f"sample-card-{w}.webp", "WEBP", quality=84, method=6)

mark = Image.open(BRAND / "solis_mark_1024.png").convert("RGBA")
for s in (32, 180, 192, 512):
    mark.resize((s, s), Image.LANCZOS).save(OUT / f"icon-{s}.png", optimize=True)
mark.resize((48, 48), Image.LANCZOS).save(OUT.parent.parent / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48)])
print("ok", len(list(OUT.iterdir())))
