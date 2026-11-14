---@brief The preview server: routes and lifecycle on top of mdpv.http.
---
--- One server per Neovim instance, started lazily and bound to loopback.
--- Each preview registers an unguessable token that owns its private routes:
---   GET  /p/<token>          page shell with the buffer embedded (instant first paint)
---   GET  /events/<token>     SSE: update, scroll, assets, prefs, config, close
---   GET  /f/<token>/<path>   files relative to the buffer's directory (.md renders as a page)
---   POST /sync/<token>       browser -> editor: cursor line, jump to source, task checkbox
---   POST /prefs/<token>      browser -> editor: page preference changes
--- Shared routes:
---   GET  /                   status page (never exposes preview tokens)
---   GET  /assets/<v>/<path>  plugin frontend, immutable under a content version
---   GET  /assets/<path>      the same files, revalidated instead
---
--- Socket callbacks run in libuv's fast context: anything touching buffers,
--- options or files under stdpath() hops to the main loop via vim.schedule.

local uv = vim.uv
local http = require('mdpv.http')
local files = require('mdpv.files')
local sse = require('mdpv.sse')
local watch = require('mdpv.watch')
local prefs = require('mdpv.prefs')
local cfg = require('mdpv.config')

local respond, MIME = http.respond, http.MIME

local M = {}

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
local asset_dir = plugin_root .. '/assets'

local IMMUTABLE = 'public, max-age=31536000, immutable'
local HEARTBEAT_MS = 30000

local state = {
  listener = nil, ---@type mdpv.Listener?
  heartbeat = nil, ---@type uv.uv_timer_t?
  host = nil, ---@type string?
  port = nil, ---@type integer?
  requested_port = nil, ---@type integer?
  config = nil, ---@type mdpv.Config?
  template = nil, ---@type string? assets/index.html
  version = nil, ---@type string? asset URL version (digits)
  previews = {}, ---@type table<string, mdpv.Preview> token -> preview
}

------------------------------------------------------------------------------
-- Page shell
------------------------------------------------------------------------------

local CSP = table.concat({
  "default-src 'self'",
  "base-uri 'none'",
  "object-src 'none'",
  "frame-ancestors 'none'",
  "img-src 'self' data: https: http:",
  "media-src 'self' data: https: http:",
  "style-src 'self' 'unsafe-inline'",
  "script-src 'self' 'wasm-unsafe-eval'", -- starry-night's Oniguruma
  "connect-src 'self'",
}, '; ')

local function page_headers()
  return {
    ['Content-Type'] = MIME.html,
    ['Cache-Control'] = 'no-store',
    ['Content-Security-Policy'] = CSP,
    ['Referrer-Policy'] = 'no-referrer',
    ['X-Content-Type-Options'] = 'nosniff',
    ['X-Frame-Options'] = 'DENY',
  }
end

-- Page preferences rendered onto <html>, in this order.
local ROOT_ATTRS = { 'theme', 'style', 'wide', 'outline', 'follow', 'syncback', 'fab', 'toc' }

--- Fill the page template. Main loop only (preferences live under stdpath).
---@param title string
---@param boot_json string
local function page_shell(title, boot_json)
  local p = prefs.resolve(assert(state.config))
  local attrs = {}
  for _, key in ipairs(ROOT_ATTRS) do
    attrs[#attrs + 1] = ('data-%s="%s"'):format(key, http.html_escape(p[key]))
  end
  return (
    assert(state.template):gsub('{{([%u_]+)}}', {
      ROOT = table.concat(attrs, ' '),
      COLOR_SCHEME = p.theme == 'auto' and 'light dark' or p.theme,
      TITLE = http.html_escape(title),
      ASSETS = '/assets/' .. state.version,
      -- Boot data ships in a non-executable JSON block (inline scripts would
      -- violate the CSP). Escaping '<' prevents a '</script>' breakout and
      -- is transparent to JSON.parse.
      BOOT = (boot_json:gsub('<', '\\u003c')),
    })
  )
end

local CLOSED_PAGE = '<!DOCTYPE html><meta charset="utf-8"><title>mdpv</title>'
  .. '<meta name="color-scheme" content="light dark">'
  .. '<p style="font:16px/1.5 system-ui,sans-serif;margin:48px auto;max-width:36em;padding:0 16px">'
  .. 'This preview has been closed. Run <code>:Preview</code> in Neovim to open it again.</p>'

------------------------------------------------------------------------------
-- Routes
------------------------------------------------------------------------------

--- Drop a socket from every preview's stream set and close it.
local function prune(sock)
  for _, pv in pairs(state.previews) do
    pv.clients[sock] = nil
  end
  http.close_sock(sock)
end

local function route_index(sock, req)
  respond(
    sock,
    200,
    page_headers(),
    table.concat({
      '<!DOCTYPE html><html><head><meta charset="utf-8"><title>mdpv</title>',
      '<meta name="color-scheme" content="light dark">',
      '<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">',
      '</head><body style="font:16px/1.5 system-ui,sans-serif;margin:48px auto;max-width:36em;padding:0 16px">',
      '<h1 style="font-size:20px">mdpv server</h1>',
      '<p>Open a preview from Neovim with <code>:Preview</code> to receive its private URL.</p>',
      '</body></html>',
    }),
    req.head_only
  )
end

local function route_page(sock, req, token)
  -- The buffer is embedded for an instant first paint: main loop.
  vim.schedule(function()
    local pv = state.previews[token]
    local json = pv and pv:payload()
    if not (pv and json and state.listener) then
      return respond(sock, 404, page_headers(), CLOSED_PAGE, req.head_only)
    end
    respond(sock, 200, page_headers(), page_shell(pv.title, json), req.head_only)
  end)
end

--- A markdown file reached through /f/<token>/… renders as a one-shot page:
--- same shell and renderer, but no buffer behind it, so no SSE stream.
--- `base` points the page's relative URLs at the file's own directory.
local function route_static_md(sock, req, token, rel, path)
  files.read(path, function(data, err)
    if not data then
      return respond(sock, err == 'toobig' and 413 or 404, nil, nil, req.head_only)
    end
    vim.schedule(function()
      if not (state.previews[token] and state.listener) then
        return respond(sock, 404, nil, nil, req.head_only)
      end
      local dir = rel:match('^(.+)/[^/]+$')
      local title = rel:match('([^/]+)$') or rel
      local ok, json = pcall(vim.json.encode, {
        token = token,
        title = title,
        md = data,
        static = true,
        -- `rel` is decoded: re-encode, or a '#' or '?' in a directory name
        -- would cut the page's relative URLs short.
        base = '/f/' .. token .. (dir and ('/' .. dir:gsub('[^%w%-._~/]', function(c)
          return ('%%%02X'):format(c:byte())
        end)) or ''),
        features = cfg.features(assert(state.config)),
      })
      if not ok then
        return respond(sock, 500, nil, nil, req.head_only) -- e.g. not valid UTF-8
      end
      respond(sock, 200, page_headers(), page_shell(title, json), req.head_only)
    end)
  end)
end

local function route_events(sock, req, token)
  local pv = state.previews[token]
  if not pv then
    return respond(sock, 404, nil, nil, req.head_only)
  end
  if req.head_only then
    -- An event stream has no length: answer the head alone.
    return http.write_and_close(
      sock,
      http.head(200, { ['Content-Type'] = 'text/event-stream', ['Cache-Control'] = 'no-cache', Connection = 'close' })
    )
  end
  -- The page boots from embedded content and passes its revision; the
  -- first update is skipped when the buffer has not changed since.
  local since = http.query_param(req.query, 'since')
  local stream
  stream = sse.open(sock, prune, function()
    vim.schedule(function()
      if state.previews[token] ~= pv or pv.clients[sock] ~= stream then
        return
      end
      if since == nil or since ~= pv:revision() then
        local json = pv:payload()
        if json then
          stream:send('update', json)
        end
      end
    end)
  end)
  if not stream.dead then -- a head write that failed outright already pruned it
    pv.clients[sock] = stream
  end
  return function()
    prune(sock) -- tab closed: EOF
  end
end

--- Fire-and-forget JSON POSTs: always 204 (404 for unknown tokens); bad
--- payloads are ignored. Handling needs editor state: main loop.
local function json_post(handler)
  return function(sock, req, token)
    if not state.previews[token] then
      return respond(sock, 404)
    end
    local body = req.body or ''
    vim.schedule(function()
      local pv = state.previews[token]
      local ok, msg = pcall(vim.json.decode, body)
      if pv and ok and type(msg) == 'table' then
        handler(pv, msg)
      end
    end)
    respond(sock, 204)
  end
end

--- { line = N } scroll sync, { line = N, jump = true } jump to source,
--- { toggle = { line = N, checked = b } } task checkbox.
local route_sync = json_post(function(pv, msg)
  pv:message(msg)
end)

--- { key = value, … }: validated, persisted, and echoed to every open tab.
local route_prefs = json_post(function(_, msg)
  local changed = prefs.set(msg)
  if changed then
    M.broadcast_all('prefs', changed)
  end
end)

local function serve_asset(sock, req, rel, cache_control)
  rel = http.percent_decode(rel)
  if not http.is_confined(rel) then
    return respond(sock, 403, nil, nil, req.head_only)
  end
  files.resolve_confined(asset_dir, asset_dir .. '/' .. rel, function(real, err)
    if not real then
      return respond(sock, err == 'outside' and 403 or 404, nil, nil, req.head_only)
    end
    files.serve(sock, real, req, { cache_control = cache_control })
  end)
end

local function route_versioned_asset(sock, req, version, rel)
  -- A stale version still gets the file, just not cached as immutable.
  serve_asset(sock, req, rel, version == state.version and IMMUTABLE or nil)
end

local function route_asset(sock, req, rel)
  serve_asset(sock, req, rel, nil)
end

local function route_file(sock, req, token, rel)
  local pv = state.previews[token]
  if not pv then
    return respond(sock, 404, nil, nil, req.head_only)
  end
  rel = http.percent_decode(rel)
  -- Reject NUL, absolute paths, and any `..` segment; realpath confinement
  -- below also stops symlinks that leave the buffer's directory.
  if not http.is_confined(rel) then
    return respond(sock, 403, nil, nil, req.head_only)
  end
  local dir = pv.dir
  files.resolve_confined(dir, dir .. '/' .. rel, function(real, err)
    if not real then
      return respond(sock, err == 'outside' and 403 or 404, nil, nil, req.head_only)
    end
    -- Markdown renders as a page, so relative .md links are followable;
    -- `?raw` serves the bytes instead.
    local low = rel:lower()
    if (low:match('%.md$') or low:match('%.markdown$')) and not http.query_param(req.query, 'raw') then
      return route_static_md(sock, req, token, rel, real)
    end
    files.serve(sock, real, req, {
      secure = true,
      on_open = function(path)
        if state.config and state.config.reload_images then
          watch.add(token, path, rel)
        end
      end,
    })
  end)
end

---@type table<string, { [1]: string, [2]: fun(sock: uv.uv_tcp_t, req: mdpv.Request, a: string, b: string?): fun()? }[]>
local ROUTES = {
  GET = {
    { '^/$', route_index },
    { '^/p/(%x+)$', route_page },
    { '^/events/(%x+)$', route_events },
    { '^/assets/(%d+)/(.+)$', route_versioned_asset },
    { '^/assets/(.+)$', route_asset },
    { '^/f/(%x+)/(.+)$', route_file },
  },
  POST = {
    { '^/sync/(%x+)$', route_sync },
    { '^/prefs/(%x+)$', route_prefs },
  },
}
ROUTES.HEAD = ROUTES.GET

---@param req mdpv.Request
local function handle(sock, req)
  for _, route in ipairs(ROUTES[req.method] or {}) do
    local a, b = req.path:match(route[1])
    if a then
      return route[2](sock, req, a, b)
    end
  end
  if req.method ~= 'GET' and req.method ~= 'HEAD' then
    return respond(sock, 405, { Allow = 'GET, HEAD' })
  end
  return respond(sock, 404, nil, nil, req.head_only)
end

------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------

--- A digits-only version for asset URLs, derived from every asset's size
--- and mtime: immutable caching stays correct across plugin updates, and an
--- unchanged plugin keeps its cache on a fixed port. Relative URLs inside
--- the assets (modules, lazy vendor scripts, KaTeX fonts) inherit it.
local function asset_version()
  local parts = {}
  for name, kind in vim.fs.dir(asset_dir, { depth = 8 }) do
    local st = kind == 'file' and uv.fs_stat(asset_dir .. '/' .. name)
    if st then
      parts[#parts + 1] = ('%s %d %d.%d'):format(name, st.size, st.mtime.sec, st.mtime.nsec)
    end
  end
  table.sort(parts)
  -- 48 bits: exact in a double; '%d' because tostring() switches to exponent notation.
  return ('%d'):format(tonumber(vim.fn.sha256(table.concat(parts, '\n')):sub(1, 12), 16))
end

local function read_file(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local data = f:read('*a')
  f:close()
  return data
end

function M.is_running()
  return state.listener ~= nil
end

--- Start the server (main loop). A running server is reconfigured instead.
---@param config mdpv.Config
---@return boolean ok, string? err
function M.start(config)
  if state.listener then
    local ok, err, changed = M.reconfigure(config)
    if ok and changed then
      M.notify_reconfigure()
    end
    return ok, err
  end
  local template = read_file(asset_dir .. '/index.html')
  if not template then
    return false, 'frontend assets are missing (see :checkhealth mdpv)'
  end
  local listener, err = http.listen(config.host, config.port, handle)
  if not listener then
    return false, ('could not bind %s:%d (%s)'):format(config.host, config.port, err)
  end
  -- SSE heartbeat: keeps idle streams open through proxies and surfaces
  -- dead sockets as write errors.
  local heartbeat = assert(uv.new_timer())
  heartbeat:start(HEARTBEAT_MS, HEARTBEAT_MS, function()
    for _, pv in pairs(state.previews) do
      for _, stream in pairs(pv.clients) do
        stream:heartbeat()
      end
    end
  end)
  state.listener, state.heartbeat = listener, heartbeat
  state.host, state.port, state.requested_port = config.host, listener.port, config.port
  state.config, state.template, state.version = config, template, asset_version()
  return true
end

--- Apply a new configuration to the running server.
---@param config mdpv.Config
---@return boolean ok, string? err, boolean? changed pages must reload to pick it up
function M.reconfigure(config)
  local old = state.config
  if not (state.listener and old) then
    return true, nil, false
  end
  if config.host ~= state.host or config.port ~= state.requested_port then
    if next(state.previews) then
      return false, 'host and port cannot change while previews are open; close them first'
    end
    M.stop()
    local ok, err = M.start(config)
    return ok, err, false
  end
  state.config = config
  if old.reload_images and not config.reload_images then
    for token in pairs(state.previews) do
      watch.drop(token)
    end
  end
  local changed = old.theme ~= config.theme
    or old.style ~= config.style
    or old.reload_images ~= config.reload_images
    or not vim.deep_equal(cfg.features(old), cfg.features(config))
  return true, nil, changed
end

--- Tell every open page to reload (configuration changed).
function M.notify_reconfigure()
  M.broadcast_all('config', '{}')
end

---@param pv mdpv.Preview
function M.register(pv)
  state.previews[pv.token] = pv
end

--- Retire a preview's routes; `notify` sends attached tabs a final `close`.
---@param token string
---@param notify boolean?
function M.unregister(token, notify)
  local pv = state.previews[token]
  if not pv then
    return
  end
  state.previews[token] = nil
  watch.drop(token)
  for sock, stream in pairs(pv.clients) do
    if notify and not sock:is_closing() then
      stream:finish('close')
    else
      http.close_sock(sock)
    end
  end
  pv.clients = {}
end

--- Queue an SSE event for every tab of a preview. `data` is JSON; a list of
--- paths for `assets`, a table of changed keys for `prefs`.
---@param token string
---@param event string
---@param data string|string[]|table<string, string>
function M.broadcast(token, event, data)
  local pv = state.previews[token]
  if not pv then
    return
  end
  for sock, stream in pairs(pv.clients) do
    if sock:is_closing() then
      pv.clients[sock] = nil
    else
      stream:send(event, data)
    end
  end
end

---@param event string
---@param data string|table<string, string>
function M.broadcast_all(event, data)
  for token in pairs(state.previews) do
    M.broadcast(token, event, data)
  end
end

---@param token string
---@return string
function M.url(token)
  return ('http://%s:%d/p/%s'):format(http.url_host(assert(state.host)), state.port, token)
end

function M.info()
  return {
    host = state.host,
    port = state.port,
    previews = vim.tbl_count(state.previews),
    asset_dir = asset_dir,
    version = state.version,
  }
end

M.asset_dir = asset_dir

function M.stop()
  if state.heartbeat then
    state.heartbeat:stop()
    state.heartbeat:close()
  end
  for _, token in ipairs(vim.tbl_keys(state.previews)) do
    M.unregister(token, true)
  end
  if state.listener then
    state.listener.close()
  end
  state.listener, state.heartbeat = nil, nil
  state.host, state.port, state.requested_port, state.template = nil, nil, nil, nil
end

return M
