// Скачивает woff2 (кириллица + латиница) для Unbounded и Golos Text из Google Fonts
// и собирает fonts.css с data:-URI — чтобы PDF и экспорт не зависели от сети.
import { readFileSync, writeFileSync } from "node:fs";

const css = readFileSync(new URL("./google.css", import.meta.url), "utf8");
const blocks = css.split("@font-face").slice(1);
const WANT = new Set(["cyrillic", "latin"]);
const out = [];

for (const block of blocks) {
  const subset = (block.match(/\/\*\s*(\S+)\s*\*\//) || [])[1];
  if (!WANT.has(subset)) continue;
  const family = block.match(/font-family:\s*'([^']+)'/)[1];
  const weight = block.match(/font-weight:\s*(\d+)/)[1];
  const url = block.match(/url\(([^)]+)\)/)[1];
  const range = block.match(/unicode-range:\s*([^;]+);/)[1];
  const buf = Buffer.from(await (await fetch(url)).arrayBuffer());
  out.push(`@font-face{font-family:'${family}';font-style:normal;font-weight:${weight};font-display:swap;` +
    `src:url(data:font/woff2;base64,${buf.toString("base64")}) format('woff2');unicode-range:${range};}`);
  console.error(`${family} ${weight} ${subset}: ${buf.length} bytes`);
}

writeFileSync(new URL("./fonts.css", import.meta.url), out.join("\n") + "\n");
console.log(`fonts.css: ${out.length} faces`);
