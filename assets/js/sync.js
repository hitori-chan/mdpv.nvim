// Scroll sync and jump-to-source.
//
// Every block carries data-source-line. Editor -> page ("Follow cursor"):
// the editor streams its cursor line; the page scrolls there, interpolating
// between the two surrounding mapped blocks so long paragraphs and code
// track smoothly, marks the block, and parks the URL hash on a heading.
// Page -> editor ("Move cursor on scroll"): reader scrolls POST the line
// under the viewport anchor. Double-clicking a block jumps the editor there.
// Echo control: the page ignores its own glides (gliding()), and the editor
// does not re-broadcast a cursor line it just applied.

import { ANCHOR, bisect, flag, gliding, glide, onPref, pageY, post } from './util.js';

const lineOf = (el) => +el.dataset.sourceLine;

// Whitespace markdown-it puts between child blocks (table cells, list
// items, quoted paragraphs): not source lines.
const CONTAINERS = new Set(['TABLE', 'THEAD', 'TBODY', 'TFOOT', 'TR', 'UL', 'OL', 'DL', 'BLOCKQUOTE', 'DIV', 'DETAILS', 'SECTION']);

/** Source line breaks between the start of `block` and the caret. */
function breaksBefore(block, caret) {
  const range = document.createRange();
  range.setStart(block, 0);
  range.setEnd(caret.node, caret.offset);
  const walker = document.createTreeWalker(range.commonAncestorContainer, NodeFilter.SHOW_TEXT);
  let n = 0;
  for (let node = walker.currentNode; node; node = walker.nextNode()) {
    if (node.nodeType !== Node.TEXT_NODE || !range.intersectsNode(node)) continue;
    if (CONTAINERS.has(node.parentElement?.tagName)) continue;
    if (node.parentElement?.closest('.katex')) continue; // typeset math: its TeX copy isn't layout
    const text = node === caret.node ? node.nodeValue.slice(0, caret.offset) : node.nodeValue;
    n += (text.match(/\n/g) || []).length;
  }
  return n;
}

/** Text position under the pointer, where the browser can tell. */
function caretAt(x, y) {
  if (document.caretPositionFromPoint) {
    const p = document.caretPositionFromPoint(x, y);
    return p && { node: p.offsetNode, offset: p.offset };
  }
  const r = document.caretRangeFromPoint?.(x, y);
  return r && { node: r.startContainer, offset: r.startOffset };
}

export function initSync(article, { live, scrollSync, outline }) {
  let blocks = []; // [data-source-line] in document order (non-decreasing lines and offsets)
  let cursorLine = 0;
  let cursorEl = null;
  let pending = 0; // a line that arrived while the tab was hidden
  let lastSent = 0;

  function blockAt(line) {
    const i = bisect(blocks, line, lineOf);
    let el = i === -1 ? null : blocks[i];
    // Fenced code maps its line on <code>; mark the block instead.
    if (el?.tagName === 'CODE' && el.parentElement?.tagName === 'PRE') el = el.parentElement;
    return el;
  }

  function paintCursor() {
    const el = cursorLine > 0 ? blockAt(cursorLine) : null;
    if (cursorEl && cursorEl !== el) cursorEl.classList.remove('mdpv-cursor');
    cursorEl = el;
    el?.classList.add('mdpv-cursor');
  }

  /** Document y where source `line` sits. */
  function yOf(line) {
    const i = bisect(blocks, line, lineOf);
    if (i === -1) return 0;
    const a = blocks[i];
    const b = blocks[i + 1];
    let y = pageY(a);
    const span = b ? lineOf(b) - lineOf(a) : 0;
    if (span > 0) y += (pageY(b) - y) * ((line - lineOf(a)) / span);
    return y;
  }

  /** Source line at document y (inverse of yOf). */
  function lineAt(y) {
    const i = bisect(blocks, y, pageY);
    if (i === -1) return 1;
    const a = blocks[i];
    const b = blocks[i + 1];
    if (!b) return lineOf(a);
    const ya = pageY(a);
    const yb = pageY(b);
    const span = lineOf(b) - lineOf(a);
    if (yb <= ya || span <= 0) return lineOf(a);
    return Math.max(1, Math.round(lineOf(a) + span * ((y - ya) / (yb - ya))));
  }

  // Deep-linkable position: a cursor on a heading line mirrors its slug into
  // the URL hash (replaceState: no scroll, no history entries).
  function hashFor(line) {
    const el = blockAt(line);
    if (el && /^H[1-6]$/.test(el.tagName) && el.id && lineOf(el) === line) {
      history.replaceState(null, '', `#${el.id}`);
    }
  }

  /** Editor cursor moved to `line`. */
  function follow(line) {
    if (!scrollSync || !flag('follow')) return;
    if (document.hidden) {
      pending = line; // nothing to see; apply when the tab shows again
      return;
    }
    lastSent = line; // don't POST straight back what we just applied
    cursorLine = line;
    glide(yOf(line) - innerHeight * ANCHOR);
    paintCursor();
    outline.activeByLine(line);
    hashFor(line);
  }

  if (live && scrollSync) {
    let timer = 0;
    addEventListener(
      'scroll',
      () => {
        if (!flag('syncback') || gliding()) return;
        clearTimeout(timer);
        timer = setTimeout(() => {
          if (gliding()) return;
          const line = lineAt(scrollY + innerHeight * ANCHOR);
          if (line !== lastSent) {
            lastSent = line;
            post('sync', { line });
          }
        }, 150);
      },
      { passive: true },
    );
    onPref('follow', (v) => {
      if (v !== '1') {
        cursorLine = 0;
        paintCursor();
      }
    });
  }

  /** Exact source line under the pointer: the innermost mapped block's
   *  line plus the line breaks between its start and the caret there
   *  (markdown-it keeps soft breaks, and code keeps its lines). */
  function lineAtPoint(ev) {
    const block = ev.target.closest?.('[data-source-line]');
    if (!block || !article.contains(block)) return lineAt(ev.pageY);
    let line = lineOf(block);
    const caret = caretAt(ev.clientX, ev.clientY);
    if (caret && block.contains(caret.node)) line += breaksBefore(block, caret);
    // Only fences map their line on <code> (indented code maps <pre>), and a
    // fence's text starts on the line after the opening fence.
    if (block.tagName === 'CODE') line += 1;
    return line;
  }

  if (live) {
    // Jump to source: double-click a block, the editor cursor lands on the
    // matching line (centered); the block flashes to confirm.
    article.addEventListener('dblclick', (ev) => {
      if (ev.target.closest('a, button, input, summary, .mdpv-mermaid')) return;
      const line = lineAtPoint(ev);
      lastSent = line;
      post('sync', { line, jump: true });
      const el = ev.target.closest('[data-source-line]') || blockAt(line);
      if (el) {
        el.classList.remove('mdpv-flash');
        void el.offsetWidth; // restart the animation
        el.classList.add('mdpv-flash');
        el.addEventListener('animationend', () => el.classList.remove('mdpv-flash'), { once: true });
      }
    });
  }

  return {
    /** After every render: re-index blocks, re-mark the cursor block. */
    refresh() {
      // Bisecting needs lines that never decrease in document order.
      // Footnotes break that (rendered last, mapped where they were
      // written): keep only blocks that don't step back.
      blocks = [];
      let max = 0;
      for (const el of article.querySelectorAll('[data-source-line]')) {
        const line = lineOf(el);
        if (line < max) continue;
        blocks.push(el);
        max = line;
      }
      paintCursor();
    },
    follow,
    /** The tab became visible: apply a cursor line that arrived meanwhile. */
    catchUp() {
      if (pending) {
        const line = pending;
        pending = 0;
        follow(line);
      }
    },
  };
}
