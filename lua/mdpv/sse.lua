---@brief Server-Sent Event streams, one per attached browser tab.
---
--- Frames queue per event name: a newer `update` or `scroll` replaces the
--- pending one, `assets` and `prefs` merge into one pending set, and the
--- queue flushes in priority order one write at a time. A slow tab therefore
--- holds at most one frame per event, never a backlog; one whose write is
--- still in flight a heartbeat later is stalled and dropped.
--- Runs in libuv callbacks (fast context): no vim.api in here.

local http = require('mdpv.http')

local M = {}

-- A finished stream whose last frame never drains (tab stopped reading) is
-- closed after this long.
local FINISH_TIMEOUT_MS = 5000

-- Flush order: content before the cursor position that refers to it.
local ORDER = { 'update', 'scroll', 'assets', 'prefs', 'config' }

local HEAD = table.concat({
  'HTTP/1.1 200 OK',
  'Content-Type: text/event-stream',
  'Cache-Control: no-cache',
  'Connection: keep-alive',
  'X-Accel-Buffering: no',
  '',
  'retry: 1000\n\n',
}, '\r\n')

function M.frame(event, data)
  return 'event: ' .. event .. '\ndata: ' .. data .. '\n\n'
end

---@class mdpv.Stream
---@field sock uv.uv_tcp_t
---@field pending table<string, string> event -> frame
---@field paths table<string, true> asset paths awaiting an `assets` frame
---@field prefs table<string, string> preference changes awaiting a `prefs` frame
---@field busy boolean a write is in flight
---@field stalled boolean? the write in flight was already in flight at the last heartbeat
---@field finishing boolean? the last frame is written: nothing else goes out
---@field dead boolean?
---@field on_dead fun(sock: uv.uv_tcp_t)
local Stream = {}
Stream.__index = Stream

--- Start a stream on `sock`: writes the response head, then `on_open()`.
---@param on_dead fun(sock: uv.uv_tcp_t) called once when the socket fails or closes
---@param on_open fun()? called once the head is flushed
---@return mdpv.Stream
function M.open(sock, on_dead, on_open)
  local s = setmetatable({ sock = sock, pending = {}, paths = {}, prefs = {}, busy = false, on_dead = on_dead }, Stream)
  s:_write(HEAD, function()
    if on_open then
      on_open()
    end
    s:_flush()
  end)
  return s
end

function Stream:_die()
  if not self.dead then
    self.dead = true
    self.on_dead(self.sock)
  end
end

function Stream:_write(data, after)
  self.busy, self.stalled = true, false
  local queued = http.write(self.sock, data, function(err)
    self.busy = false
    if err then
      return self:_die()
    end
    if after then
      after()
    else
      self:_flush()
    end
  end)
  if not queued then
    self.busy = false
    self:_die()
  end
end

--- Take the next queued frame in priority order.
function Stream:_take()
  for _, event in ipairs(ORDER) do
    local frame = self.pending[event]
    if event == 'assets' and next(self.paths) then
      local list = vim.tbl_keys(self.paths)
      table.sort(list)
      self.paths = {}
      frame = M.frame('assets', vim.json.encode({ paths = list }))
    elseif event == 'prefs' and next(self.prefs) then
      frame = M.frame('prefs', vim.json.encode(self.prefs, { sort_keys = true }))
      self.prefs = {}
    end
    if frame then
      self.pending[event] = nil
      return frame
    end
  end
  local event, frame = next(self.pending)
  if event then
    self.pending[event] = nil
    return frame
  end
end

function Stream:_flush()
  if self.busy or self.dead or self.finishing or self.sock:is_closing() then
    return
  end
  local frame = self:_take()
  if frame then
    return self:_write(frame)
  end
end

--- Queue an event. `data` is a JSON string; for `assets` a list of paths,
--- for `prefs` a table of changed keys (both merge with what is pending).
---@param event string
---@param data string|string[]|table<string, string>
function Stream:send(event, data)
  if self.dead or self.finishing then
    return
  end
  if event == 'assets' then
    for _, path in
      ipairs(data --[[@as string[] ]])
    do
      self.paths[path] = true
    end
  elseif event == 'prefs' then
    for key, value in
      pairs(data --[[@as table<string, string>]])
    do
      self.prefs[key] = value
    end
  else
    self.pending[event] = M.frame(event, data --[[@as string]])
  end
  self:_flush()
end

--- Drop everything queued, send `event` as the last frame, then close.
--- The frame goes to libuv at once, behind any write in flight, so a server
--- stopping right after still drains it (http listener close shuts down).
function Stream:finish(event)
  if self.dead or self.finishing then
    return
  end
  self.finishing = true
  self.pending, self.paths, self.prefs = {}, {}, {}
  local timer = vim.uv.new_timer()
  local function done()
    if timer and not timer:is_closing() then
      timer:close()
    end
    self:_die()
  end
  if not http.write(self.sock, M.frame(event, '{}'), done) then
    return done()
  end
  if timer then
    timer:start(FINISH_TIMEOUT_MS, 0, done)
  end
end

--- Comment frame that keeps idle streams alive and surfaces dead sockets.
--- A write still in flight since the previous heartbeat means the tab
--- stopped reading: drop it (EventSource reconnects if it ever wakes).
function Stream:heartbeat()
  if self.dead then
    return
  elseif self.busy then
    if self.stalled then
      return self:_die()
    end
    self.stalled = true
  elseif not (self.finishing or next(self.pending) or next(self.paths) or next(self.prefs)) then
    self:_write(': hb\n\n')
  end
end

return M
