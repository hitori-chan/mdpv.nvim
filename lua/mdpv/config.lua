---@brief Configuration: defaults, schema validation, and the active config.

local M = {}

---@class mdpv.Config
---@field host string interface to bind; keep loopback unless you know why
---@field port integer 0 = pick a free ephemeral port
---@field theme 'auto'|'light'|'dark' initial color scheme (the page's picker overrides it)
---@field style 'github'|'obsidian' initial content style (the page's picker overrides it)
---@field debounce integer ms of quiet time before pushing an edit to the browser
---@field filetypes string[] buffers eligible without :Preview! force
---@field follow_buffer boolean one shared preview tab that follows the current buffer
---@field auto_close boolean close a preview when its buffer is unloaded
---@field auto_stop boolean stop the server when the last preview closes
---@field open_browser boolean|string[]|fun(url: string) how to open the URL (false: just print it)
---@field math boolean|table KaTeX; a table passes options through, e.g. { macros = { ... } }
---@field mermaid boolean
---@field emoji boolean
---@field reload_images boolean refresh images in open previews when they change on disk
---@field scroll_sync boolean|'both' false | true (page follows cursor) | 'both' (+ page scroll moves cursor)

---@type mdpv.Config
M.defaults = {
  host = '127.0.0.1',
  port = 0,
  theme = 'auto',
  style = 'github',
  debounce = 150,
  filetypes = { 'markdown' },
  follow_buffer = false,
  auto_close = true,
  auto_stop = true,
  open_browser = true,
  math = true,
  mermaid = true,
  emoji = true,
  reload_images = true,
  scroll_sync = true,
}

local function boolean(v)
  return type(v) == 'boolean'
end

local function list_of_strings(v)
  if not vim.islist(v) then
    return false
  end
  for _, s in ipairs(v) do
    if type(s) ~= 'string' then
      return false
    end
  end
  return true
end

local function integer(min, max)
  return function(v)
    return type(v) == 'number' and v % 1 == 0 and v >= min and v <= max
  end
end

--- key -> { predicate, what a valid value looks like }
local SCHEMA = {
  host = {
    function(v)
      return type(v) == 'string' and v ~= ''
    end,
    'a non-empty hostname or address',
  },
  port = { integer(0, 65535), 'an integer between 0 and 65535' },
  theme = {
    function(v)
      return v == 'auto' or v == 'light' or v == 'dark'
    end,
    "'auto', 'light' or 'dark'",
  },
  style = {
    function(v)
      return v == 'github' or v == 'obsidian'
    end,
    "'github' or 'obsidian'",
  },
  debounce = { integer(0, math.huge), 'a non-negative integer' },
  filetypes = { list_of_strings, 'a list of filetype strings' },
  follow_buffer = { boolean, 'a boolean' },
  auto_close = { boolean, 'a boolean' },
  auto_stop = { boolean, 'a boolean' },
  open_browser = {
    function(v)
      return type(v) == 'boolean' or vim.is_callable(v) or (list_of_strings(v) and #v > 0)
    end,
    "a boolean, a command list like { 'firefox', '--new-window' }, or a function(url)",
  },
  math = {
    function(v)
      return type(v) == 'boolean' or (type(v) == 'table' and (pcall(vim.json.encode, v)))
    end,
    "a boolean or a JSON-serializable table of KaTeX options like { macros = { ['\\\\RR'] = '\\\\mathbb{R}' } }",
  },
  mermaid = { boolean, 'a boolean' },
  emoji = { boolean, 'a boolean' },
  reload_images = { boolean, 'a boolean' },
  scroll_sync = {
    function(v)
      return v == true or v == false or v == 'both'
    end,
    "true, false or 'both'",
  },
}

---@type mdpv.Config
M.current = vim.deepcopy(M.defaults)

--- Merge `opts` over the defaults and validate the result. Options are flat,
--- so the merge is shallow: a table value (filetypes, math, open_browser)
--- replaces the default instead of being merged index by index.
---@param opts table?
---@return mdpv.Config
function M.resolve(opts)
  vim.validate('opts', opts, 'table', true)
  opts = opts or {}
  local unknown = {}
  for key in pairs(opts) do
    if SCHEMA[key] == nil then
      unknown[#unknown + 1] = tostring(key)
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    vim.notify('mdpv: ignoring unknown option(s): ' .. table.concat(unknown, ', '), vim.log.levels.WARN)
  end
  local config = vim.deepcopy(M.defaults)
  for key in pairs(SCHEMA) do
    if opts[key] ~= nil then
      config[key] = opts[key]
    end
  end
  for key, rule in vim.spairs(SCHEMA) do
    vim.validate('config.' .. key, config[key], rule[1], rule[2])
  end
  return config
end

--- Whether `bufnr`'s filetype is in config.filetypes. Compound filetypes
--- ('markdown.pandoc') match on any of their parts.
---@param bufnr integer
---@param config mdpv.Config
function M.eligible(bufnr, config)
  local filetype = vim.bo[bufnr].filetype
  for part in filetype:gmatch('[^.]+') do
    if vim.list_contains(config.filetypes, part) then
      return true
    end
  end
  return false
end

--- Renderer feature flags shipped to the page.
---@param config mdpv.Config
function M.features(config)
  return {
    math = config.math, -- false | true | KaTeX options
    mermaid = config.mermaid,
    emoji = config.emoji,
    scrollSync = config.scroll_sync, -- false | true | 'both'
  }
end

return M
