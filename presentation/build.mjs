// Сборка деки из presentation/src:
//   index.html        — показ и печать (стрелки, F — на весь экран, P — печать)
//   render/*.html     — по слайду отдельно, для скриншотов и PDF
//   canvas/*.dc.html  — артборды для канваса (шрифты вшиты, вид не зависит от сети)
// Запуск: node presentation/build.mjs
import { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(fileURLToPath(import.meta.url));
const SRC = join(ROOT, "src");
const read = (p) => readFileSync(p, "utf8");
const out = (dir) => { mkdirSync(dir, { recursive: true }); return dir; };

// Форму «печеньки» держим отдельным файлом: 144 точки в CSS читать невозможно.
// Пересчитать — см. presentation/README.md.
const theme = read(join(SRC, "theme.css")).replace("{{cookie}}", read(join(SRC, "cookie.txt")).trim());
const fonts = read(join(ROOT, "fonts", "fonts.css"));          // полные подмножества — для index и render
const fontsMin = read(join(ROOT, "fonts", "fonts-min.css"));   // урезанные — вшиваются в каждый артборд

// Картинки: полноразмерные — data:-URI в index/render, для канваса — уменьшенные jpg по имени файла.
const IMAGES = {
  team: { full: join(ROOT, "assets", "team.jpg"), canvas: "team.jpg" },
  meme: { full: join(ROOT, "assets", "meme.jpg"), canvas: "meme.jpg" },
  cat_cook: { full: join(ROOT, "assets", "cat_cook.jpg"), canvas: "cat_cook.jpg" },
  cat_sleep: { full: join(ROOT, "assets", "cat_sleep.jpg"), canvas: "cat_sleep.jpg" },
  cat_wow: { full: join(ROOT, "assets", "cat_wow.jpg"), canvas: "cat_wow.jpg" },
  cat_space: { full: join(ROOT, "assets", "cat_space.jpg"), canvas: "cat_space.jpg" },
  cat_face: { full: join(ROOT, "assets", "cat_face.jpg"), canvas: "cat_face.jpg" },
  report_distribution: { full: join(ROOT, "captures", "report_distribution.png"), canvas: "report_distribution.jpg" },
  report_reco_first: { full: join(ROOT, "captures", "report_reco_first.png"), canvas: "report_reco_first.jpg" },
};
const dataUri = (path) => {
  const mime = path.endsWith(".png") ? "image/png" : "image/jpeg";
  return `data:${mime};base64,${readFileSync(path).toString("base64")}`;
};

// QR из assets/qr.svg: берём только путь и viewBox, размер задаём сами — генератор пишет мм.
const qrSource = read(join(ROOT, "assets", "qr.svg"));
const qrViewBox = (qrSource.match(/viewBox="([^"]+)"/) || [null, "0 0 41 41"])[1];
const qrPath = (qrSource.match(/<path[^>]*\sd="([^"]+)"/) || [null, ""])[1];
if (!qrPath) throw new Error("assets/qr.svg без <path> — перегенерировать QR");
const qr = `<svg viewBox="${qrViewBox}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="QR: github.com/Mojarung/hack_genesis_2026"><path d="${qrPath}" fill="#1c1b1f"/></svg>`;

const slideFiles = readdirSync(join(SRC, "slides")).filter((f) => f.endsWith(".html")).sort();
const usedImages = new Set();
const slides = slideFiles.map((file, index) => {
  const raw = read(join(SRC, "slides", file));
  const name = raw.match(/data-name="([^"]+)"/)[1];
  const title = raw.match(/data-title="([^"]+)"/)[1];
  const number = String(index + 1).padStart(2, "0");
  const withNumber = raw.replace(/<\/section>\s*$/, `  <div class="num">${number}</div>\n</section>\n`);
  const fill = (mode) => withNumber
    .replace(/\{\{img:([a-z_]+)\}\}/g, (_, key) => {
      const image = IMAGES[key];
      if (!image) throw new Error(`нет картинки ${key} (${file})`);
      usedImages.add(image.canvas);
      return mode === "canvas" ? image.canvas : dataUri(image.full);
    })
    .replace("{{qr}}", () => qr);
  return { file, name, title, number, index, html: fill("full"), canvasHtml: fill("canvas") };
});

// ---------- index.html: показ и печать ----------
const deckCss = `
html, body { margin: 0; height: 100%; background: #08070c; }
#deck { position: fixed; left: 50%; top: 50%; width: 1280px; height: 720px; transform: translate(-50%, -50%); transform-origin: center; }
#deck .slide { position: absolute; left: 0; top: 0; display: none; }
#deck .slide.active { display: block; }
#hint { position: fixed; left: 16px; bottom: 12px; font: 13px/1.4 "Golos Text", system-ui, sans-serif; color: rgba(255,255,255,0.45); }
@page { size: 1280px 720px; margin: 0; }
@media print {
  html, body { background: #fff; height: auto; }
  #deck { position: static; transform: none !important; width: 1280px; height: auto; }
  #deck .slide { position: relative; display: block !important; page-break-after: always; break-after: page; }
  #hint { display: none; }
}
`;
const deckJs = `
(function () {
  var slides = Array.prototype.slice.call(document.querySelectorAll('#deck .slide'));
  var i = Math.max(0, Math.min(slides.length - 1, (parseInt(location.hash.slice(1), 10) || 1) - 1));
  function show() { slides.forEach(function (s, k) { s.classList.toggle('active', k === i); }); history.replaceState(null, '', '#' + (i + 1)); }
  function fit() { var sc = Math.min(window.innerWidth / 1280, window.innerHeight / 720); document.getElementById('deck').style.transform = 'translate(-50%, -50%) scale(' + sc + ')'; }
  function next() { i = Math.min(i + 1, slides.length - 1); show(); }
  function prev() { i = Math.max(i - 1, 0); show(); }
  window.addEventListener('keydown', function (e) {
    var k = e.key;
    if (k === 'ArrowRight' || k === 'ArrowDown' || k === ' ' || k === 'PageDown' || k === 'Enter') { e.preventDefault(); next(); }
    else if (k === 'ArrowLeft' || k === 'ArrowUp' || k === 'PageUp' || k === 'Backspace') { e.preventDefault(); prev(); }
    else if (k === 'f' || k === 'F' || k === 'а' || k === 'А') { (document.documentElement.requestFullscreen || function () {}).call(document.documentElement); }
    else if (k === 'p' || k === 'P' || k === 'з' || k === 'З') { window.print(); }
    else if (k === 'Home') { i = 0; show(); }
    else if (k === 'End') { i = slides.length - 1; show(); }
  });
  window.addEventListener('click', function (e) { if (e.target.closest('a')) return; e.clientX > window.innerWidth / 2 ? next() : prev(); });
  window.addEventListener('resize', fit);
  window.addEventListener('hashchange', function () { var n = parseInt(location.hash.slice(1), 10); if (n >= 1 && n <= slides.length) { i = n - 1; show(); } });
  show(); fit();
})();
`;
const indexHtml = `<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PayoutRouter — MISIS MOJARUNG</title>
<style>${fonts}</style>
<style>${theme}</style>
<style>${deckCss}</style>
</head>
<body>
<div id="deck">
${slides.map((s) => s.html).join("\n")}
</div>
<div id="hint">← → листать · F — на весь экран · P — печать</div>
<script>${deckJs}</script>
</body>
</html>
`;
writeFileSync(join(ROOT, "index.html"), indexHtml);

// ---------- render/slide-NN.html: один слайд 1280×720 без обвязки — для скриншотов ----------
// Движение здесь выключено: headless-скриншот снимается по «виртуальному» времени и ловит
// анимацию на середине — слайд уезжает в PNG, PDF и PPTX полупрозрачным.
// Гасим только анимации: `animation: none` сам возвращает элементу конечный вид.
// Трогать opacity, transform и clip-path нельзя — на них держатся фон-слова, наклейки и фигуры.
const noMotion = `.anim, .anim-pop, .anim-fade, .term .type, .term .cur, .term .ln,
  .anim::before, .anim::after { animation: none !important; transition: none !important; }`;
const renderDir = out(join(ROOT, "render"));
for (const s of slides) {
  writeFileSync(join(renderDir, `slide-${s.number}.html`), `<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><title>${s.number} · ${s.title}</title>
<style>${fonts}</style><style>${theme}</style>
<style>html, body { margin: 0; width: 1280px; height: 720px; overflow: hidden; background: #08070c; }
${noMotion}</style>
</head><body>
${s.html}
</body></html>
`);
}

// ---------- canvas/*.dc.html + canvas.json ----------
const canvasDir = out(join(ROOT, "canvas"));
for (const s of slides) {
  writeFileSync(join(canvasDir, `${s.name}.dc.html`), `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <style>
${fontsMin}
  </style>
  <style>
    body { margin: 0; background: #08070c; }
${theme}
  </style>
</helmet>
${s.canvasHtml}
</x-dc>
</body>
</html>
`);
}
const COLS = 4;
const canvas = {
  artboards: slides.map((s) => ({
    file: `${s.name}.dc.html`,
    title: `${s.number} · ${s.title}`,
    x: (s.index % COLS) * (1280 + 120),
    y: Math.floor(s.index / COLS) * (720 + 180),
    w: 1280,
    h: 720,
    print: "fixed",
  })),
  launch: { view: "canvas" },
};
writeFileSync(join(canvasDir, "canvas.json"), JSON.stringify(canvas, null, 2) + "\n");
writeFileSync(join(canvasDir, "images.txt"), [...usedImages].sort().join("\n") + "\n");

console.log(`слайдов: ${slides.length}; index.html ${Math.round(indexHtml.length / 1024)} KB; ` +
  `картинки: ${[...usedImages].join(", ")}`);
if (!existsSync(join(ROOT, "canvas", "img"))) console.error("нет presentation/canvas/img — сначала uv run --with pillow python presentation/tools/crop.py");
