// Compile starry-night's grammars for the page, once, at vendor time:
//
//   lang/<scope>.json  each listed grammar and every grammar it embeds, as
//                      plain JSON (fetched and parsed as data, no module
//                      evaluation); lookup-only fields dropped
//   index.json         the shipped scopes, and fence flag -> scope (names,
//                      extensions): the tables starry-night's flagToScope reads
//   NOTICE, LICENSE    the license notices of the shipped grammars, and
//                      starry-night's own license
//
//   node scripts/grammars.mjs <starry-night package dir> <outdir> <scope>...

import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [pkg, outDir, ...roots] = process.argv.slice(2);
if (!pkg || !outDir || roots.length === 0) {
  console.error('usage: node scripts/grammars.mjs <package dir> <outdir> <scope>...');
  process.exit(2);
}

const file = (scope) => path.join(pkg, 'lang', `${scope}.js`);
const grammars = new Map();

async function add(scope) {
  if (grammars.has(scope) || !fs.existsSync(file(scope))) return; // embeds starry-night doesn't ship stay plain
  grammars.set(scope, null);
  const grammar = (await import(pathToFileURL(file(scope)).href)).default;
  grammars.set(scope, grammar);
  for (const dep of grammar.dependencies || []) await add(dep);
}

for (const scope of roots) {
  if (!fs.existsSync(file(scope))) throw new Error(`unknown grammar: ${scope}`);
  await add(scope);
}

const scopes = [...grammars.keys()].sort(); // registration order, as in starry-night's `all`
const index = { scopes, names: {}, extensions: {}, extensionsWithDot: {} };
fs.mkdirSync(path.join(outDir, 'lang'), { recursive: true });
for (const scope of scopes) {
  const { names, extensions, extensionsWithDot, dependencies, ...raw } = grammars.get(scope);
  for (const name of names) index.names[name] = scope;
  for (const ext of extensions) index.extensions[ext] = scope;
  for (const ext of extensionsWithDot || []) index.extensionsWithDot[ext] = scope;
  fs.writeFileSync(path.join(outDir, 'lang', `${scope}.json`), JSON.stringify(raw));
}
fs.writeFileSync(path.join(outDir, 'index.json'), `${JSON.stringify(index)}\n`);

// NOTICE: the preamble plus the sections naming a shipped grammar.
const RULE = /^={20,}$/m;
const [preamble, ...sections] = fs.readFileSync(path.join(pkg, 'notice'), 'utf8').split(RULE);
const shipped = new Set(scopes.map((scope) => `lang/${scope}.js`));
const kept = sections.filter((section) => {
  const files = /^Files in `starry-night`: (.+)$/m.exec(section)?.[1].split(/,\s*/) || [];
  return files.some((f) => shipped.has(f.trim()));
});
const rule = '='.repeat(80);
fs.writeFileSync(path.join(outDir, 'NOTICE'), [preamble.trimEnd(), ...kept.map((s) => s.trim())].join(`\n${rule}\n`) + '\n');
fs.copyFileSync(path.join(pkg, 'license'), path.join(outDir, 'LICENSE'));

console.log(`  ${grammars.size} grammars from ${roots.length} languages, ${kept.length} notices`);
