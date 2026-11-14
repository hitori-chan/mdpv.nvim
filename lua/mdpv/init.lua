---@brief Public API and the :Preview command for mdpv.nvim.

local config = require('mdpv.config')

local M = {}

--- Active configuration (read-only; change it through setup()).
---@type mdpv.Config
M.config = config.current

--- Configure the plugin. Optional: the defaults work without calling it.
--- Validated changes apply to open previews immediately; their pages reload
--- when rendering, theme, or sync settings changed.
---@param opts table?
function M.setup(opts)
  local new = config.resolve(opts)
  if package.loaded['mdpv.server'] and require('mdpv.server').is_running() then
    local server = require('mdpv.server')
    local ok, err, changed = server.reconfigure(new)
    if not ok then
      error(err, 0)
    end
    require('mdpv.preview').reconfigure(new)
    if changed then
      server.notify_reconfigure()
    end
  end
  config.current = new
  M.config = new
end

local function notify(msg, level)
  vim.notify('mdpv: ' .. msg, level or vim.log.levels.INFO)
end

---@return integer?
local function resolve_buf(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  return vim.api.nvim_buf_is_valid(bufnr) and bufnr or nil
end

--- Hand the URL to the configured opener.
local function open_in_browser(url)
  local how = M.config.open_browser
  if vim.is_callable(how) then
    local ok, err = pcall(how --[[@as fun(url: string)]], url)
    if not ok then
      notify(('open_browser failed (%s) — open %s manually'):format(err, url), vim.log.levels.WARN)
    end
    return
  end
  local _, err = vim.ui.open(url, type(how) == 'table' and { cmd = how } or nil)
  if err then
    notify(('could not open a browser (%s) — open %s manually'):format(err, url), vim.log.levels.WARN)
  end
end

--- Open a preview for a buffer (or reuse its live one) and show it in the
--- browser — unless a tab is already watching it, which just keeps going.
--- With follow_buffer, the shared preview switches to this buffer instead.
---@param bufnr integer? defaults to the current buffer
---@param opts { force: boolean? }? force skips the filetype check
---@return string? url
function M.open(bufnr, opts)
  opts = opts or {}
  bufnr = resolve_buf(bufnr)
  if not bufnr then
    notify('invalid buffer', vim.log.levels.ERROR)
    return nil
  end
  if not opts.force and not config.eligible(bufnr, M.config) then
    notify(
      ("filetype '%s' is not in config.filetypes — use :Preview! to force"):format(vim.bo[bufnr].filetype),
      vim.log.levels.WARN
    )
    return nil
  end

  local preview = require('mdpv.preview')
  local pv, err = preview.open(bufnr, M.config)
  if not pv then
    notify(err or 'failed to start the server', vim.log.levels.ERROR)
    return nil
  end
  local url = require('mdpv.server').url(pv.token)
  local tabs = vim.tbl_count(pv.clients)
  if tabs > 0 then
    notify(('showing in %d open tab%s: %s'):format(tabs, tabs == 1 and '' or 's', url))
  else
    if M.config.open_browser then
      open_in_browser(url)
    end
    notify('preview: ' .. url)
  end
  return url
end

--- Close the preview showing a buffer.
---@param bufnr integer?
function M.close(bufnr)
  bufnr = resolve_buf(bufnr)
  local preview = require('mdpv.preview')
  local pv = bufnr and (preview.of(bufnr) or preview.follower())
  if pv and preview.close(pv) then
    notify('preview closed')
  else
    notify('no preview for this buffer', vim.log.levels.WARN)
  end
end

--- Close the buffer's preview if it has one, else open one.
---@param bufnr integer?
---@return string? url
function M.toggle(bufnr)
  bufnr = resolve_buf(bufnr)
  if bufnr and package.loaded['mdpv.preview'] and require('mdpv.preview').of(bufnr) then
    return M.close(bufnr)
  end
  return M.open(bufnr)
end

--- Close every preview and stop the server.
function M.stop()
  if package.loaded['mdpv.preview'] then
    require('mdpv.preview').close_all()
  end
  notify('server stopped')
end

--- URL of the preview showing a buffer, if any.
---@param bufnr integer?
---@return string?
function M.url(bufnr)
  bufnr = resolve_buf(bufnr)
  if not (bufnr and package.loaded['mdpv.preview']) then
    return nil
  end
  local pv = require('mdpv.preview').of(bufnr)
  return pv and require('mdpv.server').url(pv.token) or nil
end

---@return { bufnr: integer, title: string, url: string, follow: boolean, tabs: integer }[]
function M.list()
  return package.loaded['mdpv.preview'] and require('mdpv.preview').list() or {}
end

------------------------------------------------------------------------------
-- :Preview command plumbing
------------------------------------------------------------------------------

local subcommands = {
  open = function(cmd)
    M.open(nil, { force = cmd.bang })
  end,
  close = function()
    M.close()
  end,
  toggle = function(cmd)
    if cmd.bang then
      local bufnr = vim.api.nvim_get_current_buf()
      if not (package.loaded['mdpv.preview'] and require('mdpv.preview').of(bufnr)) then
        return M.open(bufnr, { force = true })
      end
    end
    M.toggle()
  end,
  stop = function()
    M.stop()
  end,
  list = function()
    local items = M.list()
    if #items == 0 then
      return notify('no active previews')
    end
    local lines = {}
    for _, it in ipairs(items) do
      local tags = (it.follow and 'follows buffers, ' or '') .. ('%d tab%s'):format(it.tabs, it.tabs == 1 and '' or 's')
      lines[#lines + 1] = ('%3d  %-28s %s  (%s)'):format(it.bufnr, it.title, it.url, tags)
    end
    notify('active previews:\n' .. table.concat(lines, '\n'))
  end,
}

function M._command(cmd)
  local name = cmd.fargs[1] or 'open'
  local sub = subcommands[name]
  if not sub then
    local names = vim.tbl_keys(subcommands)
    table.sort(names)
    return notify(
      ('unknown subcommand %q (expected: %s)'):format(name, table.concat(names, ', ')),
      vim.log.levels.ERROR
    )
  end
  sub(cmd)
end

function M._complete(arglead)
  local names = vim.tbl_keys(subcommands)
  table.sort(names)
  return vim.tbl_filter(function(s)
    return vim.startswith(s, arglead)
  end, names)
end

return M
