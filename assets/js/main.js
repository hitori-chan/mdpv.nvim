// mdpv page: boots from the embedded payload, renders, and follows the
// editor over Server-Sent Events.

import { highlightCode, startHighlighter } from './highlight.js';
import { initOutline } from './outline.js';
import { createRenderer } from './render.js';
import { initSync } from './sync.js';
import { retheme, typeset } from './typeset.js';
import { initUI } from './ui.js';
import { applyPrefs, post, setToken } from './util.js';

// {token, title, md, revision, epoch, modifiable, features, static?, base?}
// — embedded server-side for an instant first paint, then dropped so the
// source isn't kept twice.
const bootEl = document.getElementById('mdpv-boot');
const BOOT = JSON.parse(bootEl.textContent);
bootEl.remove();
setToken(BOOT.token);

const FEATURES = BOOT.features || {};
const LIVE = !BOOT.static; // a linked .md rendered from disk has no buffer behind it
const SCROLL_SYNC = !!FEATURES.scrollSync;
const article = document.getElementById('content');

// Nearly every document has code: warm the highlighter up alongside the
// first render, then fill in code blocks as their languages become ready.
startHighlighter(() => highlightCode(article));
const render = createRenderer(article, FEATURES, { tasks: LIVE });
const outline = initOutline(article);
const sync = initSync(article, { live: LIVE, scrollSync: SCROLL_SYNC, outline });

let generation = 0;
const current = (gen) => () => gen === generation;
const ui = initUI({
  article,
  live: LIVE,
  scrollSync: SCROLL_SYNC,
  outline,
  onTheme: () => retheme(article, current(generation)),
});

// --- Rendering ---------------------------------------------------------------

const doc = {
  src: null,
  base: BOOT.base || `/f/${BOOT.token}`,
  epoch: BOOT.epoch || 1, // bumps when the follower switches buffers
  readonly: !LIVE || BOOT.modifiable === false,
};
let deferred = false;
let firstPaint = true;

function paint() {
  if (document.hidden) {
    deferred = true; // a background tab renders once, when it is looked at
    return;
  }
  deferred = false;
  generation += 1;
  const x = scrollX;
  const y = scrollY;
  render(doc.src, { base: doc.base, bust: doc.epoch > 1 ? doc.epoch : 0, readonly: doc.readonly });
  // Typesetting first: its loads start before the refreshes below force the
  // first layout (which can wait on fonts); its DOM work runs after them.
  typeset(article, FEATURES, current(generation));
  sync.refresh();
  outline.refresh();
  if (firstPaint) {
    firstPaint = false;
    if (location.hash) document.getElementById(decodeURIComponent(location.hash.slice(1)))?.scrollIntoView();
  } else {
    scrollTo(x, y);
  }
}

function show(src, { readonly = doc.readonly } = {}) {
  if (src === doc.src && readonly === doc.readonly) return;
  doc.src = src;
  doc.readonly = readonly;
  paint();
}

document.addEventListener('visibilitychange', () => {
  if (document.hidden) return;
  if (deferred) paint();
  sync.catchUp();
});

if (typeof BOOT.md === 'string') show(BOOT.md);

// --- Live updates ------------------------------------------------------------

if (!LIVE) {
  ui.status('static', 'static file', 'rendered from disk, not a live buffer');
} else {
  ui.status('live', 'live', 'connected, updates as you edit');

  // Task checkboxes: the editor flips [ ]/[x] on that line, and the change
  // streams back through the normal update, which confirms the state.
  article.addEventListener('change', (ev) => {
    const box = ev.target;
    if (!box.matches?.('input.task-list-item-checkbox')) return;
    const line = +box.closest('[data-source-line]')?.dataset.sourceLine;
    if (line) post('sync', { toggle: { line, checked: box.checked } });
  });

  const es = new EventSource(`/events/${BOOT.token}?since=${encodeURIComponent(BOOT.revision ?? '')}`);
  const on = (event, fn) =>
    es.addEventListener(event, (ev) => {
      let data;
      try {
        data = JSON.parse(ev.data);
      } catch {
        return;
      }
      fn(data);
    });

  on('update', (p) => {
    ui.status('live', 'live', 'connected, updates as you edit');
    if (p.title) document.title = `${p.title} · mdpv`;
    if (p.epoch && p.epoch !== doc.epoch) {
      // The follower moved to another buffer: a new document, from the top
      // (a scroll event to the cursor line follows).
      doc.epoch = p.epoch;
      doc.src = null;
      history.replaceState(null, '', location.pathname);
      scrollTo(0, 0);
    }
    show(typeof p.md === 'string' ? p.md : '', { readonly: p.modifiable === false });
  });

  on('scroll', (p) => {
    if (typeof p.line === 'number') sync.follow(p.line);
  });

  // Live asset reload: files the page loaded changed on disk; cache-bust
  // the matching media in place.
  let reloads = 0;
  on('assets', (p) => {
    if (!Array.isArray(p.paths)) return;
    const changed = new Set(p.paths.map((path) => `${doc.base}/${path}`));
    reloads += 1;
    for (const el of article.querySelectorAll('img[src], video[src], audio[src], source[src]')) {
      const url = new URL(el.getAttribute('src'), location.href);
      let file;
      try {
        file = decodeURIComponent(url.pathname);
      } catch {
        continue;
      }
      if (url.origin !== location.origin || !changed.has(file)) continue;
      url.searchParams.set('r', String(reloads));
      el.setAttribute('src', url.pathname + url.search);
      const media = el.tagName === 'SOURCE' ? el.parentElement : el;
      if (media?.tagName === 'VIDEO' || media?.tagName === 'AUDIO') media.load();
    }
  });

  on('prefs', applyPrefs); // changed in another tab
  on('config', () => location.reload());
  on('close', () => {
    es.close();
    ui.status('ended', 'closed', 'the preview was closed in Neovim');
  });

  // A reconnect whose buffer did not change gets no update: say live here.
  let failures = 0;
  es.onopen = () => {
    failures = 0;
    ui.status('live', 'live', 'connected, updates as you edit');
  };
  es.onerror = () => {
    if (es.readyState === EventSource.CLOSED) {
      // Refused for good (e.g. Neovim restarted: this preview is gone).
      ui.status('ended', 'disconnected', 'this preview no longer exists — run :Preview again');
    } else if (++failures > 10) {
      // Nothing listening for ~10 s: Neovim is gone. Keep retrying quietly.
      ui.status('ended', 'disconnected', 'Neovim is not reachable — run :Preview again');
    } else {
      ui.status('reconnecting', 'reconnecting…', 'lost the connection to Neovim, retrying');
    }
  };
}
