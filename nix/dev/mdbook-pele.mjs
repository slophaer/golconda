// mdbook preprocessor: render ```mermaid blocks to inline SVG with Pele
// (https://pele.run) at build time. The book ships no diagram JavaScript.
// Usage: node mdbook-pele.mjs <path to pele/dist/pele.js> [supports <renderer>]
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const [peleJs, cmd] = process.argv.slice(2);
if (cmd === "supports") process.exit(0);

const { render } = await import(pathToFileURL(peleJs).href);
const [, book] = JSON.parse(readFileSync(0, "utf8"));

let failed = false;
const fence = /^```mermaid[^\n]*\n([\s\S]*?)^```[ \t]*$/gm;

function renderChapter(ch) {
  ch.content = ch.content.replace(fence, (_, src) => {
    try {
      return `<div class="pele-diagram">${render(src).svg}</div>\n`;
    } catch (e) {
      failed = true;
      console.error(`mdbook-pele: ${ch.path ?? ch.name}: ${e.message}`);
      return _;
    }
  });
  (ch.sub_items ?? []).forEach(walk);
}

function walk(item) {
  if (item && item.Chapter) renderChapter(item.Chapter);
}

(book.items ?? book.sections ?? []).forEach(walk);
if (failed) process.exit(1);
process.stdout.write(JSON.stringify(book));
