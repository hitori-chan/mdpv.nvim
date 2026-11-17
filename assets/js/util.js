// Shared helpers: editor POSTs, page preferences, programmatic scrolling,
// binary search over document-ordered elements, corner-parking drags.

export const root = document.documentElement;

// --- Editor messages ---------------------------------------------------------

let token = '';
export const setToken = (t) => {
  token = t;
};

/** Fire-and-forget JSON POST to an editor route (/sync, /prefs). */
export function post(route, body) {
  fetch(`/${route}/${token}`, { method: 'POST', body: JSON.stringify(body) }).catch(() => {});
}

// --- Preferences -------------------------------------------------------------
// The editor owns them (see lua/mdpv/prefs.lua) and renders the page with the
// current values on <html> as data-* attributes, which CSS reads directly.
// A change here is applied in place, POSTed back, and the editor echoes it to
// every other open tab (applyPrefs).

const listeners = {};

export const pref = (key) => root.dataset[key];
export const flag = (key) => root.dataset[key] === '1';
export const onPref = (key, fn) => (listeners[key] ??= []).push(fn);

// Preferences that reflow the page: applying one keeps the reader's place.
const REFLOW = new Set(['style', 'wide', 'outline']);

export function setPref(key, value, persist = true) {
  if (root.dataset[key] === value) return;
  const apply = () => {
    root.dataset[key] = value;
    for (const fn of listeners[key] ?? []) fn(value);
  };
  if (REFLOW.has(key)) keepPlace(apply);
  else apply();
  if (persist) post('prefs', { [key]: value });
}

export const togglePref = (key) => setPref(key, flag(key) ? '0' : '1');

export function applyPrefs(prefs) {
  for (const [key, value] of Object.entries(prefs)) setPref(key, value, false);
}

// --- Scrolling ---------------------------------------------------------------

// Smooth scrolls the page starts itself (follow cursor, outline jumps) must
// not be mistaken for the reader scrolling: scroll sync and the outline spy
// stand down until the glide has settled.
let glideUntil = 0;
export const gliding = () => performance.now() < glideUntil;

export function glide(top, behavior = 'smooth') {
  glideUntil = performance.now() + 1200;
  window.scrollTo({ top: Math.max(0, top), behavior });
}

// Where scroll sync and the outline spy aim in the viewport: the upper
// third, which is where your eyes are.
export const ANCHOR = 0.35;

/** Document y of an element's top edge. */
export const pageY = (el) => el.getBoundingClientRect().top + window.scrollY;

/** Run `change` (a reflow) without moving what the reader is looking at: the
 *  block under the viewport anchor stays put, at the same point within it.
 *  Browser scroll anchoring can't: margins and widths change around it. */
function keepPlace(change) {
  const probe = innerHeight * ANCHOR;
  let el = null;
  if (scrollY > 0) {
    // Last visible block starting above the anchor (document order).
    for (const b of document.querySelectorAll('#content [data-source-line]')) {
      const r = b.getBoundingClientRect();
      if (r.height === 0) continue; // folded away
      if (r.top > probe) break;
      el = b;
    }
  }
  const before = el?.getBoundingClientRect();
  change();
  if (!before) return;
  const after = el.getBoundingClientRect();
  const into = Math.min(probe - before.top, before.height) / before.height;
  const past = Math.max(0, probe - before.bottom); // anchor in the gap below it
  glide(scrollY + after.top + into * after.height + past - probe, 'instant');
}

/** Rightmost index in `els` whose measure(el) <= limit, or -1. */
export function bisect(els, limit, measure) {
  let lo = 0;
  let hi = els.length - 1;
  let found = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (measure(els[mid]) <= limit) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return found;
}

// --- Lazy assets -------------------------------------------------------------

export function load(tag, attrs) {
  return new Promise((resolve, reject) => {
    const el = document.createElement(tag);
    Object.assign(el, attrs, { onload: resolve, onerror: reject });
    document.head.appendChild(el);
  });
}

// --- Corner parking ----------------------------------------------------------

export const EDGE = 20; // px from the viewport edges, every corner

/**
 * Drag `el` by `handle` and park it in the nearest corner, stored as pref
 * `key` (CSS anchors the element from it). Under 5px of travel a press stays
 * a click; past it the element follows the pointer, then glides to the
 * corner. Moves are tracked on window without pointer capture: capture
 * would retarget the closing click away from the element under the pointer,
 * and handle-scoped listeners lose fast drags.
 * Returns wasDrag(): true once for the click that ends a drag.
 */
export function cornerDrag(el, handle, key, { onStart, offset = () => 0 } = {}) {
  let drag = null;
  let dragged = false;
  handle.addEventListener('pointerdown', (ev) => {
    if (ev.button !== 0) return;
    dragged = false;
    const r = el.getBoundingClientRect();
    drag = { id: ev.pointerId, x: ev.clientX, y: ev.clientY, dx: ev.clientX - r.left, dy: ev.clientY - r.top, moved: false };
  });
  window.addEventListener('pointermove', (ev) => {
    if (!drag || ev.pointerId !== drag.id) return;
    if (!drag.moved) {
      if (Math.hypot(ev.clientX - drag.x, ev.clientY - drag.y) < 5) return;
      drag.moved = true;
      el.classList.add('dragging');
      onStart?.();
    }
    el.style.inset = `${Math.max(0, Math.min(ev.clientY - drag.dy, innerHeight - el.offsetHeight))}px auto auto ${Math.max(0, Math.min(ev.clientX - drag.dx, innerWidth - el.offsetWidth))}px`;
  });
  const end = (ev) => {
    if (!drag || ev.pointerId !== drag.id) return;
    dragged = drag.moved;
    drag = null;
    el.classList.remove('dragging');
    if (!dragged) return;
    const corner = (ev.clientY < innerHeight / 2 ? 't' : 'b') + (ev.clientX < innerWidth / 2 ? 'l' : 'r');
    const dy = EDGE + offset(corner);
    el.classList.add('snapping');
    el.style.inset = `${corner[0] === 't' ? dy : innerHeight - el.offsetHeight - dy}px auto auto ${corner[1] === 'l' ? EDGE : innerWidth - el.offsetWidth - EDGE}px`;
    setTimeout(() => {
      el.classList.remove('snapping');
      el.style.inset = '';
      setPref(key, corner);
    }, 160);
  };
  window.addEventListener('pointerup', end);
  window.addEventListener('pointercancel', end);
  return () => {
    const was = dragged;
    dragged = false;
    return was;
  };
}
