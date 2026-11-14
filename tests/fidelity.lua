-- Browser-level fidelity test: renders a live preview in headless Chromium
-- and asserts the DOM matches GitHub's markup conventions.
--
--   nvim --clean --headless -l tests/fidelity.lua
--
-- Requires curl and chromium (or set MDPV_CHROME).

local script = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(script, ':p')))
vim.opt.runtimepath:prepend(root)

-- Page preferences persist to stdpath('state'); point that at a throwaway
-- directory so the user's real prefs can't steer the DOM checks below.
vim.env.XDG_STATE_HOME = vim.fn.tempname()

local chrome = os.getenv('MDPV_CHROME') or 'chromium'
if vim.fn.executable(chrome) == 0 or vim.fn.executable('node') == 0 then
  print('SKIP: needs chromium (or MDPV_CHROME) and node')
  os.exit(0)
end

local failures, passes = {}, 0
local function check(name, cond)
  if cond then
    passes = passes + 1
    print('  ok  ' .. name)
  else
    failures[#failures + 1] = name
    print('FAIL  ' .. name)
  end
end

require('mdpv').setup({ open_browser = false })
vim.cmd.edit(root .. '/tests/fixtures/sample.md')
local url = assert(require('mdpv').open(0), 'preview failed to open')
local token = url:match('/p/(%x+)$')

-- The DOM once lazy typesetting has settled, via the DevTools driver. Run
-- async + vim.wait: SystemObj:wait() starves the vim.schedule hops the
-- server needs for buffer access.
local function dump(page)
  local done, res
  vim.system({ 'node', root .. '/tests/cdp.js', 'dump', page }, { text = true }, function(r)
    res, done = r, true
  end)
  vim.wait(35000, function()
    return done == true
  end, 10)
  return res and res.stdout or '', res and res.stderr or 'driver timed out'
end

local dom, err = dump(url)
check('chromium rendered the page', #dom > 1000)
if #dom <= 1000 then
  print(err)
end

-- Assert against the rendered article only: the raw markdown source is also
-- present in the page (boot JSON data block) and would confuse the checks.
local content = dom:match('<article id="content".-</article>') or ''
check('content region rendered', #content > 1000)

-- GitHub alert markup
check('alert div markup', content:find('class="markdown%-alert markdown%-alert%-note"') ~= nil)
check(
  'alert title with octicon',
  content:find('markdown%-alert%-title"><svg class="octicon octicon%-info mr%-2"') ~= nil
)
check('warning alert variant', content:find('class="markdown-alert markdown-alert-warning"', 1, true) ~= nil)
check('plain blockquote untouched', content:find('<blockquote[^>]*>%s*<p[^>]*>Regular blockquote') ~= nil)

-- Obsidian callouts (superset of GitHub alerts: more types, custom titles,
-- folding, nesting)
check('obsidian callout type', content:find('class="markdown-alert markdown-alert-success"', 1, true) ~= nil)
check(
  'custom title keeps inline markup',
  content:find('octicon%-check%-circle.-<span>All <strong>checks</strong> passed</span>') ~= nil
)
check('default title from type', content:find('octicon%-zap.-</svg>Danger</p>') ~= nil)
check(
  'alias resolves (faq -> question)',
  content:find('<details class="markdown%-alert markdown%-alert%-question"') ~= nil
)
check(
  '[!type]- folds closed',
  content:match('<details class="markdown%-alert markdown%-alert%-question"[^>]*') ~= nil
    and content:match('<details class="markdown%-alert markdown%-alert%-question"[^>]*'):find('open') == nil
)
check('[!type]+ folds open', content:find('<details class="markdown%-alert markdown%-alert%-tip"[^>]*open') ~= nil)
check(
  'summary title with fold chevron',
  content:find('<summary class="markdown%-alert%-title">.-octicon%-chevron%-down.-</summary>') ~= nil
)
check(
  'callouts nest',
  content:find('Can callouts nest%?</span>.-<div class="markdown%-alert markdown%-alert%-todo"') ~= nil
)
check('unknown type stays a blockquote', content:find('<blockquote[^>]*>%s*<p[^>]*>%[!unknown%]') ~= nil)

-- Task lists (GitHub classes come from markdown-it-task-lists). Live previews
-- render the checkboxes enabled — clicking one toggles the buffer line.
check('task list ul class', content:find('contains-task-list', 1, true) ~= nil)
check('task list item class', content:find('task-list-item', 1, true) ~= nil)
local checkbox = content:match('<input[^>]*task%-list%-item%-checkbox[^>]*>')
check('live checkbox is enabled (clickable)', checkbox ~= nil and checkbox:find('disabled') == nil)
check('checked state rendered', content:find('<input[^>]*checked[^>]*>') ~= nil)

-- Wikilinks (Obsidian style, resolved through the /f/ file route)
check('wikilink resolves to page.md', content:find('<a href="/f/' .. token .. '/second.md">second</a>', 1, true) ~= nil)
check('wikilink alias text', content:find('<a href="/f/' .. token .. '/second.md">the second page</a>', 1, true) ~= nil)
check('same-page heading wikilink', content:find('<a href="#wikilinks">#wikilinks</a>', 1, true) ~= nil)
check(
  'cross-page heading wikilink',
  content:find('<a href="/f/' .. token .. '/second.md#top">jump</a>', 1, true) ~= nil
)
check('image embed wikilink', content:find('<img src="/f/' .. token .. '/img.png" alt="img.png"', 1, true) ~= nil)

-- Obsidian syntax
check('==highlight== marked', content:find('<mark>highlighted</mark>', 1, true) ~= nil)
check(
  '%%comments%% hidden, inline and block',
  content:find('inline comment', 1, true) == nil
    and content:find('Block comment', 1, true) == nil
    and content:find('blank lines', 1, true) == nil
    and content:find('%%', 1, true) == nil
)
check('nested #tag', content:find('<span class="mdpv-tag">#project/mdpv</span>', 1, true) ~= nil)
check('plain #tag', content:find('<span class="mdpv-tag">#todo</span>', 1, true) ~= nil)
check('numeric and mid-word # stay text', content:find('#1984 and C#sharp stay text', 1, true) ~= nil)
check(
  'trailing block ID names the paragraph, hidden',
  content:find('<p id="^para%-id"[^>]*>A paragraph with a block ID%.</p>') ~= nil
)
check('block ID on a tight list item', content:find('<li id="^item%-id"[^>]*>tight item</li>') ~= nil)
check(
  'standalone block ID names the block before it',
  content:find('<table id="^table-id"', 1, true) ~= nil and content:find('^table-id</p>', 1, true) == nil
)
check('same-page block link', content:find('<a href="#^para-id">#^para-id</a>', 1, true) ~= nil)
check('cross-page block link', content:find('<a href="/f/' .. token .. '/second.md#^abc">there</a>', 1, true) ~= nil)
check(
  'markdown image size',
  content:find('<img src="/f/' .. token .. '/img.png" alt="sized" width="120">', 1, true) ~= nil
)
check(
  'embed image size',
  content:find('<img src="/f/' .. token .. '/img.png" alt="img.png" width="80" height="40">', 1, true) ~= nil
)
check('inline footnote', content:find('<li id="fn[^>]*>%s*<p[^>]*>Inline footnote text%.') ~= nil)

-- Heading anchors + GitHub slugs (incl. dedup)
check('heading id slug', content:find('id="sample%-document"') ~= nil)
check('anchor with octicon-link', content:find('class="anchor".-octicon%-link') ~= nil)
check(
  'duplicate slug deduped',
  content:find('id="duplicate%-heading"') ~= nil and content:find('id="duplicate%-heading%-1"') ~= nil
)

-- Footnotes (GitHub shape)
check(
  'footnotes section',
  content:find('data%-footnotes.-class="footnotes"') ~= nil or content:find('class="footnotes".-data%-footnotes') ~= nil
)
check('sr-only Footnotes label', content:find('class="sr%-only" id="footnote%-label">Footnotes') ~= nil)
check('backref GitHub class', content:find('data-footnote-backref', 1, true) ~= nil)
check('bare superscript ref (no brackets)', content:find('footnote%-ref"><a[^>]*>1</a>') ~= nil)

-- Syntax highlighting + GFM inline
check(
  'code highlighted with GitHub classes (starry-night)',
  content:find(
    '<span class="pl-k">local</span> <span class="pl-k">function</span> <span class="pl-en">greet</span>',
    1,
    true
  ) ~= nil
)
check(
  'string tokens nest GitHub-style',
  content:find(
    [[<span class="pl-s"><span class="pl-pds">'</span>hello %s<span class="pl-pds">'</span></span>]],
    1,
    true
  ) ~= nil
)
check('unknown fence language stays plain', content:find('language-text mdpv-hl">plain fenced block', 1, true) ~= nil)
check(
  'code blocks carry a copy button',
  content:find('<div class="mdpv%-pre"><pre>') ~= nil and content:find('class="mdpv%-copy"') ~= nil
)
check('strikethrough rendered', content:find('<s>strikethrough</s>', 1, true) ~= nil)
check('autolinked bare URL', content:find('<a href="https://example.com">https://example.com</a>', 1, true) ~= nil)
check(
  'table rendered',
  content:find('<table data%-source%-line="%d+">') ~= nil and content:find('<th>Feature</th>', 1, true) ~= nil
)
check('details/summary HTML preserved', content:find('<summary>Raw HTML details</summary>', 1, true) ~= nil)

-- Math (KaTeX, lazy-loaded)
check('inline math typeset', content:find('class="katex"', 1, true) ~= nil)
local katex_displays = select(2, content:gsub('class="katex%-display"', ''))
check('$$ block and ```math fence typeset as display math', katex_displays >= 2)
check('math placeholder gone after typeset', content:find('language-math', 1, true) == nil)
check('lone $ left alone', content:find('($5) untouched', 1, true) ~= nil)

-- Mermaid (lazy-loaded)
check(
  'mermaid block rendered to svg',
  content:find('class="mdpv%-mermaid mdpv%-typeset"') ~= nil and content:find('<svg', 1, true) ~= nil
)
check('mermaid node label present', content:find('Edit buffer', 1, true) ~= nil)
check('no mermaid parse error', content:find('mdpv-error', 1, true) == nil)
check('mermaid pan/zoom controls attached', content:find('mdpv%-diagram%-controls') ~= nil)

-- Emoji shortcodes
check('emoji shortcode expanded', content:find('\240\159\154\128', 1, true) ~= nil) -- 🚀

-- Frontmatter rendered as a table (GitHub file view)
check('frontmatter table with keys', content:find('<th>title</th>', 1, true) ~= nil)
check('frontmatter table marked as GitHub does', content:find('data-table-type="yaml-metadata"', 1, true) ~= nil)
check('frontmatter value cell', content:find('FRONTMATTER_TITLE_VALUE</td>', 1, true) ~= nil)
check('frontmatter list joined', content:find('alpha, beta', 1, true) ~= nil)
check('frontmatter nested map flattened', content:find('status: passing, ci: local', 1, true) ~= nil)
check('frontmatter not rendered as markdown', content:find('<p>title:', 1, true) == nil)

-- Outline: a dedicated floating overlay, built from the slugged headings
check(
  'outline items built from headings',
  -- the first item also carries the scroll-spy "active" class by default
  dom:find('<a href="#sample%-document" class="outline%-h1[ "]') ~= nil
    and dom:find('<a href="#code" class="outline%-h3[ "]') ~= nil
)
check('outline rail shown by default', dom:find('id="mdpv%-toc"[^>]*hidden') == nil)
check(
  'outline rows carry rail dashes + labels',
  dom:find('class="toc%-bar"') ~= nil and dom:find('class="toc%-text"') ~= nil
)
check(
  'outline switch offered in the menu, on',
  dom:find('data%-pref="outline"[^>]*aria%-checked="true"') ~= nil
    and dom:find('data%-pref="outline"[^>]*hidden') == nil
)

-- Menu: theme and style pickers are segmented controls
check(
  'theme and style pickers rendered',
  dom:find('data%-pref="theme"') ~= nil
    and dom:find('data%-value="dark"[^>]*aria%-checked="false"') ~= nil
    and dom:find('data%-pref="style"') ~= nil
    and dom:find('data%-value="github"[^>]*aria%-checked="true"') ~= nil
)
check('Obsidian style sheet linked', dom:find('href="/assets/%d+/obsidian%.css"') ~= nil)

-- Page preferences arrive as <html> attributes (defaults here: fresh state dir)
check(
  'prefs rendered onto <html>',
  dom:find('<html[^>]* data%-theme="auto"') ~= nil
    and dom:find('<html[^>]* data%-style="github"') ~= nil
    and dom:find('<html[^>]* data%-outline="1"') ~= nil
    and dom:find('<html[^>]* data%-fab="br"') ~= nil
)
check(
  'menu and shortcut card are popovers',
  dom:find('id="fab%-menu" popover') ~= nil and dom:find('id="mdpv%-keys" popover') ~= nil
)
check('assets load from a versioned path', dom:find('src="/assets/%d+/js/main%.js"') ~= nil)

-- Scroll sync + diffing plumbing
check('blocks carry data-source-line', content:find('data-source-line="', 1, true) ~= nil)
check('sync toggles shown on a live preview', dom:find('id="sync%-group"[^>]*hidden') == nil)
check('follow switch on', dom:find('data%-pref="follow"[^>]*aria%-checked="true"') ~= nil)
check(
  'move-cursor-on-scroll switch off under scroll_sync = true',
  dom:find('data%-pref="syncback"[^>]*aria%-checked="false"') ~= nil
)
check('typeset nodes keyed by source (morphdom)', content:find('data-mdpv-src="', 1, true) ~= nil)
check('morphdom loaded', dom:find('vendor/morphdom%-umd%.min%.js') ~= nil)

-- Local file routing + hygiene
check('relative image routed via /f/<token>/', content:find('src="/f/' .. token .. '/img.png"', 1, true) ~= nil)
check(
  'script tag sanitized out',
  content:find('<script', 1, true) == nil and content:find('document.body.innerHTML', 1, true) == nil
)
check('live status shown', dom:find('<html[^>]* data%-status="live"') ~= nil)
check('raw HTML still sanitized (an onerror handler never survives)', content:find('onerror', 1, true) == nil)

-- A document without raw HTML skips the sanitizer: markdown-it's own output
-- must still keep script URLs out, wikilinks included.
vim.cmd.edit(root .. '/tests/fixtures/plain.md')
local plain_url = assert(require('mdpv').open(0), 'plain preview failed to open')
local plain_token = plain_url:match('/p/(%x+)$')
local plain = (dump(plain_url):match('<article id="content".-</article>')) or ''
check('plain document rendered', plain:find('<h1', 1, true) ~= nil)
check('no javascript: URL survives the unsanitized path', plain:find('href="javascript:', 1, true) == nil)
check('unsafe wikilink left as text', plain:find('[[javascript:alert(1)]]', 1, true) ~= nil)
check(
  'safe wikilink still resolves',
  plain:find('<a href="/f/' .. plain_token .. '/second.md">second</a>', 1, true) ~= nil
)

require('mdpv').stop()

print(('\n%d passed, %d failed'):format(passes, #failures))
if #failures > 0 then
  print('failed: ' .. table.concat(failures, ', '))
  os.exit(1)
end
