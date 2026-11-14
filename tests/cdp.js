// Minimal Chrome DevTools Protocol driver for the browser suites — no deps
// (uses Node's built-in WebSocket, Node 22+).
//
//   node tests/cdp.js watch-scroll <url>   print LOADED, then poll until the
//                                          page scrolls (editor -> browser);
//                                          prints SCROLLED <y> and exits 0.
//   node tests/cdp.js user-scroll <url>    print LOADED, wait out the page's
//                                          programmatic-scroll suppression,
//                                          then scroll like a user would
//                                          (browser -> editor); prints
//                                          SCROLLED <y> and exits 0.
//   node tests/cdp.js jump <url>           print LOADED, double-click the
//                                          "Table" heading (prints JUMPED
//                                          <line>) and exit 0.
//   node tests/cdp.js keys <url>           print LOADED, then drive the
//                                          keyboard layer: t (THEME), s
//                                          (STYLE), ]] (HEADING), ? (HELP).
//   node tests/cdp.js follow <url>         print LOADED, wait for the page to
//                                          switch to second.md (SWITCHED).
//   node tests/cdp.js dump <url>           print LOADED, wait for the lazy
//                                          typesetting (code, math, diagrams)
//                                          to settle, print the DOM, exit 0.
//   node tests/cdp.js edit-code <url>      print READY once the Lua block is
//                                          highlighted; after the Lua side
//                                          edits it, print CLEAN (or FLASH if
//                                          it ever showed unhighlighted).
//   node tests/cdp.js toggle-task <url>    print LOADED, click the first
//                                          unchecked task checkbox with a
//                                          trusted click (prints CLICKED
//                                          <line>), then wait for the editor's
//                                          re-render to confirm the checked
//                                          state (prints SYNCED) and exit 0.
//
// Exits non-zero on any timeout. Chromium binary from $MDPV_CHROME.
'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const [mode, url] = process.argv.slice(2);
const chrome = process.env.MDPV_CHROME || 'chromium';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'mdpv-cdp-'));
const proc = spawn(chrome, [
  '--headless=new',
  '--no-sandbox', // CI runners (Ubuntu 24.04+) forbid the user-namespace sandbox
  '--disable-gpu',
  '--user-data-dir=' + profile,
  '--window-size=1100,800',
  '--remote-debugging-port=0',
  url,
], { stdio: ['ignore', 'ignore', 'pipe'], detached: true }); // own process group

// Chrome's helpers (the network service) outlive the browser process and
// write into the profile on the way out, so kill the whole group and wait
// for it to be gone before removing the profile.
const groupAlive = () => {
  try {
    process.kill(-proc.pid, 0);
    return true;
  } catch {
    return false;
  }
};
let dying = false;
const die = (msg, code) => {
  if (dying) return;
  dying = true;
  if (msg) console.error(msg);
  try {
    process.kill(-proc.pid, 'SIGKILL');
  } catch {}
  const deadline = Date.now() + 3000;
  const finish = () => {
    if (groupAlive() && Date.now() < deadline) return setTimeout(finish, 20);
    try {
      fs.rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    } catch {} // cleanup never decides the exit code
    process.exit(code);
  };
  finish();
};
setTimeout(() => die('TIMEOUT: overall', 3), 30000).unref();

let stderr = '';
proc.stderr.on('data', (d) => {
  stderr += d;
  const m = stderr.match(/DevTools listening on (ws:\/\/\S+)/);
  if (m) {
    stderr = ''; // stop matching
    run(m[1]).catch((e) => die('ERROR: ' + e.message, 2));
  }
});
proc.on('exit', (code, signal) => die(`ERROR: chromium exited (${code ?? signal})\n${stderr.trim()}`, 2));

async function run(wsUrl) {
  const ws = new WebSocket(wsUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });

  let msgId = 0;
  const pending = new Map();
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) {
      pending.get(m.id)(m);
      pending.delete(m.id);
    }
  };
  const send = (method, params, sessionId) => new Promise((res) => {
    const id = ++msgId;
    pending.set(id, res);
    ws.send(JSON.stringify({ id, method, params: params || {}, sessionId }));
  });

  // Attach to the page target.
  let targetId;
  for (let i = 0; i < 100 && !targetId; i++) {
    const r = await send('Target.getTargets');
    targetId = r.result.targetInfos.find((t) => t.type === 'page')?.targetId;
    if (!targetId) await sleep(100);
  }
  if (!targetId) return die('TIMEOUT: no page target', 3);
  const attach = await send('Target.attachToTarget', { targetId, flatten: true });
  const sid = attach.result.sessionId;
  const evaluate = async (expression) =>
    (await send('Runtime.evaluate', { expression, returnByValue: true }, sid)).result.result?.value;

  // Wait for the preview to render (source-line map present = main.js ran).
  let ready = false;
  for (let i = 0; i < 100 && !ready; i++) {
    ready = await evaluate(
      "document.readyState === 'complete' && document.querySelectorAll('#content [data-source-line]').length > 0",
    );
    if (!ready) await sleep(100);
  }
  if (!ready) return die('TIMEOUT: page never rendered', 3);
  console.log('LOADED');

  if (mode === 'dump') {
    // Like --dump-dom, but on a condition instead of a guess at when the page
    // is done (headless --dump-dom stalls lazy loads after the load event).
    const selector = [
      '#content pre > code[class*="language-"]:not(.mdpv-hl)',
      '#content .mdpv-math:not(.mdpv-typeset)',
      '#content .mdpv-mermaid:not(.mdpv-typeset)',
    ].join(', ');
    const pending = `document.querySelector(${JSON.stringify(selector)}) !== null`;
    for (let i = 0; i < 150 && (await evaluate(pending)) !== false; i++) await sleep(100);
    const html = await evaluate('document.documentElement.outerHTML');
    return process.stdout.write(`${html}\n`, () => die('', 0));
  }

  if (mode === 'watch-scroll') {
    // Editor -> browser: the Lua side moves the cursor once it sees LOADED;
    // wait for the resulting smooth scroll to land.
    let scrolled = false;
    for (let i = 0; i < 100 && !scrolled; i++) {
      const y = await evaluate('window.scrollY');
      if (y > 200) {
        console.log('SCROLLED ' + Math.round(y));
        scrolled = true;
      } else {
        await sleep(100);
      }
    }
    if (!scrolled) return die('TIMEOUT: page never scrolled', 1);
    // The block under the cursor should carry the indicator class; print
    // whether it sits in the main text or the footnotes.
    for (let i = 0; i < 50; i++) {
      const where = await evaluate(
        "(el => el && (el.closest('.footnotes') ? 'footnotes' : 'body'))(document.querySelector('#content .mdpv-cursor'))",
      );
      if (where) {
        console.log('MARKED ' + where);
        break;
      }
      await sleep(100);
    }
    // The Lua side now parks the cursor on the '### Footnotes' heading line;
    // the URL hash should follow.
    for (let i = 0; i < 100; i++) {
      const hash = await evaluate('location.hash');
      if (hash === '#footnotes') {
        console.log('HASH ' + hash);
        return die('', 0);
      }
      await sleep(100);
    }
    return die('TIMEOUT: hash never followed the heading', 1);
  }

  if (mode === 'toggle-task') {
    // Click like a user (trusted event); the page POSTs the toggle, the
    // editor flips the source line, and the SSE re-render arrives with the
    // checkbox now checked in markup (a `checked` attribute, not just the
    // click's transient property).
    const info = await evaluate(`(() => {
      const box = document.querySelector('#content input.task-list-item-checkbox:not([checked])');
      if (!box || box.disabled) return null;
      box.scrollIntoView({ block: 'center', behavior: 'instant' });
      const r = box.getBoundingClientRect();
      return { x: r.x + r.width / 2, y: r.y + r.height / 2,
               line: +box.closest('[data-source-line]').dataset.sourceLine };
    })()`);
    if (!info) return die('FAIL: no enabled unchecked task checkbox', 1);
    await send('Input.dispatchMouseEvent',
      { type: 'mousePressed', x: info.x, y: info.y, button: 'left', clickCount: 1 }, sid);
    await send('Input.dispatchMouseEvent',
      { type: 'mouseReleased', x: info.x, y: info.y, button: 'left', clickCount: 1 }, sid);
    console.log('CLICKED ' + info.line);
    for (let i = 0; i < 100; i++) {
      const synced = await evaluate(
        `!!document.querySelector('#content [data-source-line="${info.line}"] input.task-list-item-checkbox[checked]')`,
      );
      if (synced) {
        console.log('SYNCED');
        return die('', 0);
      }
      await sleep(100);
    }
    return die('TIMEOUT: checkbox state never came back from the editor', 1);
  }

  if (mode === 'readonly-task') {
    for (let i = 0; i < 100; i++) {
      const disabled = await evaluate(
        '!!document.querySelector("#content input.task-list-item-checkbox:disabled")',
      );
      if (disabled) {
        console.log('READONLY');
        return die('', 0);
      }
      await sleep(100);
    }
    return die('TIMEOUT: read-only checkbox was enabled', 1);
  }

  if (mode === 'user-scroll') {
    // Browser -> editor: scroll like a user; the page should POST the line.
    await sleep(1500); // clear any programmatic-scroll suppression window
    await evaluate("window.scrollTo({ top: document.body.scrollHeight, behavior: 'instant' })");
    await sleep(600); // > the 150 ms send debounce
    const y = await evaluate('window.scrollY');
    console.log('SCROLLED ' + Math.round(y));
    return die('', y > 0 ? 0 : 1);
  }

  const press = async (key) => {
    for (const type of ['keyDown', 'keyUp']) {
      await send('Input.dispatchKeyEvent', { type, key, text: type === 'keyDown' ? key : undefined }, sid);
    }
  };
  const until = async (expr, ms = 5000) => {
    for (let i = 0; i < ms / 100; i++) {
      const v = await evaluate(expr);
      if (v) return v;
      await sleep(100);
    }
    return null;
  };

  if (mode === 'jump') {
    // Jump to source: a trusted double-click on a block POSTs its line;
    // the Lua side checks where the cursor landed.
    const info = await evaluate(`(() => {
      const h = [...document.querySelectorAll('#content h3')].find((e) => e.textContent.trim() === 'Table');
      h.scrollIntoView({ block: 'center', behavior: 'instant' });
      const r = h.getBoundingClientRect();
      return { x: r.x + 40, y: r.y + r.height / 2, line: +h.dataset.sourceLine };
    })()`);
    for (const clickCount of [1, 2]) {
      for (const type of ['mousePressed', 'mouseReleased']) {
        await send('Input.dispatchMouseEvent', { type, x: info.x, y: info.y, button: 'left', clickCount }, sid);
      }
    }
    console.log('JUMPED ' + info.line);
    return die('', 0);
  }

  if (mode === 'keys') {
    // Keyboard layer: t cycles the theme and s the style (both persisted),
    // ]] steps to a heading, ? opens the shortcut card.
    await press('t');
    const theme = await until("document.documentElement.dataset.theme === 'light' && 'light'");
    if (!theme) return die('FAIL: t did not cycle the theme', 1);
    console.log('THEME ' + theme);
    await press('s');
    // The style sheet applies: Obsidian drops the card border.
    const style = await until(
      "document.documentElement.dataset.style === 'obsidian' && " +
        "getComputedStyle(document.querySelector('.markdown-body')).borderTopColor === 'rgba(0, 0, 0, 0)' && 'obsidian'",
    );
    if (!style) return die('FAIL: s did not cycle the style', 1);
    console.log('STYLE ' + style);
    await press(']');
    await press(']');
    const hash = await until("location.hash.length > 1 && scrollY > 0 && location.hash");
    if (!hash) return die('FAIL: ]] did not move to a heading', 1);
    console.log('HEADING ' + hash);
    await press('?');
    if (!(await until("document.getElementById('mdpv-keys').matches(':popover-open')"))) {
      return die('FAIL: ? did not open the shortcut card', 1);
    }
    console.log('HELP');
    return die('', 0);
  }

  if (mode === 'edit-code') {
    // Code highlights inside the render pass: once Lua is ready, the line the
    // Lua side inserts must never be on screen unhighlighted. A
    // MutationObserver sees every intermediate state the diff leaves.
    const ready = await until("document.querySelector('#content code.language-lua .pl-k') !== null", 10000);
    if (!ready) return die('TIMEOUT: code never highlighted', 1);
    await evaluate(`(() => {
      window.mdpvFlash = false;
      const highlighted = (c) => [...c.querySelectorAll('.pl-s')].some((s) => s.textContent === "'yes'");
      new MutationObserver(() => {
        const c = document.querySelector('#content code.language-lua');
        if (c && c.textContent.includes("'yes'") && !highlighted(c)) window.mdpvFlash = true;
      }).observe(document.getElementById('content'), { subtree: true, childList: true, characterData: true });
    })()`);
    console.log('READY');
    const seen = await until("document.querySelector('#content code.language-lua')?.textContent.includes(\"'yes'\")", 10000);
    if (!seen) return die('TIMEOUT: the edit never arrived', 1);
    await sleep(300);
    console.log(((await evaluate('window.mdpvFlash')) ? 'FLASH' : 'CLEAN') + ' HIGHLIGHTED');
    return die('', 0);
  }

  if (mode === 'follow') {
    // follow_buffer: the Lua side switches buffers after LOADED; the same
    // tab must re-render the other document.
    const ok = await until("document.querySelector('#content h1')?.textContent.includes('Second Document')", 10000);
    if (!ok) return die('TIMEOUT: page never switched documents', 1);
    console.log('SWITCHED ' + (await evaluate('document.title')));
    return die('', 0);
  }

  return die('ERROR: unknown mode ' + mode, 2);
}
