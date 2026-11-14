// Markdown -> GitHub-shaped DOM, diffed into the page.
//
// Syntax: GitHub's (GFM, alerts, math, footnotes, emoji) plus Obsidian's
// (callouts, wikilinks, embeds, ==highlights==, %%comments%%, #tags, block
// IDs, image sizes, inline footnotes), all at once.
//
// Pipeline: markdown-it (CommonMark + GFM plugins) -> DOMPurify (only when
// the source carries raw HTML) -> DOM passes that reshape the output into the
// markup GitHub emits (alerts/callouts, heading anchors, footnotes), so
// github-markdown-css styles it 1:1 -> morphdom into the live article.

import { highlightCode } from './highlight.js';
import { OCTICON } from './icons.js';

// --- markdown-it plugins -----------------------------------------------------

// Math is parsed into inert placeholders (rules adapted from
// markdown-it-katex, MIT); KaTeX lazy-loads and typesets them after the
// diff. GitHub's delimiters: $…$, $$…$$, and ```math fences (fences are
// handled at the DOM stage).
function mathPlugin(md) {
  function validDelim(state, pos) {
    const prev = pos > 0 ? state.src.charCodeAt(pos - 1) : -1;
    const next = pos + 1 <= state.posMax ? state.src.charCodeAt(pos + 1) : -1;
    return {
      canOpen: next !== 0x20 && next !== 0x09,
      canClose: !(prev === 0x20 || prev === 0x09 || (next >= 0x30 && next <= 0x39)),
    };
  }

  function mathInline(state, silent) {
    if (state.src[state.pos] !== '$') return false;
    if (!validDelim(state, state.pos).canOpen) {
      if (!silent) state.pending += '$';
      state.pos += 1;
      return true;
    }
    const start = state.pos + 1;
    let match = start;
    while ((match = state.src.indexOf('$', match)) !== -1) {
      let pos = match - 1;
      while (state.src[pos] === '\\') pos -= 1;
      if ((match - pos) % 2 === 1) break; // unescaped $
      match += 1;
    }
    if (match === -1) {
      if (!silent) state.pending += '$';
      state.pos = start;
      return true;
    }
    if (match - start === 0) {
      if (!silent) state.pending += '$$';
      state.pos = start + 1;
      return true;
    }
    if (!validDelim(state, match).canClose) {
      if (!silent) state.pending += '$';
      state.pos = start;
      return true;
    }
    if (!silent) {
      const token = state.push('math_inline', 'math', 0);
      token.markup = '$';
      token.content = state.src.slice(start, match);
    }
    state.pos = match + 1;
    return true;
  }

  function mathBlock(state, start, end, silent) {
    let pos = state.bMarks[start] + state.tShift[start];
    let max = state.eMarks[start];
    if (pos + 2 > max || state.src.slice(pos, pos + 2) !== '$$') return false;
    pos += 2;
    let firstLine = state.src.slice(pos, max);
    let lastLine = '';
    let found = false;
    let next = start;
    if (firstLine.trim().slice(-2) === '$$') {
      firstLine = firstLine.trim().slice(0, -2); // single-line $$…$$
      found = true;
    }
    while (!found) {
      next += 1;
      if (next >= end) break;
      pos = state.bMarks[next] + state.tShift[next];
      max = state.eMarks[next];
      if (pos < max && state.tShift[next] < state.blkIndent) break;
      if (state.src.slice(pos, max).trim().slice(-2) === '$$') {
        const lastPos = state.src.slice(0, max).lastIndexOf('$$');
        lastLine = state.src.slice(pos, lastPos);
        found = true;
      }
    }
    if (!found) return false; // unclosed $$: leave the text alone (GitHub does too)
    if (silent) return true;
    const token = state.push('math_block', 'math', 0);
    token.block = true;
    token.content =
      (firstLine.trim() ? firstLine + '\n' : '') +
      state.getLines(start + 1, next, state.tShift[start], true) +
      (lastLine.trim() ? lastLine : '');
    token.map = [start, next + 1];
    token.markup = '$$';
    state.line = next + 1;
    return true;
  }

  md.inline.ruler.after('escape', 'math_inline', mathInline);
  md.block.ruler.after('blockquote', 'math_block', mathBlock, {
    alt: ['paragraph', 'reference', 'blockquote', 'list'],
  });
  md.renderer.rules.math_inline = (tokens, i) =>
    `<span class="mdpv-math">${md.utils.escapeHtml(tokens[i].content)}</span>`;
  md.renderer.rules.math_block = (tokens, i, opts, env, self) =>
    `<div class="mdpv-math mdpv-math-display"${self.renderAttrs(tokens[i])}>${md.utils.escapeHtml(tokens[i].content)}</div>`;
}

// github-slugger-compatible ids (common cases).
const slug = (text) =>
  text
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\p{Emoji_Presentation} _-]/gu, '')
    .replace(/ /g, '-');

// Obsidian image size: `300` or `300x200` after a `|`.
const SIZE_RE = /^(\d+)(?:x(\d+))?$/;

function setSize(token, size) {
  token.attrSet('width', size[1]);
  if (size[2]) token.attrSet('height', size[2]);
}

// Obsidian wikilinks: [[Page]], [[Page|alias]], [[Page#Heading]],
// [[Page#^block-id]], and ![[img.png]] / ![[img.png|300]] embeds. A target
// without a known extension resolves to <page>.md, so vault-style links go
// through the /f/ route like any relative link. Hrefs pass markdown-it's link
// validation like every other link.
const WIKI_EXT_RE = /\.(md|markdown|png|jpe?g|gif|svg|webp|avif|bmp|ico|pdf|txt|mp[34]|webm|ogg|wav|mov)$/i;
const WIKI_IMG_RE = /\.(png|jpe?g|gif|svg|webp|avif|bmp|ico)$/i;

function wikilinkPlugin(md) {
  md.inline.ruler.before('link', 'wikilink', (state, silent) => {
    const src = state.src;
    let pos = state.pos;
    const embed = src.charCodeAt(pos) === 0x21; /* ! */
    if (embed) pos += 1;
    if (src.charCodeAt(pos) !== 0x5b || src.charCodeAt(pos + 1) !== 0x5b /* [[ */) return false;
    const close = src.indexOf(']]', pos + 2);
    if (close === -1) return false;
    const inner = src.slice(pos + 2, close);
    if (!inner.trim() || /[[\]\n]/.test(inner)) return false;
    const bar = inner.indexOf('|');
    const target = (bar === -1 ? inner : inner.slice(0, bar)).trim();
    const alias = bar === -1 ? '' : inner.slice(bar + 1).trim();
    const hashAt = target.indexOf('#');
    const page = (hashAt === -1 ? target : target.slice(0, hashAt)).trim();
    const heading = hashAt === -1 ? '' : target.slice(hashAt + 1).trim();
    if (!page && !heading) return false;
    const block = /^\^[A-Za-z0-9-]+$/.test(heading);
    const hash = !heading ? '' : block ? `#${heading}` : `#${slug(heading)}`;
    const href = (page ? md.normalizeLink(WIKI_EXT_RE.test(page) ? page : `${page}.md`) : '') + hash;
    if (!md.validateLink(href)) return false;
    if (!silent) {
      if (embed && page && WIKI_IMG_RE.test(page)) {
        const size = SIZE_RE.exec(alias);
        const img = state.push('image', 'img', 0);
        img.attrs = [['src', href], ['alt', '']];
        if (size) setSize(img, size);
        const alt = new state.Token('text', '', 0);
        alt.content = (!size && alias) || page;
        img.children = [alt];
      } else {
        // Non-image embeds degrade to a plain link (no transclusion).
        const open = state.push('link_open', 'a', 1);
        open.attrs = [['href', href]];
        open.markup = 'wikilink';
        state.push('text', '', 0).content = alias || target;
        state.push('link_close', 'a', -1);
      }
    }
    state.pos = close + 2;
    return true;
  });
}

// Obsidian comments: %%inline%% and %%-delimited blocks render nothing.
function commentPlugin(md) {
  md.inline.ruler.before('emphasis', 'comment', (state) => {
    const pos = state.pos;
    if (state.src.charCodeAt(pos) !== 0x25 || state.src.charCodeAt(pos + 1) !== 0x25 /* %% */) return false;
    const close = state.src.indexOf('%%', pos + 2);
    if (close === -1) return false;
    state.pos = close + 2;
    return true;
  });

  // A block opens with %% at the start of a line and runs, blank lines
  // included, to a %% that ends a line.
  md.block.ruler.before(
    'fence',
    'comment',
    (state, start, end, silent) => {
      if (state.sCount[start] - state.blkIndent >= 4) return false;
      const open = state.bMarks[start] + state.tShift[start];
      if (state.src.charCodeAt(open) !== 0x25 || state.src.charCodeAt(open + 1) !== 0x25) return false;
      for (let line = start, from = open + 2; line < end; line += 1) {
        if (line > start) {
          if (!state.isEmpty(line) && state.sCount[line] < state.blkIndent) return false; // left the container
          from = state.bMarks[line] + state.tShift[line];
        }
        const close = state.src.indexOf('%%', from);
        if (close === -1) return false;
        const max = state.eMarks[line];
        if (close + 2 > max) continue;
        if (state.src.slice(close + 2, max).trim()) return false; // text after: inline comment
        if (!silent) state.line = line + 1;
        return true;
      }
      return false;
    },
    { alt: ['paragraph', 'reference', 'blockquote', 'list'] },
  );
}

// Obsidian tags: #tag, #nested/tag after whitespace or at the start of a
// block; at least one non-digit (#1984 stays text).
const TAG_RE = /#([\p{L}\p{N}_/-]+)/uy;

function tagPlugin(md) {
  md.inline.ruler.before('emphasis', 'tag', (state, silent) => {
    const pos = state.pos;
    if (state.src.charCodeAt(pos) !== 0x23 /* # */) return false;
    if (pos > 0 && !md.utils.isWhiteSpace(state.src.charCodeAt(pos - 1))) return false;
    TAG_RE.lastIndex = pos;
    const m = TAG_RE.exec(state.src);
    if (!m || /^\d+$/.test(m[1])) return false;
    if (!silent) {
      state.push('tag_open', 'span', 1).attrs = [['class', 'mdpv-tag']];
      state.push('text', '', 0).content = m[0];
      state.push('tag_close', 'span', -1);
    }
    state.pos += m[0].length;
    return true;
  });
}

// Obsidian image size in markdown images: ![alt|300](img.png).
function imageSizePlugin(md) {
  md.core.ruler.after('inline', 'image_size', (state) => {
    for (const block of state.tokens) {
      if (block.type !== 'inline') continue;
      for (const t of block.children) {
        const bar = t.type === 'image' ? t.content.lastIndexOf('|') : -1;
        const size = bar === -1 ? null : SIZE_RE.exec(t.content.slice(bar + 1).trim());
        if (!size) continue;
        setSize(t, size);
        const alt = new state.Token('text', '', 0);
        alt.content = t.content = t.content.slice(0, bar).trimEnd();
        t.children = [alt];
      }
    }
  });
}

// Obsidian block IDs. A trailing " ^id" names its paragraph (or tight list
// item); a "^id" paragraph of its own names the block before it. The marker
// is hidden; the block gets id="^id", the target of [[#^id]].
const BLOCK_ID_RE = /(?:^|[ \t])\^([A-Za-z0-9-]+)$/;

function blockIdPlugin(md) {
  // The open token of the block that ends at tokens[i] (or is tokens[i]).
  const blockOpen = (tokens, i) => {
    if (tokens[i].nesting === 0) return tokens[i];
    for (let j = i - 1; j >= 0; j -= 1) {
      if (tokens[j].nesting === 1 && tokens[j].level === tokens[i].level) return tokens[j];
    }
    return null;
  };

  md.core.ruler.after('inline', 'block_id', (state) => {
    const tokens = state.tokens;
    for (let i = 1; i < tokens.length; i += 1) {
      const t = tokens[i];
      const open = tokens[i - 1];
      if (t.type !== 'inline' || open.type !== 'paragraph_open' || !t.children.length) continue;
      const last = t.children[t.children.length - 1];
      const m = last.type === 'text' ? BLOCK_ID_RE.exec(last.content) : null;
      // Starts the text: only after a line break or as the whole paragraph.
      if (!m || (m[0][0] === '^' && t.children.length > 1 && t.children.at(-2).type !== 'softbreak')) continue;
      const id = `^${m[1]}`;

      // Standalone: names the previous sibling block, if there is one.
      if (t.children.length === 1 && m.index === 0) {
        const prev = i >= 2 && tokens[i - 2].nesting !== 1 ? blockOpen(tokens, i - 2) : null;
        if (!prev) continue;
        prev.attrSet('id', id);
        tokens.splice(i - 1, 3);
        i -= 2;
        continue;
      }

      // Trailing: names the paragraph, or the list item a tight list hides it in.
      last.content = last.content.slice(0, m.index);
      if (!last.content && t.children.at(-2)?.type === 'softbreak') t.children.splice(-2, 2);
      let target = open;
      if (open.hidden) {
        target = null;
        for (let j = i - 2; j >= 0 && !target; j -= 1) {
          if (tokens[j].nesting === 1 && tokens[j].level === open.level - 1) target = tokens[j];
        }
      }
      target?.attrSet('id', id);
    }
  });
}

// Every block element carries its markdown source line, so the page can
// scroll to the editor cursor and map clicks back to the source.
// env.lineOffset accounts for a frontmatter block removed before parsing.
function sourceLinePlugin(md) {
  md.core.ruler.push('mdpv_source_lines', (state) => {
    const offset = 1 + (state.env.lineOffset || 0);
    for (const t of state.tokens) {
      if (t.map && t.nesting !== -1) t.attrSet('data-source-line', String(t.map[0] + offset));
    }
  });
}

// --- Frontmatter -------------------------------------------------------------
// GitHub's file view renders YAML frontmatter as a table (keys as the header
// row). A minimal subset is parsed — flat `key: value` pairs, block/inline
// lists of scalars, one level of nested maps (joined as "sub: value, …");
// anything hairier strips the block, never renders it as markdown.

const FM_RE = /^---\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/;

function parseFrontmatter(src) {
  const m = src.startsWith('---') ? FM_RE.exec(src) : null;
  if (!m) return { body: src, offset: 0, pairs: null };
  const offset = m[0].split('\n').length - 1;
  const stripped = { body: src.slice(m[0].length), offset, pairs: null };
  const unquote = (v) => v.replace(/^(['"])(.*)\1$/, '$2');
  const pairs = [];
  let open = null; // key awaiting indented list items / nested map entries
  for (const raw of m[1].split(/\r?\n/)) {
    if (!raw.trim() || raw.trim().startsWith('#')) continue;
    if (/^\s/.test(raw) && open) {
      const item = /^\s+-\s*(.*)$/.exec(raw);
      const sub = /^\s+([\w][\w .-]*):\s*(.+)$/.exec(raw);
      let piece;
      if (item) piece = unquote(item[1].trim());
      else if (sub) piece = `${sub[1]}: ${unquote(sub[2].trim())}`;
      else return stripped; // deeper nesting than we render
      const p = pairs[pairs.length - 1];
      p[1] = p[1] ? `${p[1]}, ${piece}` : piece;
      continue;
    }
    const kv = /^([\w][\w .-]*):\s*(.*)$/.exec(raw);
    if (!kv) return stripped;
    let value = kv[2].trim();
    open = value === '' ? kv[1] : null;
    if (/^\[.*\]$/.test(value)) {
      value = value.slice(1, -1).split(',').map((s) => unquote(s.trim())).join(', ');
    }
    pairs.push([kv[1], unquote(value)]);
  }
  return { body: stripped.body, offset, pairs: pairs.length ? pairs : null };
}

function frontmatterTable(pairs) {
  const table = document.createElement('table');
  table.dataset.tableType = 'yaml-metadata'; // GitHub's marker for this table
  const head = table.createTHead().insertRow();
  const row = table.createTBody().insertRow();
  for (const [key, value] of pairs) {
    head.appendChild(document.createElement('th')).textContent = key;
    row.insertCell().textContent = value;
  }
  return table;
}

// --- GitHub-shaped DOM passes ------------------------------------------------

function addHeadingAnchors(root) {
  const seen = Object.create(null);
  for (const h of root.querySelectorAll('h1,h2,h3,h4,h5,h6')) {
    let id = slug(h.textContent || '');
    if (!id) continue;
    if (id in seen) id = `${id}-${++seen[id]}`;
    else seen[id] = 0;
    h.id = id;
    const a = document.createElement('a');
    a.className = 'anchor';
    a.href = `#${id}`;
    a.setAttribute('aria-hidden', 'true');
    a.tabIndex = -1;
    a.innerHTML = OCTICON.link;
    h.prepend(a);
  }
}

// > [!NOTE] blockquotes -> GitHub's <div class="markdown-alert ..."> markup.
// GitHub's five alerts render exactly as on GitHub; the rest of Obsidian's
// callout vocabulary rides on the same markup, as do Obsidian's extras on
// every type: a custom title, [!type]- / [!type]+ folding into <details>,
// and nesting. Where the vocabularies collide, GitHub wins.
const CALLOUT_ICON = {
  note: 'info',
  tip: 'lightBulb',
  important: 'report',
  warning: 'alert',
  caution: 'stop',
  abstract: 'note',
  info: 'info',
  todo: 'checklist',
  success: 'checkCircle',
  question: 'question',
  failure: 'xCircle',
  danger: 'zap',
  bug: 'bug',
  example: 'listUnordered',
  quote: 'quote',
};
const CALLOUT_ALIAS = {
  summary: 'abstract',
  tldr: 'abstract',
  hint: 'tip',
  check: 'success',
  done: 'success',
  help: 'question',
  faq: 'question',
  attention: 'warning',
  fail: 'failure',
  missing: 'failure',
  error: 'danger',
  cite: 'quote',
};
const CALLOUT_RE = /^\[!([A-Za-z]+)\]([-+]?)(?:[ \t]+|(?=\r?\n|$))/;

// Detach the rest of the marker line — the custom title, which may hold
// inline markup. The line ends at a softbreak "\n" in a text node or a <br>.
function detachTitleLine(p) {
  const frag = document.createDocumentFragment();
  while (p.firstChild) {
    const node = p.firstChild;
    if (node.nodeType === Node.TEXT_NODE) {
      const cut = node.nodeValue.search(/\r?\n/);
      if (cut !== -1) {
        frag.appendChild(document.createTextNode(node.nodeValue.slice(0, cut)));
        node.nodeValue = node.nodeValue.slice(cut).replace(/^\r?\n/, '');
        break;
      }
    } else if (node.nodeName === 'BR') {
      node.remove();
      break;
    }
    frag.appendChild(node);
  }
  return frag;
}

function transformCallouts(root) {
  for (const bq of root.querySelectorAll('blockquote')) {
    const first = bq.firstElementChild;
    const text = first?.tagName === 'P' ? first.firstChild : null;
    const m = text?.nodeType === Node.TEXT_NODE ? CALLOUT_RE.exec(text.nodeValue) : null;
    if (!m) continue;
    const raw = m[1].toLowerCase();
    const kind = CALLOUT_ICON[raw] ? raw : CALLOUT_ALIAS[raw];
    if (!kind) continue; // unknown type: stays a blockquote, like on GitHub

    text.nodeValue = text.nodeValue.slice(m[0].length);
    const custom = detachTitleLine(first);
    if (!first.textContent.trim() && first.children.length === 0) first.remove();
    // What's left of the paragraph starts on the line after the marker.
    else if (first.dataset.sourceLine) first.dataset.sourceLine = String(+first.dataset.sourceLine + 1);

    const fold = m[2];
    const box = document.createElement(fold ? 'details' : 'div');
    box.className = `markdown-alert markdown-alert-${kind}`;
    const line = bq.getAttribute('data-source-line');
    if (line) box.setAttribute('data-source-line', line);
    if (bq.id) box.id = bq.id; // block ID
    if (fold === '+') box.open = true;

    const title = document.createElement(fold ? 'summary' : 'p');
    title.className = 'markdown-alert-title';
    title.innerHTML = OCTICON[CALLOUT_ICON[kind]];
    if (custom.textContent.trim()) {
      // One <span> flex item keeps the spaces between inline elements.
      title.appendChild(document.createElement('span')).appendChild(custom);
    } else {
      title.append(m[1].charAt(0).toUpperCase() + m[1].slice(1).toLowerCase());
    }
    if (fold) title.insertAdjacentHTML('beforeend', OCTICON.chevronDown);

    box.appendChild(title);
    box.append(...bq.childNodes);
    bq.replaceWith(box);
  }
}

// markdown-it-footnote -> GitHub's footnote markup: <section data-footnotes>
// with an sr-only heading, bare superscript numbers, "↩" backrefs.
function polishFootnotes(root) {
  const section = root.querySelector('section.footnotes');
  if (!section) return;
  section.setAttribute('data-footnotes', '');
  root.querySelector('hr.footnotes-sep')?.remove(); // .footnotes has a border-top
  const label = document.createElement('h2');
  label.className = 'sr-only';
  label.id = 'footnote-label';
  label.textContent = 'Footnotes';
  section.prepend(label);
  for (const ref of root.querySelectorAll('sup.footnote-ref > a')) {
    ref.textContent = ref.textContent.replace(/^\[(.+)\]$/, '$1'); // [1] -> 1
    ref.setAttribute('data-footnote-ref', '');
    ref.setAttribute('aria-describedby', 'footnote-label');
  }
  for (const back of root.querySelectorAll('a.footnote-backref')) {
    back.classList.add('data-footnote-backref');
    back.textContent = '↩';
  }
}

// GitHub-style hover copy button on code blocks. Added to the detached copy,
// so both sides of the diff carry the wrapper and morphdom leaves it alone.
function addCopyButtons(root) {
  for (const pre of root.querySelectorAll('pre')) {
    if (!pre.querySelector(':scope > code')) continue;
    const wrap = document.createElement('div');
    wrap.className = 'mdpv-pre';
    pre.replaceWith(wrap);
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'mdpv-copy';
    btn.title = 'Copy';
    btn.setAttribute('aria-label', 'Copy code');
    btn.innerHTML = OCTICON.copy;
    wrap.append(pre, btn);
  }
}

// Relative resources resolve against the file's directory through the /f/
// route, like on GitHub. `bust` (set after the follower switched buffers)
// keeps a same-named image from another directory out of the image cache.
const ABSOLUTE_RE = /^(?:[a-z][a-z0-9+.-]*:|\/\/|#|\/)/i;

function rewriteRelativeUrls(root, base, bust) {
  const rewrite = (el, attr, busted) => {
    const v = el.getAttribute(attr);
    if (!v || ABSOLUTE_RE.test(v)) return;
    const q = busted && bust ? `${v.includes('?') ? '&' : '?'}b=${bust}` : '';
    el.setAttribute(attr, `${base}/${v}${q}`);
  };
  for (const el of root.querySelectorAll('img[src], video[src], audio[src], source[src]')) rewrite(el, 'src', true);
  for (const el of root.querySelectorAll('a[href]')) rewrite(el, 'href', false);
}

// Typeset targets become placeholder <div>/<span>s carrying their source in
// data-mdpv-src *before* the diff, so a typeset node and its regenerated
// placeholder share a tag, pair up in morphdom, and skip re-typesetting when
// the source didn't change.
function normalizeTypeset(root, features) {
  const swap = (code, cls) => {
    const div = document.createElement('div');
    div.className = cls;
    div.textContent = code.textContent;
    const line = code.getAttribute('data-source-line');
    if (line) div.setAttribute('data-source-line', line);
    code.parentElement.replaceWith(div);
  };
  if (features.math !== false) {
    for (const code of root.querySelectorAll('pre > code.language-math')) swap(code, 'mdpv-math mdpv-math-display');
  }
  if (features.mermaid !== false) {
    for (const code of root.querySelectorAll('pre > code.language-mermaid')) swap(code, 'mdpv-mermaid');
  }
  for (const el of root.querySelectorAll('.mdpv-math, .mdpv-mermaid')) el.dataset.mdpvSrc = el.textContent;
}

// --- Renderer ----------------------------------------------------------------

// Raw HTML can only enter through `<` followed by a tag name, `/`, `!`, or
// `?` in the source (markdown-it's html_block/html_inline). Without it the
// output is markdown-it's own escaped markup with validated links — safe by
// construction, the html: false guarantee — so the sanitizer, the costliest
// step, is skipped. Autolinks and code mentioning tags just take the
// sanitizing path. The page CSP stays the backstop either way.
const RAW_HTML_RE = /<[A-Za-z!?/]/;
const PURIFY = {
  FORBID_TAGS: ['style'], // GitHub strips <style> from markdown too
  USE_PROFILES: { html: true, svg: true, svgFilters: true },
};

// morphdom hook: keep nodes whose rendering is expensive or reader-owned.
function onBeforeElUpdated(from, to) {
  const keepLine = () => {
    const line = to.getAttribute('data-source-line');
    if (line) from.setAttribute('data-source-line', line);
    return false;
  };
  // Typeset math/diagram with the same source: keep it, refresh its line.
  if (from.classList.contains('mdpv-typeset') && from.dataset.mdpvSrc === to.dataset.mdpvSrc) return keepLine();
  if (from.tagName === 'DETAILS' && from.open !== to.open) to.open = from.open; // reader-toggled
  return !from.isEqualNode(to);
}

/**
 * Build a renderer for `article`. features: the editor's feature flags;
 * tasks: render task checkboxes clickable (live previews).
 * render(src, {base, bust, readonly}) diffs the new rendering into the page.
 */
export function createRenderer(article, features, { tasks }) {
  const md = window
    .markdownit({ html: true, linkify: true, typographer: false })
    .use(window.markdownitTaskLists, { enabled: tasks })
    .use(window.markdownitFootnote)
    .use(window.markdownitMark)
    .use(wikilinkPlugin)
    .use(commentPlugin)
    .use(tagPlugin)
    .use(imageSizePlugin)
    .use(blockIdPlugin);
  if (features.emoji !== false && window.markdownitEmoji) md.use(window.markdownitEmoji);
  if (features.math !== false) md.use(mathPlugin);
  md.use(sourceLinePlugin);

  return function render(src, { base, bust = 0, readonly = false }) {
    const fm = parseFrontmatter(src);
    let html = md.render(fm.body, { lineOffset: fm.offset });
    if (RAW_HTML_RE.test(fm.body)) html = window.DOMPurify.sanitize(html, PURIFY);

    // Post-process a detached copy, then diff it into the live article:
    // untouched subtrees keep their nodes, so images don't reload, open
    // <details> stay open, and typeset math/diagrams/code survive.
    const next = article.cloneNode(false);
    next.innerHTML = html;
    if (fm.pairs) next.prepend(frontmatterTable(fm.pairs));
    transformCallouts(next);
    addHeadingAnchors(next);
    polishFootnotes(next);
    rewriteRelativeUrls(next, base, bust);
    normalizeTypeset(next, features);
    highlightCode(next, { render: true });
    addCopyButtons(next);
    if (readonly) {
      // An attribute (not just the property), so the diff carries it.
      for (const box of next.querySelectorAll('input.task-list-item-checkbox')) box.setAttribute('disabled', '');
    }
    window.morphdom(article, next, { onBeforeElUpdated });
  };
}
