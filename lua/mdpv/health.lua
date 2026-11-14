local M = {}

function M.check()
  local health = vim.health
  health.start('mdpv.nvim')

  if vim.fn.has('nvim-0.12') == 1 then
    health.ok(('Neovim %s'):format(tostring(vim.version())))
  else
    health.error('Neovim 0.12+ required')
  end

  local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h') .. '/assets/'
  local missing = {}
  for _, rel in ipairs({
    'index.html',
    'mdpv.css',
    'obsidian.css',
    'favicon.svg',
    'js/main.js',
    'js/render.js',
    'js/typeset.js',
    'js/ui.js',
    'js/outline.js',
    'js/sync.js',
    'js/util.js',
    'js/icons.js',
    'vendor/markdown-it.min.js',
    'vendor/markdown-it-task-lists.min.js',
    'vendor/markdown-it-footnote.min.js',
    'vendor/markdown-it-emoji.min.js',
    'vendor/markdown-it-mark.min.js',
    'vendor/purify.min.js',
    'vendor/morphdom-umd.min.js',
    'vendor/starry-night/index.json',
    'vendor/starry-night/parse.js',
    'vendor/starry-night/theme.js',
    'vendor/starry-night/vscode-textmate.js',
    'vendor/starry-night/vscode-oniguruma.js',
    'vendor/starry-night/onig.wasm',
    'vendor/starry-night/lang/source.lua.json',
    'vendor/github-markdown.css',
    'vendor/mermaid.min.js',
    'vendor/katex/katex.min.js',
    'vendor/katex/katex.min.css',
    'vendor/katex/fonts/KaTeX_Main-Regular.woff2',
  }) do
    if not vim.uv.fs_stat(root .. rel) then
      missing[#missing + 1] = rel
    end
  end
  if #missing == 0 then
    health.ok('frontend assets present')
  else
    health.error('missing assets: ' .. table.concat(missing, ', '), 'reinstall the plugin')
  end

  local opener = require('mdpv').config.open_browser
  if opener == true then
    health.ok('browser opener: vim.ui.open()')
  elseif opener == false then
    health.info('open_browser = false: preview URLs are only printed')
  else
    health.ok('browser opener: custom (config.open_browser)')
  end

  local prefs = require('mdpv.prefs')
  health.info('page preferences: ' .. prefs.path())

  local server = package.loaded['mdpv.server']
  if server and server.is_running() then
    local info = server.info()
    health.ok(
      ('server on %s:%d (%d preview%s)'):format(info.host, info.port, info.previews, info.previews == 1 and '' or 's')
    )
  else
    health.info('server not running (starts on the first :Preview)')
  end
end

return M
