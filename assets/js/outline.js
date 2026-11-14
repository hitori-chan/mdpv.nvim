// Floating outline. Collapsed, it is a rail of dashes — one per heading,
// longer for higher levels, the section in view accented — that covers next
// to nothing. Hovering (after a short intent delay) or focusing it expands
// it in place into the full heading list; leaving collapses it. Rebuilt only
// when the headings change; scroll-spied against the same viewport anchor as
// scroll sync. Corner-parked by drag like the menu button.

import { ANCHOR, bisect, cornerDrag, flag, glide, gliding, onPref, pageY, pref } from './util.js';

export function initOutline(article) {
  const toc = document.getElementById('mdpv-toc');
  const list = document.getElementById('outline-list');
  const toggle = document.querySelector('[data-pref="outline"]');
  let heads = [];
  let signature = '';
  let active = null;

  function paint() {
    toggle.hidden = heads.length === 0;
    toc.hidden = !(flag('outline') && heads.length > 0);
    if (!toc.hidden) spy();
  }

  function setActive(link) {
    if (link === active) return;
    active?.classList.remove('active');
    active = link || null;
    if (link) {
      link.classList.add('active');
      link.scrollIntoView({ block: 'nearest' });
    }
  }

  // The heading under the viewport anchor. A glide in flight (outline click,
  // cursor follow) already set the right item; the spy would fight it.
  function spy() {
    if (toc.hidden || heads.length === 0 || gliding()) return;
    const i = bisect(heads, scrollY + innerHeight * ANCHOR, pageY);
    setActive(list.children[Math.max(i, 0)]);
  }

  function rebuild() {
    active = null;
    list.replaceChildren(
      ...heads.map((h) => {
        const a = document.createElement('a');
        a.href = `#${h.id}`;
        a.className = `outline-${h.tagName.toLowerCase()}`;
        a.title = h.textContent; // full text when the label ellipsizes
        const bar = a.appendChild(document.createElement('span'));
        bar.className = 'toc-bar'; // the collapsed-rail dash
        const label = a.appendChild(document.createElement('span'));
        label.className = 'toc-text';
        label.textContent = h.textContent;
        return a;
      }),
    );
  }

  /** ]] / [[: next heading, or back to the start of this section (and on
   *  to the previous one when already there), like Vim's section motions. */
  let stepped = { at: 0, index: -1 }; // a step's glide is still landing: keep stepping from its target
  function step(dir) {
    if (heads.length === 0) return;
    let k;
    if (performance.now() - stepped.at < 1000) {
      k = stepped.index + dir;
    } else {
      const i = bisect(heads, scrollY + 16, pageY); // last heading at/above the top edge
      const atIt = i >= 0 && pageY(heads[i]) > scrollY - 4;
      k = dir > 0 ? i + 1 : atIt ? i - 1 : i;
    }
    k = Math.min(k, heads.length - 1);
    stepped = { at: performance.now(), index: Math.max(k, -1) };
    if (k < 0) return glide(0);
    jump(heads[k]);
  }

  function jump(h) {
    history.replaceState(null, '', `#${h.id}`);
    glide(pageY(h) - 12);
    setActive(list.children[heads.indexOf(h)]);
  }

  // Hover intent: a pointer merely passing by doesn't pop the card.
  let openTimer = 0;
  toc.addEventListener('pointerenter', () => {
    toc.classList.remove('pointer-away');
    clearTimeout(openTimer);
    openTimer = setTimeout(() => toc.classList.add('open'), 120);
  });
  toc.addEventListener('focusin', () => toc.classList.remove('pointer-away'));
  toc.addEventListener('pointerleave', () => {
    clearTimeout(openTimer);
    toc.classList.add('pointer-away');
    toc.classList.remove('open');
  });

  // The whole rail is the drag handle; a sub-5px press stays a link click.
  // When it shares the button's corner it parks past the button (CSS).
  const wasDrag = cornerDrag(toc, toc, 'toc', { offset: (corner) => (corner === pref('fab') ? 52 : 0) });
  toc.addEventListener('dragstart', (ev) => ev.preventDefault()); // links native-drag by default
  list.addEventListener('click', (ev) => {
    const a = ev.target.closest('a');
    if (!a) return;
    ev.preventDefault();
    if (wasDrag()) return; // the click that ends a drag isn't a jump
    const h = heads[[...list.children].indexOf(a)];
    if (h) jump(h);
  });

  let raf = 0;
  addEventListener(
    'scroll',
    () => {
      raf ||= requestAnimationFrame(() => {
        raf = 0;
        spy();
      });
    },
    { passive: true },
  );
  onPref('outline', paint);

  return {
    /** After every render: pick up heading changes (rebuilding only if any). */
    refresh() {
      heads = [...article.querySelectorAll('h1[id],h2[id],h3[id],h4[id],h5[id],h6[id]')];
      const sig = heads.map((h) => `${h.tagName}#${h.id}\u0000${h.textContent}`).join('\u0001');
      if (sig !== signature) {
        signature = sig;
        rebuild();
      }
      paint();
    },
    /** Follow mode: light the heading enclosing the cursor line. */
    activeByLine(line) {
      if (heads.length === 0) return;
      const i = bisect(heads, line, (h) => +h.dataset.sourceLine);
      setActive(list.children[Math.max(i, 0)]);
    },
    step,
  };
}
