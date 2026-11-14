#!/usr/bin/env bash
# Re-download the pinned frontend dependencies into assets/vendor/.
# Bump the pins deliberately and re-run the test suites afterwards.
set -euo pipefail

MARKDOWN_IT=14.3.0
TASK_LISTS=2.1.1
FOOTNOTE=4.0.0
EMOJI=3.0.0
MARK=4.0.0
DOMPURIFY=3.4.11
STARRY_NIGHT=3.11.0
TEXTMATE=9.3.2
ONIGURUMA=2.0.1
GH_MD_CSS=5.9.0
KATEX=0.17.0
MERMAID=11.16.0
MORPHDOM=2.7.8

# Highlighted languages (starry-night scopes); embedded grammars come along.
GRAMMARS="
  source.c source.c++ source.cs source.css source.css.less source.css.scss
  source.diff source.go source.graphql source.ini source.java source.js
  source.json source.json.comments source.kotlin source.lua source.makefile
  source.objc source.perl source.python source.r source.ruby source.rust
  source.shell text.shell-session source.sql source.swift source.ts source.tsx
  source.vbnet source.yaml text.html.basic text.html.php text.md text.xml
  text.xml.svg source.viml text.vim-help source.toml source.dockerfile
  source.nix source.zig source.elixir source.erlang source.haskell
  source.scala source.dart text.tex.latex source.hcl source.proto source.cmake
  source.powershell source.batchfile source.fish source.nginx source.vue
  source.svelte source.astro source.ocaml source.clojure source.julia
  source.groovy source.gitignore source.gitconfig source.editorconfig
  source.jq source.just source.awk source.elm source.fsharp source.assembly
  source.regexp source.dotenv source.csv source.emacs.lisp source.scheme
  source.nim source.glsl source.webassembly source.prisma source.solidity
  source.gleam source.typst text.html.django
"

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/assets/vendor"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$dir"

fetch() { echo "  $2"; curl -fsSL -o "$2" "$1"; }

fetch "https://unpkg.com/markdown-it@$MARKDOWN_IT/dist/markdown-it.min.js" markdown-it.min.js
fetch "https://unpkg.com/markdown-it-task-lists@$TASK_LISTS/dist/markdown-it-task-lists.min.js" markdown-it-task-lists.min.js
fetch "https://unpkg.com/markdown-it-footnote@$FOOTNOTE/dist/markdown-it-footnote.min.js" markdown-it-footnote.min.js
fetch "https://unpkg.com/markdown-it-emoji@$EMOJI/dist/markdown-it-emoji.min.js" markdown-it-emoji.min.js
fetch "https://unpkg.com/markdown-it-mark@$MARK/dist/markdown-it-mark.min.js" markdown-it-mark.min.js
fetch "https://unpkg.com/dompurify@$DOMPURIFY/dist/purify.min.js" purify.min.js
fetch "https://unpkg.com/mermaid@$MERMAID/dist/mermaid.min.js" mermaid.min.js
fetch "https://unpkg.com/morphdom@$MORPHDOM/dist/morphdom-umd.min.js" morphdom-umd.min.js

# Theme: upstream keeps light and dark in two media blocks; scripts/theme.lua
# folds them into one light-dark() stylesheet the page switches by attribute.
echo "  github-markdown.css (folded light/dark)"
curl -fsSL -o "$tmp/gh.css" "https://unpkg.com/github-markdown-css@$GH_MD_CSS/github-markdown.css"
nvim --clean --headless -l "$root/scripts/theme.lua" "$tmp/gh.css" "$dir"

# Code highlighting: starry-night, GitHub's highlighter (the Linguist grammars,
# tokens as GitHub's pl-* classes). Its scope->class theme and tokenizer
# (lib/theme.js, lib/parse.js) run on the UMD builds of vscode-textmate and
# vscode-oniguruma. scripts/grammars.mjs (needs node) compiles the grammars
# below, and every grammar they embed, to JSON plus a fence-flag index.
echo "  starry-night/ (theme, tokenizer, vscode-textmate, oniguruma, grammars)"
rm -rf starry-night && mkdir -p starry-night
curl -fsSL "https://registry.npmjs.org/@wooorm/starry-night/-/starry-night-$STARRY_NIGHT.tgz" \
  | tar -xz -C "$tmp" package/lib package/lang package/notice package/license
cp "$tmp/package/lib/theme.js" "$tmp/package/lib/parse.js" starry-night/
fetch "https://unpkg.com/vscode-textmate@$TEXTMATE/release/main.js" starry-night/vscode-textmate.js
fetch "https://unpkg.com/vscode-oniguruma@$ONIGURUMA/release/main.js" starry-night/vscode-oniguruma.js
fetch "https://unpkg.com/vscode-oniguruma@$ONIGURUMA/release/onig.wasm" starry-night/onig.wasm
node "$root/scripts/grammars.mjs" "$tmp/package" starry-night $GRAMMARS

# KaTeX ships fonts referenced relatively from its CSS, so it gets its own
# subdirectory (only the woff2 fonts; every current browser uses those).
echo "  katex/ (js + css + woff2 fonts)"
rm -rf katex && mkdir -p katex
curl -fsSL "https://registry.npmjs.org/katex/-/katex-$KATEX.tgz" \
  | tar -xz -C katex --strip-components=2 --wildcards \
      package/dist/katex.min.js package/dist/katex.min.css 'package/dist/fonts/*.woff2'

{
  echo "Pinned vendor versions (refresh with scripts/vendor.sh):"
  echo "  markdown-it            $MARKDOWN_IT"
  echo "  markdown-it-task-lists $TASK_LISTS"
  echo "  markdown-it-footnote   $FOOTNOTE"
  echo "  markdown-it-emoji      $EMOJI"
  echo "  markdown-it-mark       $MARK"
  echo "  dompurify              $DOMPURIFY"
  echo "  starry-night           $STARRY_NIGHT ($(ls starry-night/lang | wc -l) grammars)"
  echo "  vscode-textmate        $TEXTMATE"
  echo "  vscode-oniguruma       $ONIGURUMA"
  echo "  github-markdown-css    $GH_MD_CSS"
  echo "  katex                  $KATEX"
  echo "  mermaid                $MERMAID"
  echo "  morphdom               $MORPHDOM"
} > VERSIONS.txt

echo "done."
