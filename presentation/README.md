# Дека защиты — MISIS_MOJARUNG

Двенадцать слайдов, ~4 минуты вместе с демо в терминале.

- `index.html` — показ в браузере: ← → листать, **F** — на весь экран, **P** — печать.
  Шрифты вшиты, сеть не нужна. Слайды въезжают по появлению, команда в терминале набирается
  по буквам, трасса каскада на слайде 5 раскрывается построчно.
- `MISIS_MOJARUNG.pdf` — 12 страниц 16:9, шрифты вшиты.
- `MISIS_MOJARUNG.pptx` — те же слайды картинками 2560×1440, нередактируемый.
- `pitch.md` — текст выступления по слайдам и ответы на вероятные вопросы.

## Как собрано

Слайды — `src/slides/*.html`, общий стиль — `src/theme.css`: Material Design 3 (тональные
поверхности, скругления 16 / 28 / 40, Unbounded для заголовков и чисел, Golos Text для текста)
плюс приёмы из афиши — рубрика мелкими прописными над заголовком, огромное слово на фоне
в 4% непрозрачности, фото наклейками с поворотом. Подложки под котами — 12-лепестковая
«печенька» Material 3 Expressive (`src/cookie.txt`, 144 точки clip-path).

Все выводы терминала на слайдах — настоящие, сняты с этого репозитория 06.09.2026 (`captures/`).
Скриншоты отчёта — с `routing_report.html` через headless Edge, кропы — `tools/crop.py`.
Коты и мем — картинки команды, оригиналы в `assets/cats/`, кадрирование — `tools/prep_cats.py`.

Движение живёт только в `index.html` и в артбордах канваса. В `render/*.html` анимации гасятся:
headless-скриншот снимается по «виртуальному» времени и ловит анимацию на середине — слайд
уезжает в PNG, PDF и PPTX полупрозрачным. Гасим именно `animation`, не `opacity`/`transform`/
`clip-path` — на них держатся фон-слова, наклейки и фигуры.

```powershell
node presentation/fonts/embed.mjs                              # один раз: полные woff2 → fonts.css
uv run --with fonttools --with brotli python presentation/tools/subset_fonts.py   # урезанные подмножества
uv run --with pillow python presentation/tools/prep_cats.py    # кадрирование котов
uv run --with pillow python presentation/tools/crop.py         # кропы отчёта и превью для канваса
node presentation/build.mjs                                    # index.html, render/, canvas/
# PNG слайдов: headless Edge по render/slide-*.html (--window-size=1280,720 --force-device-scale-factor=2)
uv run --with python-pptx python presentation/tools/make_pptx.py
```

PDF: `msedge --headless=new --no-pdf-header-footer --print-to-pdf=presentation/MISIS_MOJARUNG.pdf presentation/index.html`.

Пересчитать «печеньку»:

```powershell
node -e "const N=144,L=12,A=0.075;const p=[];for(let i=0;i<N;i++){const t=(i/N)*Math.PI*2;const r=0.5*(1+A*Math.cos(L*t))/(1+A);p.push((50+r*100*Math.cos(t)).toFixed(2)+'% '+(50+r*100*Math.sin(t)).toFixed(2)+'%');}require('fs').writeFileSync('presentation/src/cookie.txt','polygon('+p.join(', ')+')')"
```
