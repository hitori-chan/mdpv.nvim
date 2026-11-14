---@brief Previews. A preview is a token on the shared server bound to one
--- buffer: it streams the buffer's content (nvim_buf_attach, debounced) and
--- cursor line (scroll sync), and applies what the page sends back (cursor
--- moves, jumps to source, task checkbox flips).
---
--- Previews stay locked to their buffer, except the follower: with
--- `follow_buffer`, a single shared preview rebinds to whichever eligible
--- buffer becomes current, so one browser tab tracks your editing.

local server = require('mdpv.server')
local watch = require('mdpv.watch')
local cfg = require('mdpv.config')

local M = {}

local CURSOR_DEBOUNCE_MS = 80

---@class mdpv.Preview
---@field token string unguessable route id
---@field bufnr integer bound buffer (may be unloaded under the follower)
---@field title string tail of the buffer name, or a placeholder
---@field dir string directory relative file requests resolve against
---@field follow boolean the follow_buffer preview
---@field clients table<uv.uv_tcp_t, mdpv.Stream> attached tabs (managed by the server)
---@field config mdpv.Config
---@field epoch integer bumps per (re)bind; retires the previous binding's callbacks
---@field generation integer bumps when payload-visible configuration changes
---@field augroup integer autocmds of the current binding
---@field timer uv.uv_timer_t edit debounce
---@field cursor_timer uv.uv_timer_t cursor debounce
---@field last_line integer last cursor line sent (or applied from the page)
---@field attached boolean the current binding's nvim_buf_attach is live
---@field closed boolean?
---@field cache_rev string? revision of cache_json
---@field cache_json string? last payload, reused until the revision moves
---@field push_soon fun()
---@field send_cursor fun()
local Preview = {}
Preview.__index = Preview

---@type table<string, mdpv.Preview> token -> preview
M.previews = {}

local follow_group ---@type integer? autocmds driving the follower

local function new_token()
  local ok, bytes = pcall(vim.uv.random, 16)
  if ok and type(bytes) == 'string' and #bytes == 16 then
    return vim.text.hexencode(bytes):lower()
  end
end

---@return string title, string dir
local function buf_meta(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then
    return ('buffer %d'):format(bufnr), assert(vim.uv.cwd())
  end
  return vim.fs.basename(name), vim.fs.dirname(name)
end

------------------------------------------------------------------------------
-- Content
------------------------------------------------------------------------------

--- Identifies what the page has rendered: binding, buffer state, config.
---@return string?
function Preview:revision()
  local b = self.bufnr
  if not vim.api.nvim_buf_is_loaded(b) then
    return self.cache_rev -- follower whose buffer went away: keep showing it
  end
  return ('%d.%d.%d.%d'):format(
    self.epoch,
    vim.api.nvim_buf_get_changedtick(b),
    self.generation,
    vim.bo[b].modifiable and 1 or 0
  )
end

--- The buffer as a JSON payload (SSE `update` data and page boot data),
--- cached per revision so the page load and its first SSE push share one
--- read + encode.
---@return string?
function Preview:payload()
  local rev = self:revision()
  if rev == nil or rev == self.cache_rev then
    return self.cache_json
  end
  local b = self.bufnr
  self.cache_json = vim.json.encode({
    token = self.token,
    title = self.title,
    md = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), '\n'),
    modifiable = vim.bo[b].modifiable,
    revision = rev,
    epoch = self.epoch,
    features = cfg.features(self.config),
  })
  self.cache_rev = rev
  return self.cache_json
end

--- Send the buffer to attached tabs now. Nobody listening: nothing is read
--- or encoded; a tab connecting later gets a fresh payload.
function Preview:push()
  if self.closed or next(self.clients) == nil then
    return
  end
  local json = self:payload()
  if json then
    server.broadcast(self.token, 'update', json)
  end
end

--- Debounced push: only the last change in a burst reaches the page.
function Preview:schedule_push()
  self.timer:stop()
  self.timer:start(self.config.debounce, 0, self.push_soon)
end

------------------------------------------------------------------------------
-- Cursor
------------------------------------------------------------------------------

--- The window to read/move the cursor in: the current one if it shows the
--- buffer, else one in the current tabpage, else any.
---@return integer?
function Preview:window()
  local cur = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(cur) == self.bufnr then
    return cur
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local wins = vim.fn.win_findbuf(self.bufnr)
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_get_tabpage(win) == tab then
      return win
    end
  end
  return wins[1]
end

--- Broadcast the cursor line immediately (after a rebind).
function Preview:sync_cursor()
  local win = self.config.scroll_sync ~= false and self:window()
  if win then
    self.last_line = vim.api.nvim_win_get_cursor(win)[1]
    self.send_cursor()
  end
end

--- Messages POSTed by the page:
---   { line = N }                          page scrolled ("move cursor on scroll")
---   { line = N, jump = true }             double-click: jump there, centered
---   { toggle = { line = N, checked = b }} task checkbox clicked
function Preview:message(msg)
  if self.closed or not vim.api.nvim_buf_is_loaded(self.bufnr) then
    return
  end
  local toggle = msg.toggle
  if type(toggle) == 'table' and type(toggle.line) == 'number' then
    return self:toggle_task(math.floor(toggle.line), toggle.checked == true)
  end
  if type(msg.line) ~= 'number' or (msg.jump ~= true and self.config.scroll_sync == false) then
    return
  end
  local win = self:window()
  if not win then
    return
  end
  local line = math.max(1, math.min(math.floor(msg.line), vim.api.nvim_buf_line_count(self.bufnr)))
  -- Recorded first: the CursorMoved this causes must not echo back.
  self.last_line = line
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  if msg.jump == true then
    pcall(vim.api.nvim_win_call, win, function()
      vim.cmd('normal! zvzz')
    end)
  end
end

--- Flip the [ ]/[x] on `line`, provided it still is a task item and the
--- buffer is modifiable. The edit streams back through the normal push.
function Preview:toggle_task(line, checked)
  local b = self.bufnr
  if not vim.bo[b].modifiable or line < 1 or line > vim.api.nvim_buf_line_count(b) then
    return
  end
  local text = vim.api.nvim_buf_get_lines(b, line - 1, line, false)[1]
  -- List marker ([-*+] or "1."/"1)"), optionally inside blockquote/callout
  -- '>' prefixes, followed by the [ ]/[x] state box.
  local marker = text:match('^([>%s]*[-*+]%s+%[)[ xX]%]') or text:match('^([>%s]*%d+[.%)]%s+%[)[ xX]%]')
  if marker then
    vim.api.nvim_buf_set_text(b, line - 1, #marker, line - 1, #marker + 1, { checked and 'x' or ' ' })
  end
end

------------------------------------------------------------------------------
-- Binding
------------------------------------------------------------------------------

--- Track every mutation (typing, :s, undo, LSP edits, API calls — unlike
--- TextChanged autocmds). Runs under textlock: only re-arms the timer.
function Preview:attach()
  local epoch, bufnr = self.epoch, self.bufnr
  self.attached = vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      if self.closed or self.epoch ~= epoch then
        return true -- stale binding: detach
      end
      self:schedule_push()
    end,
    on_reload = function()
      if not self.closed and self.epoch == epoch then
        self:schedule_push()
      end
    end,
    on_detach = function()
      if self.epoch == epoch then
        self.attached = false -- unloaded; BufReadPost re-attaches
      end
    end,
  })
end

--- (Re)create the current binding's autocmds from the current config.
function Preview:autocmds()
  local bufnr = self.bufnr
  vim.api.nvim_clear_autocmds({ group = self.augroup })
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return -- a follower whose buffer was wiped: rebinding re-creates them
  end
  local function on(events, callback, extra)
    vim.api.nvim_create_autocmd(
      events,
      vim.tbl_extend('force', { group = self.augroup, buffer = bufnr, callback = callback }, extra or {})
    )
  end

  on('BufFilePost', function()
    local title = self.title
    self.title, self.dir = buf_meta(bufnr)
    if self.title ~= title then
      self.generation = self.generation + 1
    end
    self:schedule_push()
  end)
  on('BufReadPost', function()
    if not self.attached then
      self:attach()
    end
    self:schedule_push()
  end)
  -- modifiable is part of the revision; this only triggers the push.
  vim.api.nvim_create_autocmd('OptionSet', {
    group = self.augroup,
    pattern = 'modifiable',
    callback = function(args)
      if args.buf == bufnr then
        self:schedule_push()
      end
    end,
  })

  -- Scroll sync follows the cursor line (not the topline: the cursor is
  -- where you work), skipping column-only moves and echoes of page moves.
  if self.config.scroll_sync ~= false then
    on({ 'CursorMoved', 'CursorMovedI' }, function()
      if next(self.clients) == nil then
        return
      end
      local line = vim.api.nvim_win_get_cursor(0)[1]
      if line ~= self.last_line then
        self.last_line = line
        self.cursor_timer:stop()
        self.cursor_timer:start(CURSOR_DEBOUNCE_MS, 0, self.send_cursor)
      end
    end)
  end

  if self.config.auto_close and not self.follow then
    on({ 'BufUnload', 'BufWipeout' }, function()
      -- Fires mid-unload: tear down outside of it, unless it was a reload
      -- (:e!, :checktime), which leaves the buffer loaded again.
      vim.schedule(function()
        if not vim.api.nvim_buf_is_loaded(bufnr) then
          M.close(self)
        end
      end)
    end)
  end
end

---@param bufnr integer
function Preview:bind(bufnr)
  self.epoch = self.epoch + 1
  self.bufnr = bufnr
  self.title, self.dir = buf_meta(bufnr)
  self.last_line = 0
  self:attach()
  self:autocmds()
end

--- Follower: show `bufnr` instead, right away.
function Preview:rebind(bufnr)
  if bufnr == self.bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  watch.drop(self.token) -- the file directory changes with the buffer
  self:bind(bufnr)
  self:push()
  self:sync_cursor()
end

------------------------------------------------------------------------------
-- Registry
------------------------------------------------------------------------------

local function start_following(pv)
  follow_group = vim.api.nvim_create_augroup('mdpv.follow', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'FileType' }, {
    group = follow_group,
    callback = function(args)
      -- Deferred: keeps buffer switches snappy and collapses bursts
      -- (:bufdo, session restore) into one rebind to where you land.
      vim.schedule(function()
        local bufnr = args.buf
        if
          pv.closed
          or bufnr ~= vim.api.nvim_get_current_buf()
          or vim.bo[bufnr].buftype ~= '' -- help, terminals, LSP hover floats
          or vim.api.nvim_win_get_config(0).relative ~= ''
          or not cfg.eligible(bufnr, pv.config)
        then
          return
        end
        pv:rebind(bufnr)
      end)
    end,
  })
end

local function stop_following()
  if follow_group then
    pcall(vim.api.nvim_del_augroup_by_id, follow_group)
    follow_group = nil
  end
end

---@return mdpv.Preview? pv, string? err
local function create(bufnr, config, follow)
  local token = new_token()
  if not token then
    return nil, 'secure preview-token generation is unavailable'
  end
  local timer, cursor_timer = vim.uv.new_timer(), vim.uv.new_timer()
  local ok, err = false, 'could not create timers' ---@type boolean, string?
  if timer and cursor_timer then
    ok, err = server.start(config)
  end
  if not ok then
    if timer then
      timer:close()
    end
    if cursor_timer then
      cursor_timer:close()
    end
    return nil, err
  end
  local pv = setmetatable({
    token = token,
    follow = follow,
    clients = {},
    config = config,
    epoch = 0,
    generation = 0,
    last_line = 0,
    timer = timer,
    cursor_timer = cursor_timer,
    augroup = vim.api.nvim_create_augroup('mdpv.' .. token, { clear = true }),
  }, Preview)
  pv.push_soon = vim.schedule_wrap(function()
    pv:push()
  end)
  pv.send_cursor = vim.schedule_wrap(function()
    if not pv.closed then
      server.broadcast(pv.token, 'scroll', vim.json.encode({ line = pv.last_line }))
    end
  end)
  pv:bind(bufnr)
  server.register(pv)
  M.previews[token] = pv
  if follow then
    start_following(pv)
  end
  return pv
end

--- The preview showing `bufnr`: its locked preview, else the follower if it
--- is bound there.
---@return mdpv.Preview?
function M.of(bufnr)
  local follower
  for _, pv in pairs(M.previews) do
    if pv.bufnr == bufnr then
      if not pv.follow then
        return pv
      end
      follower = pv
    end
  end
  return follower
end

---@return mdpv.Preview?
function M.follower()
  for _, pv in pairs(M.previews) do
    if pv.follow then
      return pv
    end
  end
end

--- Preview for `bufnr`: the existing one, else (with follow_buffer) the
--- follower rebound here, else a new one.
---@param bufnr integer
---@param config mdpv.Config
---@return mdpv.Preview? pv, string? err
function M.open(bufnr, config)
  local pv = M.of(bufnr)
  if pv then
    return pv
  end
  if config.follow_buffer then
    pv = M.follower()
    if pv then
      pv:rebind(bufnr)
      return pv
    end
  end
  return create(bufnr, config, config.follow_buffer)
end

---@param pv mdpv.Preview
---@return boolean closed
function M.close(pv)
  if pv.closed then
    return false
  end
  pv.closed = true
  M.previews[pv.token] = nil
  for _, t in ipairs({ pv.timer, pv.cursor_timer }) do
    t:stop()
    t:close()
  end
  pcall(vim.api.nvim_del_augroup_by_id, pv.augroup)
  if pv.follow then
    stop_following()
  end
  server.unregister(pv.token, true)
  if pv.config.auto_stop and next(M.previews) == nil then
    server.stop()
  end
  return true
end

function M.close_all()
  for _, pv in pairs(vim.tbl_values(M.previews)) do
    M.close(pv)
  end
  server.stop()
end

--- Apply a new configuration to open previews (the server tells pages to
--- reload afterwards if they render differently).
---@param config mdpv.Config
function M.reconfigure(config)
  for _, pv in pairs(M.previews) do
    local old = pv.config
    pv.config = config
    if not vim.deep_equal(cfg.features(old), cfg.features(config)) then
      pv.generation = pv.generation + 1 -- the payload embeds the features
    end
    if pv.follow and not config.follow_buffer then
      pv.follow = false -- stays open, now locked to its current buffer
      stop_following()
      local b = pv.bufnr
      if not vim.api.nvim_buf_is_valid(b) or (config.auto_close and not vim.api.nvim_buf_is_loaded(b)) then
        M.close(pv) -- ...unless that buffer is gone (or unloaded, under auto_close)
      end
    end
    if not pv.closed then
      pv:autocmds()
    end
  end
end

---@return { bufnr: integer, title: string, url: string, follow: boolean, tabs: integer }[]
function M.list()
  local out = {}
  for _, pv in pairs(M.previews) do
    out[#out + 1] = {
      bufnr = pv.bufnr,
      title = pv.title,
      url = server.url(pv.token),
      follow = pv.follow,
      tabs = vim.tbl_count(pv.clients),
    }
  end
  table.sort(out, function(a, b)
    return a.bufnr < b.bufnr
  end)
  return out
end

return M
