"""Кроп настоящих скриншотов отчёта под слайды + уменьшенные копии для канваса.

Координаты — по presentation/captures/report_full.png (2560×7200, масштаб 2×).
"""

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "captures" / "report_full.png"
OUT = ROOT / "captures"
SMALL = ROOT / "canvas" / "img"
OUT.mkdir(exist_ok=True)
SMALL.mkdir(parents=True, exist_ok=True)

CROPS = {
    "report_distribution": (190, 680, 2370, 1320),
    "report_recommendations": (190, 4550, 2370, 5730),
    "report_cascade": (190, 3200, 2370, 3820),
    "report_attainability": (190, 3920, 2370, 4470),
    "report_reco_first": (198, 4655, 2358, 4832),
}

full = Image.open(SRC).convert("RGB")
for name, box in CROPS.items():
    crop = full.crop(box)
    crop.save(OUT / f"{name}.png", optimize=True)
    small = crop.copy()
    small.thumbnail((1400, 1400))
    small.save(SMALL / f"{name}.jpg", quality=78, optimize=True)
    print(name, crop.size, (OUT / f"{name}.png").stat().st_size, (SMALL / f"{name}.jpg").stat().st_size)

for name in ("team.jpg", "meme.jpg", "cat_cook.jpg", "cat_sleep.jpg", "cat_wow.jpg", "cat_space.jpg", "cat_face.jpg"):
    im = Image.open(ROOT / "assets" / name).convert("RGB")
    small = im.copy()
    small.thumbnail((820, 820))
    small.save(SMALL / name, quality=68, optimize=True)
    print(name, im.size, (SMALL / name).stat().st_size)
