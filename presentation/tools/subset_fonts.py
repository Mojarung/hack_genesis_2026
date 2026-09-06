"""Скачивает woff2 из Google Fonts CSS и режет до кириллицы + латиницы + знаков, которые есть на слайдах.

Итог — компактный CSS с data:-URI, который вшивается в каждый артборд канваса:
  fonts/fonts-min.css         Unbounded 700/800 + Golos Text 400/500/600   (дека M3)

"""

from __future__ import annotations

import base64
import re
import urllib.request
from io import BytesIO
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parents[1] / "fonts"
UNICODES = (
    "U+0020-007E,U+00A0-00FF,U+0400-045F,U+0490-0491,U+2010-2027,U+2030-203A,"
    "U+2116,U+20AC,U+20BD,U+2192,U+2190,U+2211,U+00D7,U+2026,U+2264,U+2265,U+2248"
)
SUBSETS = {"cyrillic", "latin"}

FACE = re.compile(
    r"/\*\s*(?P<subset>\S+)\s*\*/\s*@font-face\s*\{(?P<body>.*?)\}", re.S
)


def faces(css_path: Path, families: set[str], weights: set[int]):
    css = css_path.read_text(encoding="utf-8")
    for match in FACE.finditer(css):
        if match["subset"] not in SUBSETS:
            continue
        body = match["body"]
        family = re.search(r"font-family:\s*'([^']+)'", body)[1]
        weight = int(re.search(r"font-weight:\s*(\d+)", body)[1])
        if family not in families or weight not in weights:
            continue
        url = re.search(r"url\(([^)]+)\)", body)[1]
        yield family, weight, match["subset"], url


def shrink(data: bytes) -> bytes:
    font = TTFont(BytesIO(data))
    options = subset.Options()
    options.flavor = "woff2"
    options.desubroutinize = True
    options.hinting = False
    options.layout_features = ["kern", "liga", "calt", "locl", "tnum"]
    subsetter = subset.Subsetter(options)
    subsetter.populate(unicodes=subset.parse_unicodes(UNICODES))
    subsetter.subset(font)
    out = BytesIO()
    font.flavor = "woff2"
    font.save(out)
    return out.getvalue()


def build(target: Path, sources: list[tuple[Path, set[str], set[int]]]) -> None:
    rules = []
    seen = {}
    for css_path, families, weights in sources:
        for family, weight, subset_name, url in faces(css_path, families, weights):
            raw = urllib.request.urlopen(url, timeout=60).read()  # noqa: S310 — только fonts.gstatic.com
            small = shrink(raw)
            key = (family, weight, subset_name)
            seen[key] = (len(raw), len(small))
            rules.append(
                f"@font-face{{font-family:'{family}';font-style:normal;font-weight:{weight};font-display:swap;"
                f"src:url(data:font/woff2;base64,{base64.b64encode(small).decode()}) format('woff2');}}"
            )
    target.write_text("\n".join(rules) + "\n", encoding="utf-8")
    for key, (before, after) in seen.items():
        print(f"{key[0]} {key[1]} {key[2]}: {before} → {after} bytes")
    print(f"{target.name}: {len(rules)} faces, {target.stat().st_size // 1024} KB")


if __name__ == "__main__":
    golos = (ROOT / "google.css", {"Golos Text"}, {400, 500, 600})
    build(ROOT / "fonts-min.css", [(ROOT / "google.css", {"Unbounded"}, {700, 800}), golos])

