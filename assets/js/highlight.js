// Code highlighting with starry-night, GitHub's own highlighter: the Linguist
// grammars GitHub uses (compiled to JSON by scripts/grammars.mjs), tokens as
// GitHub's pl-* classes, colored by github-markdown-css.
//
// The engine (vscode-textmate on the Oniguruma WASM) warms up at page load,
// alongside the first render; each grammar loads on first use. Once a
// language is ready, its code highlights inside the render pass, before the
// diff: edits never flash plain code, and a cache keyed by language and text
// skips blocks that didn't change.

import { load } from './util.js';

const SN = (path) => new URL(`../vendor/starry-night/${path}`, import.meta.url).href;
const MAX_CODE = 200_000; // characters; bigger blocks stay plain
const fetchJson = (path) => fetch(SN(path)).then((r) => (r.ok ? r.json() : null));

let engine = null; // { index, registry, parse, colors } once booted
let booting = null;
let notify = () => {};
const grammars = new Map(); // scope -> IGrammar, or null when it failed to load
const pending = new Set(); // scopes loading into the registry
const cache = new Map(); // `${scope}\n${text}` -> { node, gen }
let gen = 0;

async function boot() {
  const [tables, { parse }, { theme }] = await Promise.all([
    fetchJson('index.json'),
    import(SN('parse.js')),
    import(SN('theme.js')),
    load('script', { src: SN('vscode-textmate.js') }),
    load('script', { src: SN('vscode-oniguruma.js') }),
  ]);
  await window.onig.loadWASM(await fetch(SN('onig.wasm'))); // streamed; Chrome caches the compiled module
  const shipped = new Set(tables.scopes);
  const registry = new window.vscodetextmate.Registry({
    onigLib: Promise.resolve(window.onig),
    // Embedded languages load through here too; unshipped ones stay plain.
    loadGrammar: (scope) => (shipped.has(scope) ? fetchJson(`lang/${scope}.json`) : null),
  });
  registry.setTheme(theme);
  const index = {
    names: new Map(Object.entries(tables.names)),
    extensions: new Map(Object.entries(tables.extensions)),
    extensionsWithDot: new Map(Object.entries(tables.extensionsWithDot)),
  };
  engine = { index, registry, parse, colors: registry.getColorMap() };
  notify();
}

/** Start the engine; `onLoad` runs whenever more code can be highlighted. */
export function startHighlighter(onLoad) {
  notify = onLoad;
  booting ??= boot().catch(() => {}); // no engine: code stays plain
  return booting;
}

// starry-night's flagToScope: a name (`ts`), an extension, or a path ending
// in one.
function flagToScope({ names, extensions, extensionsWithDot }, flag) {
  const normal = flag.replace(/^[ \t]+|[ \t/]+$/g, '').toLowerCase();
  if (names.has(normal)) return names.get(normal);
  const dot = normal.lastIndexOf('.');
  if (dot === -1) return extensions.get(`.${normal}`);
  const ext = normal.slice(dot);
  return extensions.get(ext) || extensionsWithDot.get(ext);
}

function request(scope) {
  if (pending.has(scope)) return;
  pending.add(scope);
  engine.registry
    .loadGrammar(scope)
    .catch(() => null)
    .then((grammar) => {
      grammars.set(scope, grammar);
      pending.delete(scope);
      notify();
    });
}

// starry-night's hast: spans with a className, and text.
function toDom(node) {
  if (node.type === 'text') return document.createTextNode(node.value);
  const el = node.type === 'element' ? document.createElement(node.tagName) : document.createDocumentFragment();
  if (node.properties?.className) el.className = node.properties.className.join(' ');
  for (const child of node.children) el.appendChild(toDom(child));
  return el;
}

/**
 * Highlight root's code blocks whose language is ready and request the rest.
 * Blocks are marked `mdpv-hl` once settled (highlighted, or plain for good).
 * `render`: root is a fresh rendering; cache entries unused by the last two
 * renderings are dropped.
 */
export function highlightCode(root, { render = false } = {}) {
  if (render) gen += 1;
  if (!engine) return; // boot() notifies
  for (const code of root.querySelectorAll('pre > code[class*="language-"]:not(.mdpv-hl)')) {
    const scope = flagToScope(engine.index, /language-(\S+)/.exec(code.className)?.[1] ?? '');
    const grammar = scope ? grammars.get(scope) : null;
    if (grammar === undefined) {
      request(scope);
      continue;
    }
    code.classList.add('mdpv-hl');
    const text = code.textContent;
    if (!grammar || text.length > MAX_CODE) continue; // unknown language: plain, like GitHub
    const key = `${scope}\n${text}`;
    let hit = cache.get(key);
    if (!hit) {
      try {
        hit = { node: toDom(engine.parse(text, grammar, engine.colors)) };
      } catch {
        continue;
      }
      cache.set(key, hit);
    }
    hit.gen = gen;
    code.replaceChildren(hit.node.cloneNode(true));
  }
  if (render) {
    for (const [key, hit] of cache) if (hit.gen < gen - 1) cache.delete(key);
  }
}
