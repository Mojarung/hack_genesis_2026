"""Кадрирует котов, которые прислала команда, под слайды и кладёт в assets/.

Источники — assets/cats/new_*.jpg. У двух картинок внизу подпись мема: на слайде она
нечитаема и режется краем, поэтому вырезаем область руками (box), а не по центру.
"""

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
CATS = ROOT / "assets" / "cats"

# файл-источник -> (имя в assets, соотношение сторон, центр по вертикали 0..1, ручная область или None)
PICKS = {
    # спит в коробке — «провайдер молчит»; отрезаем подпись «full of:» и кружок справа снизу
    "new_2.jpg": ("cat_sleep.jpg", None, 0.5, (245, 30, 715, 340)),
    # круглые глаза — «шесть тысяч в секунду»; отрезаем красную плашку внизу
    "new_1.jpg": ("cat_wow.jpg", 1 / 1, 0.5, (8, 4, 327, 298)),
    "new_4.jpg": ("cat_space.jpg", 1 / 1, 0.5, None),   # с антеннами — «мы не как все»
    "new_3.jpg": ("cat_face.jpg", 1 / 1, 0.5, None),    # морда вплотную — наклейка на титуле
}


def crop_to(im: Image.Image, ratio: float, focus: float) -> Image.Image:
    width, height = im.size
    if width / height > ratio:  # шире нужного — режем по бокам
        new_width = round(height * ratio)
        left = (width - new_width) // 2
        return im.crop((left, 0, left + new_width, height))
    new_height = round(width / ratio)  # выше нужного — режем вокруг focus
    top = max(0, min(height - new_height, round(height * focus - new_height / 2)))
    return im.crop((0, top, width, top + new_height))


for source, (name, ratio, focus, box) in PICKS.items():
    im = Image.open(CATS / source).convert("RGB")
    out = im.crop(box) if box else im
    if ratio:
        out = crop_to(out, ratio, focus)
    out.thumbnail((900, 900))
    out.save(ROOT / "assets" / name, quality=86, optimize=True)
    print(name, im.size, "->", out.size, (ROOT / "assets" / name).stat().st_size // 1024, "KB")
