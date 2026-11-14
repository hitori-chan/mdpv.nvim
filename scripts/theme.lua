-- Fold github-markdown-css's light and dark builds into one stylesheet that
-- follows the page's color-scheme through light-dark(). The page then
-- switches theme by flipping one attribute on <html> (mdpv.css maps it to
-- color-scheme) instead of swapping stylesheets: no network, no flash, no
-- per-theme files.
--
--   nvim -l scripts/theme.lua <github-markdown.css> <outdir>
--
-- Writes <outdir>/github-markdown.css.

local md_in, outdir = unpack(_G.arg)
assert(md_in and outdir, 'usage: theme.lua <github-markdown.css> <outdir>')

local function read(path)
  local f = assert(io.open(path, 'rb'))
  local s = f:read('*a')
  f:close()
  return s
end

local function write(path, s)
  local f = assert(io.open(path, 'wb'))
  f:write(s)
  f:close()
end

--- Body of the brace block whose '{' sits at `open`, plus the index past it.
local function block(s, open)
  local depth = 0
  for i = open, #s do
    local c = s:sub(i, i)
    if c == '{' then
      depth = depth + 1
    elseif c == '}' then
      depth = depth - 1
      if depth == 0 then
        return s:sub(open + 1, i - 1), i + 1
      end
    end
  end
  error('unbalanced braces')
end

local function blend(light, dark)
  return light == dark and light or ('light-dark(%s, %s)'):format(light, dark)
end

------------------------------------------------------------------------------
-- github-markdown-css: the auto build keeps every color in two
-- `@media (prefers-color-scheme: …) { .markdown-body, [data-theme] { --vars } }`
-- blocks; replace both with one block of light-dark() pairs.
------------------------------------------------------------------------------

local css = read(md_in)

local function scheme_vars(scheme)
  local at = css:find('@media (prefers-color-scheme: ' .. scheme .. ') {', 1, true)
  assert(at, 'no ' .. scheme .. ' block in ' .. md_in)
  local media, after = block(css, css:find('{', at, true))
  local inner = block(media, media:find('{', 1, true))
  local vars, order = {}, {}
  for name, value in inner:gmatch('(%-%-[%w%-_]+)%s*:%s*([^;]+);') do
    if not vars[name] then
      order[#order + 1] = name
    end
    vars[name] = vim.trim(value)
  end
  return vars, order, at, after
end

local dark, _, dark_at, dark_end = scheme_vars('dark')
local light, light_order, light_at, light_end = scheme_vars('light')
assert(light_at > dark_at and css:sub(dark_end, light_at - 1):match('^%s*$'), 'theme blocks are not adjacent')

local lines = { '.markdown-body {' }
local seen = {}
for _, name in ipairs(light_order) do
  seen[name] = true
  lines[#lines + 1] = ('  %s: %s;'):format(name, blend(light[name], dark[name] or light[name]))
end
for name, value in vim.spairs(dark) do
  if not seen[name] then
    lines[#lines + 1] = ('  %s: %s;'):format(name, value)
  end
end
lines[#lines + 1] = '}'

write(
  outdir .. '/github-markdown.css',
  '/* github-markdown-css, light + dark folded into light-dark() by scripts/theme.lua */\n'
    .. css:sub(1, dark_at - 1)
    .. table.concat(lines, '\n')
    .. css:sub(light_end)
)
