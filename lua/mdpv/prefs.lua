---@brief Page preferences — theme, style, width, outline, sync switches, corners.
---
--- Edited in the page, owned by the editor: a small state file is the single
--- source of truth. Pages are rendered with the current values already on
--- <html> as data attributes (so the first paint is right), POST changes
--- back, and every open tab hears about a change over SSE. A browser-side
--- store would not work anyway: the default ephemeral port makes every
--- Neovim session a new origin, i.e. empty localStorage.
---
--- The file is re-read when it changed on disk and writes merge into it, so
--- several Neovim instances share one set of preferences without clobbering
--- each other. Main loop only.

local uv = vim.uv

local M = {}

local BOOL = { ['0'] = true, ['1'] = true }
local CORNER = { tl = true, tr = true, bl = true, br = true }

--- key -> allowed values. The file is user-editable and its values land in
--- the page, so anything outside this table is dropped, never shipped.
M.SCHEMA = {
  theme = { auto = true, light = true, dark = true },
  style = { github = true, obsidian = true },
  wide = BOOL,
  outline = BOOL,
  follow = BOOL,
  syncback = BOOL,
  fab = CORNER,
  toc = CORNER,
}

-- Keys written by earlier releases (localStorage names), read on load.
local LEGACY = {
  ['mdpv-theme'] = 'theme',
  ['mdpv-wide'] = 'wide',
  ['mdpv-outline'] = 'outline',
  ['mdpv-follow'] = 'follow',
  ['mdpv-sync-back'] = 'syncback',
  ['mdpv-fab-corner'] = 'fab',
  ['mdpv-toc-corner'] = 'toc',
}

local cache = {} ---@type table<string, string>
local cache_stamp ---@type string? mtime+size of the file the cache came from

function M.path()
  return vim.fs.joinpath(vim.fn.stdpath('state'), 'mdpv-prefs.json')
end

---@return table<string, string> only known keys with allowed values
function M.sanitize(t)
  local out = {}
  if type(t) ~= 'table' then
    return out
  end
  for key, value in pairs(t) do
    key = LEGACY[key] or key
    local allowed = M.SCHEMA[key]
    if allowed and type(value) == 'string' and allowed[value] and out[key] == nil then
      out[key] = value
    end
  end
  return out
end

local function stamp(path)
  local st = uv.fs_stat(path)
  return st and ('%d.%d:%d'):format(st.mtime.sec, st.mtime.nsec, st.size) or nil
end

--- Current preferences, re-read if the file changed since the last read.
---@return table<string, string>
function M.get()
  local path = M.path()
  local s = stamp(path)
  if s ~= cache_stamp then
    cache_stamp = s
    cache = {}
    local f = s and io.open(path, 'r')
    if f then
      local ok, t = pcall(vim.json.decode, f:read('*a'))
      f:close()
      cache = M.sanitize(ok and t)
    end
  end
  return cache
end

--- Merge `changes` (sanitized first) into the stored set and persist it.
---@return table<string, string>? changed the keys that actually changed, or nil
function M.set(changes)
  local current = M.get()
  local changed
  for key, value in pairs(M.sanitize(changes)) do
    if current[key] ~= value then
      current[key] = value
      changed = changed or {}
      changed[key] = value
    end
  end
  if not changed then
    return nil
  end
  local path = M.path()
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  -- Write-then-rename: a concurrent reader never sees a half-written file.
  local tmp = ('%s.%d.tmp'):format(path, uv.os_getpid())
  local f = io.open(tmp, 'w')
  if f then
    f:write(vim.json.encode(current, { sort_keys = true }))
    f:close()
    if uv.fs_rename(tmp, path) then
      cache_stamp = stamp(path)
    else
      os.remove(tmp)
    end
  end
  return changed -- an unwritable state dir still applies the change for this session
end

--- Effective values (stored, else defaults derived from `config`).
---@param config mdpv.Config
---@return table<string, string>
function M.resolve(config)
  local p = M.get()
  return {
    theme = p.theme or config.theme,
    style = p.style or config.style,
    wide = p.wide or '0',
    outline = p.outline or '1',
    follow = p.follow or '1',
    syncback = p.syncback or (config.scroll_sync == 'both' and '1' or '0'),
    fab = p.fab or 'br',
    toc = p.toc or 'tr',
  }
end

return M
