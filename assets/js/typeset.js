// Lazy typesetting: KaTeX (math) and Mermaid (diagrams); code highlights in
// the render pass (highlight.js).
//
// Both are vendored but fetched only the first time a document needs
// them (CSP script-src 'self' allows same-origin injection). Work is async;
// `current()` tells a pass whether its render is still the newest, so a slow
// pass never touches a newer one. URLs resolve relative to this module, so
// they inherit the asset version in its path.

import { OCTICON } from './icons.js';
import { load, root } from './util.js';

const vendor = (path) => new URL(`../vendor/${path}`, import.meta.url).href;

const once = (fn) => {
  let p = null;
  return () => (p ??= fn());
};

const loadKatex = once(() =>
  Promise.all([
    load('script', { src: vendor('katex/katex.min.js') }),
    load('link', { rel: 'stylesheet', href: vendor('katex/katex.min.css') }),
  ]),
);

export const isDark = () =>
  root.dataset.theme === 'dark' || (root.dataset.theme !== 'light' && matchMedia('(prefers-color-scheme: dark)').matches);

const mermaidConfig = () => ({ startOnLoad: false, securityLevel: 'strict', theme: isDark() ? 'dark' : 'default' });
let mermaidLoaded = null;
const loadMermaid = once(
  () => (mermaidLoaded = load('script', { src: vendor('mermaid.min.js') }).then(() => window.mermaid.initialize(mermaidConfig()))),
);

function typesetMath(article, current, options) {
  const nodes = article.querySelectorAll('.mdpv-math:not(.mdpv-typeset)');
  if (nodes.length === 0) return;
  loadKatex().then(() => {
    if (!current()) return;
    for (const el of nodes) {
      const src = el.dataset.mdpvSrc ?? el.textContent;
      try {
        window.katex.render(src, el, {
          ...options,
          displayMode: el.classList.contains('mdpv-math-display'),
          throwOnError: false, // invalid TeX renders in red, like a typo should
          // KaTeX writes \gdef definitions into the macros object it's given;
          // a copy per block keeps rendering order-independent.
          macros: options.macros ? { ...options.macros } : undefined,
        });
      } catch {
        el.textContent = src;
      }
      el.classList.add('mdpv-typeset');
    }
  }, () => {});
}

// Pan/zoom on rendered diagrams: hover controls (+ / − / reset), drag to pan
// while zoomed, double-click to reset. The transform lives on the <svg>
// inside the morphdom-preserved node, so the view survives edits elsewhere
// and resets when the diagram itself changes.
function addDiagramControls(div) {
  const svg = div.querySelector('svg');
  if (!svg) return;
  const view = { x: 0, y: 0, k: 1 };
  const apply = () => {
    const idle = view.k === 1 && view.x === 0 && view.y === 0;
    svg.style.transform = idle ? '' : `translate(${view.x}px, ${view.y}px) scale(${view.k})`;
    div.classList.toggle('mdpv-zoomed', !idle);
  };
  const zoom = (f) => {
    view.k = Math.min(8, Math.max(0.25, view.k * f));
    apply();
  };
  const reset = () => {
    Object.assign(view, { x: 0, y: 0, k: 1 });
    apply();
  };
  const controls = document.createElement('div');
  controls.className = 'mdpv-diagram-controls';
  for (const [icon, title, fn] of [
    [OCTICON.plus, 'Zoom in', () => zoom(1.25)],
    [OCTICON.dash, 'Zoom out', () => zoom(0.8)],
    [OCTICON.sync, 'Reset view', reset],
  ]) {
    const b = controls.appendChild(document.createElement('button'));
    b.type = 'button';
    b.title = title;
    b.innerHTML = icon;
    b.addEventListener('click', fn);
  }
  div.appendChild(controls);
  let pan = null;
  svg.addEventListener('pointerdown', (ev) => {
    if (view.k === 1 || ev.button !== 0) return;
    pan = { x: ev.clientX - view.x, y: ev.clientY - view.y };
    svg.setPointerCapture(ev.pointerId);
    ev.preventDefault(); // no text selection while panning
  });
  svg.addEventListener('pointermove', (ev) => {
    if (!pan) return;
    view.x = ev.clientX - pan.x;
    view.y = ev.clientY - pan.y;
    apply();
  });
  const endPan = () => {
    pan = null;
  };
  svg.addEventListener('pointerup', endPan);
  svg.addEventListener('pointercancel', endPan);
  div.addEventListener('dblclick', reset);
}

let mermaidSeq = 0;

function typesetMermaid(article, current) {
  const blocks = article.querySelectorAll('.mdpv-mermaid:not(.mdpv-typeset)');
  if (blocks.length === 0) return;
  loadMermaid().then(async () => {
    for (const div of blocks) {
      if (!current()) return;
      const id = `mdpv-mermaid-${++mermaidSeq}`;
      try {
        const { svg } = await window.mermaid.render(id, div.dataset.mdpvSrc ?? div.textContent);
        if (!current()) return;
        div.innerHTML = svg; // vendored mermaid in strict mode
        addDiagramControls(div);
      } catch {
        document.getElementById(`d${id}`)?.remove(); // mermaid's error scratch node
        div.classList.add('mdpv-error'); // invalid diagram: the source stays visible
      }
      div.classList.add('mdpv-typeset');
    }
  }, () => {});
}

/** Typeset whatever `article` needs; `current()` is false once superseded. */
export function typeset(article, features, current) {
  if (features.math !== false) typesetMath(article, current, typeof features.math === 'object' ? features.math : {});
  if (features.mermaid !== false) typesetMermaid(article, current);
}

/** Effective color scheme changed: redraw diagrams in the matching theme. */
export function retheme(article, current) {
  mermaidLoaded?.then(() => {
    window.mermaid.initialize(mermaidConfig());
    for (const div of article.querySelectorAll('.mdpv-mermaid.mdpv-typeset')) {
      div.classList.remove('mdpv-typeset', 'mdpv-error', 'mdpv-zoomed');
      div.textContent = div.dataset.mdpvSrc || '';
    }
    typesetMermaid(article, current);
  });
}
