// mdbook preprocessor: render ```mermaid blocks to inline SVG with Pele
// (https://pele.run) at build time. The book ships no diagram JavaScript.
// It also fixes the links of the first page, which includes ../README.md: the
// README links docs/x.md from the repository root, the book serves x.md, and a
// root file (CONTRIBUTING.md, LICENSE) is not in the book, so it goes to the forge.
// Usage: node mdbook-pele.mjs <path to pele/dist/pele.js> [supports <renderer>]
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const [peleJs, cmd] = process.argv.slice(2);
if (cmd === "supports") process.exit(0);

const { render } = await import(pathToFileURL(peleJs).href);
const [, book] = JSON.parse(readFileSync(0, "utf8"));

let failed = false;
const fence = /^```mermaid[^\n]*\n([\s\S]*?)^```[ \t]*$/gm;
const forge = "https://code.in.a.flawed.cloud/yolobox/golconda/src/branch/main/";

function readmeLinks(text) {
  return text.replace(/\]\((?![a-z]+:|#|\/)([^)\s]+)\)/g, (_, target) =>
    target.startsWith("docs/") ? `](${target.slice(5)})` : `](${forge}${target})`,
  );
}

function renderChapter(ch) {
  if (ch.path === "index.md") ch.content = readmeLinks(ch.content);
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
