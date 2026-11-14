-- In-page interaction test: drives headless Chromium via the DevTools
-- protocol (tests/cdp.js) against a live preview with real, trusted input:
--   click checkbox -> POST /sync -> buffer line flips -> SSE re-render
--   confirms the checked state back in the page;
--   double-click a block -> the cursor jumps to its exact source line;
--   keyboard layer (theme and style cycling persisted, heading steps, shortcut card);
--   follow_buffer: the open tab switches documents with the buffer.
--
--   nvim --clean --headless -l tests/interact.lua
--
-- Requires chromium (or MDPV_CHROME) and node 22+ (built-in WebSocket).

local script = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(script, ':p')))
vim.opt.runtimepath:prepend(root)

-- Page preferences persist to stdpath('state'); point that at a throwaway
-- directory so the user's real prefs can't steer the page under test.
vim.env.XDG_STATE_HOME = vim.fn.tempname()

local chrome = os.getenv('MDPV_CHROME') or 'chromium'
if vim.fn.executable(chrome) == 0 then
  print('SKIP: no chromium found (set MDPV_CHROME)')
  os.exit(0)
end
if vim.fn.executable('node') == 0 then
  print('SKIP: no node found')
  os.exit(0)
end

local failures, passes = {}, 0
local function check(name, cond, detail)
  if cond then
    passes = passes + 1
    print('  ok  ' .. name)
  else
    failures[#failures + 1] = name
    print('FAIL  ' .. name .. (detail and (' -- ' .. tostring(detail)) or ''))
  end
end

require('mdpv').setup({ open_browser = false, debounce = 50 })
vim.cmd.edit(root .. '/tests/fixtures/sample.md')
local buf = vim.api.nvim_get_current_buf()
local url = assert(require('mdpv').open(0), 'preview failed to open')

-- The first unchecked task in the fixture — the checkbox cdp.js will click.
local task_line
for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if l:find('%[ %]') then
    task_line = i
    break
  end
end
check('fixture has an unchecked task', task_line ~= nil)

local out, done, res = '', false, nil
vim.system({ 'node', root .. '/tests/cdp.js', 'toggle-task', url }, {
  text = true,
  stdout = function(_, data)
    if data then
      out = out .. data
    end
  end,
}, function(r)
  res = r
  done = true
end)

check(
  'checkbox clicked in the page',
  vim.wait(20000, function()
    return out:find('CLICKED', 1, true) ~= nil
  end, 50),
  out
)
local clicked_line = tonumber(out:match('CLICKED (%d+)'))
check('clicked checkbox maps to the fixture task line', clicked_line == task_line, clicked_line)
check(
  'click flipped the buffer line to [x]',
  vim.wait(5000, function()
    return (vim.api.nvim_buf_get_lines(buf, task_line - 1, task_line, false)[1] or ''):find('%[x%]') ~= nil
  end, 50)
)
vim.wait(20000, function()
  return done
end, 50)
check('page saw the checked state come back (SYNCED)', res and res.code == 0, out)

vim.bo[buf].modifiable = false
local readonly_out, readonly_done, readonly_res = '', false, nil
vim.system({ 'node', root .. '/tests/cdp.js', 'readonly-task', url }, {
  text = true,
  stdout = function(_, data)
    if data then
      readonly_out = readonly_out .. data
    end
  end,
}, function(r)
  readonly_res = r
  readonly_done = true
end)
check(
  'read-only preview disables task checkboxes in the browser',
  vim.wait(20000, function()
    return readonly_out:find('READONLY', 1, true) ~= nil
  end, 50),
  readonly_out
)
vim.wait(20000, function()
  return readonly_done
end, 50)
check('read-only checkbox driver completed', readonly_res and readonly_res.code == 0, readonly_out)

vim.bo[buf].modifiable = true

--- Run a tests/cdp.js mode against `page`; returns the output so far
--- through saw(marker), and the final result through finish().
local function drive(mode, page)
  local o, finished, r = '', false, nil
  vim.system({ 'node', root .. '/tests/cdp.js', mode, page }, {
    text = true,
    stdout = function(_, data)
      if data then
        o = o .. data
      end
    end,
  }, function(x)
    r = x
    finished = true
  end)
  return {
    saw = function(marker)
      return vim.wait(20000, function()
        return o:find(marker, 1, true) ~= nil
      end, 50)
    end,
    finish = function()
      vim.wait(20000, function()
        return finished
      end, 50)
      return r and r.code == 0, o
    end,
  }
end

-- --- Jump to source: double-click a block, the cursor lands on its line -------

vim.api.nvim_win_set_cursor(0, { 1, 0 })
local jump = drive('jump', url)
check('double-click sent from the page', jump.saw('JUMPED'))
local _, jump_out = jump.finish()
local jumped_line = tonumber(jump_out:match('JUMPED (%d+)'))
check(
  'cursor jumped to the double-clicked block',
  vim.wait(3000, function()
    return vim.api.nvim_win_get_cursor(0)[1] == jumped_line
  end, 50),
  ('cursor %d, block %s'):format(vim.api.nvim_win_get_cursor(0)[1], jumped_line)
)

-- --- Code edits arrive highlighted -------------------------------------------------

local greet_line
for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if l == 'local function greet(name)' then
    greet_line = i
    break
  end
end
local edit = drive('edit-code', url)
check('code block highlighted', edit.saw('READY'))
vim.api.nvim_buf_set_lines(buf, greet_line, greet_line, false, { "  local edited = 'yes'" })
local edit_ok, edit_out = edit.finish()
check('edited code arrives highlighted, never plain', edit_ok and edit_out:find('CLEAN HIGHLIGHTED', 1, true), edit_out)
vim.api.nvim_buf_set_lines(buf, greet_line, greet_line + 1, false, {})

-- --- Keyboard layer ----------------------------------------------------------------

local keys = drive('keys', url)
local keys_ok, keys_out = keys.finish()
check('t cycles the theme', keys_out:find('THEME light', 1, true) ~= nil, keys_out)
check(
  'theme choice persisted by the editor',
  vim.wait(2000, function()
    return require('mdpv.prefs').get().theme == 'light'
  end, 20)
)
check('s cycles the style', keys_out:find('STYLE obsidian', 1, true) ~= nil, keys_out)
check(
  'style choice persisted by the editor',
  vim.wait(2000, function()
    return require('mdpv.prefs').get().style == 'obsidian'
  end, 20)
)
check(']] jumps to a heading', keys_out:find('HEADING #', 1, true) ~= nil, keys_out)
check('? opens the shortcut card', keys_ok and keys_out:find('HELP', 1, true) ~= nil, keys_out)
require('mdpv').stop()

-- --- follow_buffer: the open tab switches documents with the buffer ---------------

require('mdpv').setup({ open_browser = false, debounce = 50, follow_buffer = true })
local follow_url = assert(require('mdpv').open(0), 'follower failed to open')
local follow = drive('follow', follow_url)
check('follower page loaded', follow.saw('LOADED'))
vim.cmd.edit(root .. '/tests/fixtures/second.md')
local follow_ok, follow_out = follow.finish()
check(
  'the same tab re-rendered the entered buffer',
  follow_ok and follow_out:find('SWITCHED second.md', 1, true) ~= nil,
  follow_out
)

require('mdpv').stop()
print(('\n%d passed, %d failed'):format(passes, #failures))
if #failures > 0 then
  print('failed: ' .. table.concat(failures, ', '))
  os.exit(1)
end
