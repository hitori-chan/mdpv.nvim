# Development

## Layout

```
plugin/mdpv.lua        :Preview command, server stop on exit
lua/mdpv/init.lua      public API, command dispatch
lua/mdpv/config.lua    defaults, validation, feature flags
lua/mdpv/preview.lua   previews: buffer binding, cursor sync, page messages, follower
lua/mdpv/server.lua    routes and lifecycle
lua/mdpv/http.lua      HTTP/1.1 listener, limits, response helpers
lua/mdpv/sse.lua       per-tab event streams
lua/mdpv/prefs.lua     page preferences (state file)
lua/mdpv/files.lua     file serving: streaming, ranges, 304
lua/mdpv/watch.lua     fs watchers for image reload
lua/mdpv/health.lua    :checkhealth mdpv
assets/index.html      page shell template
assets/js/             ES modules: main, render, highlight, typeset, sync, outline, ui, util, icons
assets/mdpv.css        page chrome, extra callout kinds, tags
assets/obsidian.css    Obsidian style
assets/vendor/         pinned third-party code
scripts/               check.sh (lint gate), vendor.sh, theme.lua, grammars.mjs
tests/                 suites, cdp.js (DevTools driver), fixtures
```

## How it works

1. `nvim_buf_attach` re-arms a debounce timer on every change.
2. When it fires and a tab is attached, the buffer is JSON-encoded once per
   revision and pushed over SSE.
3. The page renders: markdown-it with GitHub and Obsidian rules → DOMPurify
   (only if the source has raw HTML) → passes that reshape the output into
   GitHub's markup and highlight code → morphdom. KaTeX and Mermaid typeset
   after the diff. Hidden tabs render when shown.

Neovim never parses markdown. Socket callbacks run in libuv's fast context;
anything touching editor state goes through `vim.schedule`.

### Routes

| Route | Purpose |
| --- | --- |
| `GET /p/<token>` | page shell: buffer embedded, prefs as `<html data-*>` |
| `GET /events/<token>` | SSE: `update`, `scroll`, `assets`, `prefs`, `config`, `close` |
| `GET /f/<token>/<path>` | files next to the buffer; `.md` renders as a static page, `?raw` serves it |
| `POST /sync/<token>` | `{line}` cursor, `{line, jump}` jump to source, `{toggle}` checkbox |
| `POST /prefs/<token>` | preference changes: saved, echoed to every tab |
| `GET /assets/<v>/<path>` | frontend, immutable; `<v>` derives from file sizes and mtimes |
| `GET /assets/<path>` | same files, revalidated (status page) |
| `GET /` | status page, no tokens |

## Decisions

- **Pure `vim.uv`, SSE, not WebSocket.** No external runtime. Updates flow
  editor → browser; the few reverse messages are POSTs.
- **One syntax.** GitHub's plus Obsidian's, always on; no flavors or
  vault detection. Obsidian syntax only claims text GitHub shows literally.
- **Render in the browser.** markdown-it with GFM plugins is close to
  cmark-gfm; fidelity comes from emitting GitHub's exact markup for its CSS.
- **Sanitize only when needed.** Raw HTML needs `<[A-Za-z!?/]` in the
  source; without it, markdown-it's output is safe (links, wikilinks
  included, are validated). CSP `script-src 'self'` is the backstop.
- **Tokens, not servers.** One lazy server; each preview is a 128-bit token
  on it. Ephemeral port by default.
- **Binding epochs.** Rebinding a preview bumps an epoch, so stale
  `buf_attach` callbacks detach themselves. The follower rebinds on
  `BufEnter`/`FileType`; the epoch also busts cached image URLs.
- **Editor-owned preferences.** Ephemeral ports make localStorage useless.
  A state file is the source of truth: rendered onto `<html>` (no flash),
  re-read when it changes on disk, merged on write.
- **GitHub's highlighter.** starry-night: the Linguist grammars and `pl-*`
  classes GitHub uses, colored by github-markdown-css. `scripts/grammars.mjs`
  compiles the languages listed in `vendor.sh` (and what they embed) to JSON
  at vendor time. The engine (vscode-textmate, Oniguruma WASM: CSP
  `'wasm-unsafe-eval'`) warms up with the page; once a language is ready,
  code highlights in the render pass, cached by language and text, so edits
  never flash plain code.
- **Themes via `light-dark()`.** `scripts/theme.lua` folds github-markdown-css's
  light and dark builds into one sheet; a theme switch sets one attribute.
- **Styles are CSS only.** `obsidian.css`, scoped to
  `:root[data-style='obsidian']`, remaps github-markdown variables (code
  colors included) and the chrome tokens; markup never changes. Values and variable
  names come from Obsidian's default theme (`publish.obsidian.md/app.css`).
- **Path-versioned assets.** Relative imports, lazy vendor scripts, and
  KaTeX fonts inherit the version.
- **Bounded.** 16 KiB headers, 4 KiB bodies, 3 s request timeout, 256
  connections; 32 watched dirs and 512 files per preview.
- **SSE queue.** At most one pending frame per event per tab: a newer
  `update`/`scroll` replaces the older, `assets`/`prefs` merge. A write
  still in flight at two consecutive heartbeats (30 s apart) drops the tab.
  Closing a preview queues the final `close` frame behind any write in
  flight; a tab that hasn't taken it after 5 s is dropped. Stopping the
  server shuts connections down and cuts them after 1 s.
- **Confined files.** `/f/` rejects `..`, absolute paths, and symlinks that
  leave the buffer's directory. HTML downloads; raw files get restrictive
  headers.

## Tests

```sh
./scripts/check.sh                              # stylua, node --check, lua-language-server
nvim --clean --headless -l tests/e2e.lua        # server, protocol, lifecycle, SSE queue (curl)
nvim --clean --headless -l tests/fidelity.lua   # rendered DOM: GitHub markup, Obsidian syntax
nvim --clean --headless -l tests/sync.lua       # scroll sync both ways
nvim --clean --headless -l tests/interact.lua   # checkbox clicks, jump, keys, code edits, follow_buffer
```

- Browser suites drive Chromium (or `$MDPV_CHROME`) through `tests/cdp.js`
  and need Node 22+; they skip when missing. Fidelity reads the DOM once
  typesetting has settled.
- Tests point `XDG_STATE_HOME` at a temp dir; real prefs are untouched.
- `check.sh` writes `$VIMRUNTIME` into a temporary `.luarc.json`; the
  headless language server doesn't expand it.
- Test browsers run with `--no-sandbox`: CI runners (Ubuntu 24.04+) block
  Chrome's sandbox.
- CI runs all of the above.

## Frontend

Plain ES modules, no build step, hand-formatted. Asset versions are computed
when the server starts: run `:Preview stop` after editing assets.

## Vendored assets

```sh
./scripts/vendor.sh   # re-download pinned versions, fold the theme, compile grammars (needs nvim, node)
```

Pins and the highlighted languages live in `scripts/vendor.sh`; versions are
recorded in `assets/vendor/VERSIONS.txt`.

## Releases

Semver tags on `main`: breaking → major (minor while `0.x`), feature →
minor, fix → patch.

```sh
git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z
gh release create vX.Y.Z --generate-notes
```

## Future work

- `:Preview export` to a self-contained HTML file.
- Optional MathJax backend.
- Incremental rendering for very large documents.
