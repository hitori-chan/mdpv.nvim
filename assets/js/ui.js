// Page chrome: the floating button and its menu, preference switches, the
// theme and style pickers, connection status, copy buttons, and keyboard
// shortcuts.
//
// Menu and shortcut card are native popovers: top layer, light dismiss and
// Escape for free. Every choice is a page preference (util.js): a data-*
// attribute on <html> that CSS renders from, persisted by the editor.

import { OCTICON } from './icons.js';
import { cornerDrag, flag, glide, onPref, pref, root, setPref, togglePref } from './util.js';

const $ = (id) => document.getElementById(id);

export function initUI({ article, live, scrollSync, outline, onTheme }) {
  const fab = $('mdpv-fab');
  const fabButton = $('fab-toggle');
  const menu = $('fab-menu');
  const keys = $('mdpv-keys');
  const statusText = $('status-text');

  // --- Switches: <button role="switch" data-pref="…"> ----------------------
  for (const btn of document.querySelectorAll('[role="switch"][data-pref]')) {
    const key = btn.dataset.pref;
    const paint = () => btn.setAttribute('aria-checked', String(flag(key)));
    paint();
    onPref(key, paint);
    btn.addEventListener('click', () => togglePref(key));
  }
  $('sync-group').hidden = !(live && scrollSync);
  for (const el of document.querySelectorAll('[data-live]')) el.hidden = !live;

  // --- Pickers: <div role="radiogroup" data-pref="…"> of [data-value] -------
  const cycle = {};
  for (const group of document.querySelectorAll('[role="radiogroup"][data-pref]')) {
    const key = group.dataset.pref;
    const buttons = [...group.querySelectorAll('[data-value]')];
    const values = buttons.map((b) => b.dataset.value);
    const paint = (value) => {
      for (const b of buttons) b.setAttribute('aria-checked', String(b.dataset.value === value));
    };
    paint(pref(key));
    onPref(key, paint);
    for (const b of buttons) b.addEventListener('click', () => setPref(key, b.dataset.value));
    cycle[key] = () => setPref(key, values[(values.indexOf(pref(key)) + 1) % values.length]);
  }

  // Theme: the stylesheets follow color-scheme, which data-theme sets; the
  // meta tag keeps browser UI (scrollbars, form controls) in step.
  onPref('theme', (theme) => {
    document.querySelector('meta[name="color-scheme"]').content = theme === 'auto' ? 'light dark' : theme;
    onTheme();
  });
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (pref('theme') === 'auto') onTheme();
  });

  // --- Floating button: opens the menu, drags to any corner ----------------
  const wasDrag = cornerDrag(fab, fabButton, 'fab', { onStart: () => menu.hidePopover() });
  // The click ending a drag must not toggle the menu: canceling it skips
  // the button's popovertarget activation.
  fabButton.addEventListener('click', (ev) => {
    if (wasDrag()) ev.preventDefault();
  });
  $('keys-button').addEventListener('click', () => {
    menu.hidePopover();
    keys.showPopover();
  });

  // --- Copy buttons on code blocks (127.0.0.1 is a secure context) ---------
  article.addEventListener('click', (ev) => {
    const btn = ev.target.closest('button.mdpv-copy');
    const code = btn?.parentElement.querySelector('pre > code');
    if (!code) return;
    navigator.clipboard?.writeText(code.textContent).then(() => {
      btn.classList.add('mdpv-copied');
      btn.innerHTML = OCTICON.check;
      setTimeout(() => {
        btn.classList.remove('mdpv-copied');
        btn.innerHTML = OCTICON.copy;
      }, 1500);
    }, () => {});
  });

  // --- Keyboard: Vim-flavored, for people who live in Neovim ---------------
  const scrollBy = (top, behavior = 'instant') => window.scrollBy({ top, behavior });
  const BINDINGS = {
    j: () => scrollBy(64),
    k: () => scrollBy(-64),
    d: () => scrollBy(innerHeight / 2, 'smooth'),
    u: () => scrollBy(-innerHeight / 2, 'smooth'),
    gg: () => glide(0),
    G: () => glide(document.documentElement.scrollHeight),
    ']]': () => outline.step(1),
    '[[': () => outline.step(-1),
    o: () => togglePref('outline'),
    w: () => togglePref('wide'),
    t: cycle.theme,
    s: cycle.style,
    f: () => live && scrollSync && togglePref('follow'),
    m: () => menu.togglePopover(),
    '?': () => keys.togglePopover(),
  };
  let prefix = '';
  let prefixTimer = 0;
  addEventListener('keydown', (ev) => {
    if (ev.ctrlKey || ev.metaKey || ev.altKey || ev.isComposing) return;
    if (ev.target.closest?.('input, textarea, select, [contenteditable]')) return;
    const seq = prefix + ev.key;
    clearTimeout(prefixTimer);
    prefix = '';
    if (BINDINGS[seq]) {
      ev.preventDefault();
      BINDINGS[seq]();
    } else if (Object.keys(BINDINGS).some((k) => k.length > seq.length && k.startsWith(seq))) {
      prefix = seq; // gg, ]], [[
      prefixTimer = setTimeout(() => (prefix = ''), 800);
    }
  });

  return {
    /** Connection state: colors the dot on the button and in the menu. */
    status(state, text, tip) {
      root.dataset.status = state;
      statusText.textContent = text;
      fabButton.title = `mdpv — ${tip} (m)`;
    },
  };
}
