---@brief HTTP/1.1 on vim.uv, the small subset a preview needs: a listener
--- that reads one request per connection (bounded size and time), response
--- serialization, and request/text utilities. No routing, no app state.
---
--- Every response closes its connection (no keep-alive); the one long-lived
--- response is SSE, whose handler keeps the socket. All callbacks here run
--- in libuv's fast context.

local uv = vim.uv

local M = {}

local MAX_HEADER_BYTES = 16 * 1024
local MAX_BODY_BYTES = 4 * 1024 -- POST bodies are tiny JSON messages
local MAX_CONNECTIONS = 256
local REQUEST_TIMEOUT_MS = 3000
local SHUTDOWN_GRACE_MS = 1000 -- server stop: time for queued writes to drain

M.REASONS = {
  [200] = 'OK',
  [204] = 'No Content',
  [206] = 'Partial Content',
  [304] = 'Not Modified',
  [400] = 'Bad Request',
  [403] = 'Forbidden',
  [404] = 'Not Found',
  [405] = 'Method Not Allowed',
  [413] = 'Payload Too Large',
  [416] = 'Range Not Satisfiable',
  [431] = 'Request Header Fields Too Large',
  [500] = 'Internal Server Error',
}

M.MIME = {
  html = 'text/html; charset=utf-8',
  js = 'text/javascript; charset=utf-8',
  mjs = 'text/javascript; charset=utf-8',
  css = 'text/css; charset=utf-8',
  json = 'application/json',
  wasm = 'application/wasm',
  txt = 'text/plain; charset=utf-8',
  md = 'text/plain; charset=utf-8',
  markdown = 'text/plain; charset=utf-8',
  svg = 'image/svg+xml',
  png = 'image/png',
  jpg = 'image/jpeg',
  jpeg = 'image/jpeg',
  gif = 'image/gif',
  webp = 'image/webp',
  avif = 'image/avif',
  bmp = 'image/bmp',
  ico = 'image/x-icon',
  mp4 = 'video/mp4',
  webm = 'video/webm',
  mov = 'video/quicktime',
  mp3 = 'audio/mpeg',
  ogg = 'audio/ogg',
  wav = 'audio/wav',
  pdf = 'application/pdf',
  woff2 = 'font/woff2',
}

--- libuv calls report success as 0 (luv) or true; failures as nil, err.
local function uv_ok(r, err)
  return r == 0 or r == true or (r == nil and not err)
end

function M.close_sock(sock)
  if sock and not sock:is_closing() then
    sock:close()
  end
end

--- Queue `data` on `sock`; `cb(err)` runs once it is flushed. False if the
--- write failed outright (closed handle, EPIPE): `cb` then never runs.
---@param sock uv.uv_tcp_t
---@param data string
---@param cb fun(err: string?)
---@return boolean
function M.write(sock, data, cb)
  local ok, req = pcall(sock.write, sock, data, cb)
  return ok and req ~= nil
end

--- Write `data` then close the connection once flushed.
function M.write_and_close(sock, data)
  if not M.write(sock, data, function()
    M.close_sock(sock)
  end) then
    M.close_sock(sock)
  end
end

--- Serialize a response head: status line, headers, and the blank line.
function M.head(status, headers)
  local lines = { ('HTTP/1.1 %d %s'):format(status, M.REASONS[status] or 'OK') }
  for k, v in pairs(headers) do
    lines[#lines + 1] = k .. ': ' .. v
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = ''
  return table.concat(lines, '\r\n')
end

--- Write a complete response and close the socket. For HEAD requests,
--- `head_only` suppresses the body while keeping the GET Content-Length.
function M.respond(sock, status, headers, body, head_only)
  headers = headers or {}
  if status == 304 or status == 204 then
    body = '' -- must carry neither content nor Content-Length
    headers['Content-Length'] = nil
  else
    body = body or (status ~= 200 and M.REASONS[status] or '')
    headers['Content-Length'] = tostring(#body)
  end
  headers['Content-Type'] = headers['Content-Type'] or 'text/plain; charset=utf-8'
  headers['Connection'] = 'close'
  M.write_and_close(sock, M.head(status, headers) .. (head_only and '' or body))
end

function M.html_escape(s)
  return (
    s:gsub('[&<>"\']', {
      ['&'] = '&amp;',
      ['<'] = '&lt;',
      ['>'] = '&gt;',
      ['"'] = '&quot;',
      ["'"] = '&#39;',
    })
  )
end

function M.percent_decode(s)
  return (s:gsub('%%(%x%x)', function(h)
    return string.char(tonumber(h, 16))
  end))
end

--- All values of a request header; `name` must be given lowercase.
function M.req_headers(head, name)
  local values = {}
  for k, v in head:gmatch('\r\n([%w%-]+):[ \t]*([^\r\n]*)') do
    if k:lower() == name then
      values[#values + 1] = (v:gsub('%s+$', ''))
    end
  end
  return values
end

--- First value of a request header; `name` must be given lowercase.
function M.req_header(head, name)
  return M.req_headers(head, name)[1]
end

--- Value of query parameter `name` ('' for a bare `?name`), or nil.
function M.query_param(query, name)
  for pair in query:gmatch('[^&;]+') do
    local k, v = pair:match('^([^=]*)=?(.*)$')
    if k == name then
      return M.percent_decode(v)
    end
  end
end

--- Reject relative paths that could escape their base directory.
function M.is_confined(rel)
  if rel:find('\0', 1, true) or rel:find('\\', 1, true) or rel:sub(1, 1) == '/' or rel:match('^%a:') then
    return false
  end
  for seg in rel:gmatch('[^/]+') do
    if seg == '..' then
      return false
    end
  end
  return true
end

--- Host part of a URL for a bound address: unspecified addresses are not
--- browsable (use loopback) and IPv6 literals need brackets.
function M.url_host(host)
  if host == '0.0.0.0' then
    return '127.0.0.1'
  elseif host == '::' then
    return '[::1]'
  elseif host:find(':', 1, true) then
    return '[' .. host .. ']'
  end
  return host
end

------------------------------------------------------------------------------
-- Listener
------------------------------------------------------------------------------

---@class mdpv.Request
---@field method string
---@field path string percent-encoded path, query stripped
---@field query string raw query string ('' if none)
---@field head string request line + headers, through the blank line
---@field body string? POST body
---@field head_only boolean HEAD request

---@class mdpv.Listener
---@field port integer
---@field close fun()

--- Accept connections on host:port and call `handler(sock, req)` once per
--- connection with its parsed request. The handler owns the socket: respond
--- (which closes it) or keep it (SSE) and return a function to run when the
--- peer disconnects. Read errors, EOF, oversize heads or bodies, and requests
--- idle past REQUEST_TIMEOUT_MS close the connection.
---@param handler fun(sock: uv.uv_tcp_t, req: mdpv.Request): fun()?
---@return mdpv.Listener? listener, string? err
function M.listen(host, port, handler)
  local tcp = uv.new_tcp()
  if not tcp then
    return nil, 'could not create TCP handle'
  end
  local conns = {} ---@type table<uv.uv_tcp_t, true>

  local function live_count()
    local n = 0
    for sock in pairs(conns) do
      if sock:is_closing() then
        conns[sock] = nil -- responses close asynchronously; sweep before counting
      else
        n = n + 1
      end
    end
    return n
  end

  local function on_connection()
    local sock = uv.new_tcp()
    if not sock then
      return
    end
    -- Accept even over the cap: libuv stops polling the listening socket
    -- until a pending connection is accepted.
    if not uv_ok(tcp:accept(sock)) or live_count() >= MAX_CONNECTIONS then
      return M.close_sock(sock)
    end
    conns[sock] = true
    local timer = uv.new_timer()
    if not timer then
      return M.close_sock(sock)
    end
    local chunks, done = {}, false
    local head_end, body_len, on_close

    -- Stop reading this request: one response per connection.
    local function settle()
      done = true
      chunks = nil
      if not timer:is_closing() then
        timer:close()
      end
    end
    local function fail(status)
      settle()
      if status then
        M.respond(sock, status)
      else
        M.close_sock(sock)
      end
    end

    if
      not uv_ok(timer:start(REQUEST_TIMEOUT_MS, 0, function()
        if not done then
          fail()
        end
      end))
    then
      return fail()
    end

    -- read_start stays armed after the request is handled, so a client
    -- disconnect surfaces as EOF; the SSE handler relies on that.
    sock:read_start(function(err, chunk)
      if err or not chunk then
        if not done then
          settle()
        end
        M.close_sock(sock)
        if on_close then
          on_close()
          on_close = nil
        end
        return
      end
      if done then
        return -- pipelined or trailing data: ignored
      end
      chunks[#chunks + 1] = chunk
      local data = table.concat(chunks)
      if not head_end then
        head_end = data:find('\r\n\r\n', 1, true)
        if not head_end then
          if #data > MAX_HEADER_BYTES then
            fail(431)
          end
          return -- keep accumulating the head
        end
        if head_end + 3 > MAX_HEADER_BYTES then
          return fail(431)
        end
        -- Only POST carries a body: Content-Length framing, no chunked
        -- encoding (smuggling-shaped requests are refused outright).
        if data:match('^POST%s') then
          local head = data:sub(1, head_end + 3)
          local lengths = M.req_headers(head, 'content-length')
          if M.req_header(head, 'transfer-encoding') or #lengths > 1 then
            return fail(400)
          end
          if lengths[1] and not lengths[1]:match('^%d+$') then
            return fail(400)
          end
          body_len = tonumber(lengths[1] or '0')
          if body_len > MAX_BODY_BYTES then
            return fail(413)
          end
        end
      end
      if body_len and #data < head_end + 3 + body_len then
        return -- body still streaming in
      end
      settle()
      local head = data:sub(1, head_end + 3)
      local method, target = head:match('^(%u+)%s+(%S+)%s+HTTP/1%.[01]\r\n')
      if not method then
        return M.respond(sock, 400)
      end
      local req = {
        method = method,
        path = target:gsub('[?#].*$', ''),
        query = target:match('%?([^#]*)') or '',
        head = head,
        body = body_len and data:sub(head_end + 4, head_end + 3 + body_len) or nil,
        head_only = method == 'HEAD',
      }
      local ok, hook = pcall(handler, sock, req)
      if not ok then
        M.respond(sock, 500)
      elseif type(hook) == 'function' then
        on_close = hook
      end
    end)
  end

  local ok, err = pcall(function()
    local bok, berr = tcp:bind(host, port)
    if not uv_ok(bok, berr) then
      error(berr or 'bind failed', 0)
    end
    local lok, lerr = tcp:listen(128, function(lerr2)
      if not lerr2 then
        on_connection()
      end
    end)
    if not uv_ok(lok, lerr) then
      error(lerr or 'listen failed', 0)
    end
  end)
  if not ok then
    M.close_sock(tcp)
    return nil, err
  end

  return {
    port = tcp:getsockname().port,
    -- Connections end with a shutdown, which completes once queued writes
    -- (a final SSE `close`, a response tail) have drained; peers that stopped
    -- reading are cut off after a grace period.
    close = function()
      M.close_sock(tcp)
      local socks = conns
      conns = {}
      for sock in pairs(socks) do
        if sock:is_closing() or not sock:shutdown(function()
          M.close_sock(sock)
        end) then
          M.close_sock(sock)
        end
      end
      local grace = uv.new_timer()
      if grace then
        grace:start(SHUTDOWN_GRACE_MS, 0, function()
          grace:close()
          for sock in pairs(socks) do
            M.close_sock(sock)
          end
        end)
      end
    end,
  }
end

return M
