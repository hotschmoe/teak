#!/usr/bin/env node
// Web accessibility probe: serve a zunk `dist/`, load it in headless Chromium
// (software WebGPU), read the browser's accessibility tree through puppeteer
// (`page.accessibility.snapshot`), assert roles / names / values, and DRIVE the
// app purely through the DOM mirror (DOM click, DOM focus, typing into the
// mirrored textbox, setting its value like assistive technology does).
//
//   cd tools && npm ci
//   node tools/a11yprobe.mjs todo  examples/todo/dist
//   node tools/a11yprobe.mjs notes examples/notes/dist
//   node tools/a11yprobe.mjs dump  <dist>            # print the tree, no assertions
//        [--chrome /path] [--wait-ms 3500]
//
// Exit: 0 ok, 1 a check failed / page error, 2 usage. See docs/features/a11y.md.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import puppeteer from 'puppeteer-core';

const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };
const valueFlags = ['--chrome', '--wait-ms'];
const pos = argv.filter((a, i) => !a.startsWith('--') && !valueFlags.includes(argv[i - 1]));
if (pos.length < 2) { console.error('usage: a11yprobe.mjs <todo|notes|dump> <dist-dir> [--chrome PATH] [--wait-ms N]'); process.exit(2); }
const [scenario, distDir] = pos;
const root = path.resolve(distDir);
const waitMs = Number(opt('--wait-ms', 3500));

function findChrome() {
  const cands = [opt('--chrome'), process.env.CHROME_PATH];
  for (const name of ['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser']) {
    try { cands.push(execFileSync('which', [name], { encoding: 'utf8' }).trim()); } catch {}
  }
  return cands.find((c) => c && fs.existsSync(c));
}
const chrome = findChrome();
if (!chrome) { console.error('no Chrome/Chromium found (set CHROME_PATH or --chrome)'); process.exit(2); }

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.wasm': 'application/wasm', '.json': 'application/json', '.wgsl': 'text/plain', '.ttf': 'font/ttf' };
const server = http.createServer((req, res) => {
  let file;
  try { file = path.join(root, decodeURIComponent(new URL(req.url, 'http://x').pathname)); } catch { res.writeHead(400).end(); return; }
  if (!file.startsWith(root)) { res.writeHead(403).end(); return; }
  if (file === path.join(root, 'favicon.ico')) { res.writeHead(204).end(); return; }
  try {
    if (fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    fs.createReadStream(file).pipe(res);
  } catch { res.writeHead(404).end('not found'); }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}/`;

const browser = await puppeteer.launch({
  executablePath: chrome, headless: true, protocolTimeout: 120000,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--hide-scrollbars', '--window-size=1280,800', '--ignore-gpu-blocklist',
    '--enable-unsafe-webgpu', '--enable-webgpu-developer-features', '--enable-unsafe-swiftshader', '--enable-features=Vulkan,WebGPU',
    '--use-vulkan=swiftshader', '--use-webgpu-adapter=swiftshader', `--use-angle=${process.env.WEBSHOT_ANGLE || 'swiftshader'}`],
});

const failures = [];
const check = (cond, msg) => { if (!cond) { failures.push(msg); console.log(`  FAIL ${msg}`); } else console.log(`  ok   ${msg}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Flatten the browser accessibility tree into [{role, name, value, focused, checked, level, ...}]. */
async function tree(page) {
  const snap = await page.accessibility.snapshot({ interestingOnly: false });
  const out = [];
  const walk = (n, depth) => {
    out.push({ ...n, depth });
    for (const c of n.children || []) walk(c, depth + 1);
  };
  if (snap) walk(snap, 0);
  return out;
}
const find = (nodes, role, name) => nodes.find((n) => n.role === role && (name === undefined || n.name === name));
const dump = (nodes) => nodes.forEach((n) => {
  if (n.role === 'InlineTextBox') return;
  console.log(`${' '.repeat(n.depth * 2)}${n.role} "${n.name || ''}"${n.value !== undefined ? ` value=${JSON.stringify(n.value)}` : ''}${n.focused ? ' FOCUSED' : ''}${n.checked !== undefined ? ` checked=${n.checked}` : ''}${n.multiline ? ' multiline' : ''}`);
});
/** Poll until `pred(nodes)` is truthy (the app republishes a frame or two after an action). */
async function until(page, pred, what, timeout = 6000) {
  const t0 = Date.now();
  let nodes;
  while (Date.now() - t0 < timeout) {
    nodes = await tree(page);
    if (pred(nodes)) return nodes;
    await sleep(120);
  }
  failures.push(`timeout waiting for: ${what}`);
  console.log(`  FAIL timeout waiting for: ${what}`);
  return nodes;
}
const mirror = (page, js) => page.evaluate(`(() => { const root = document.getElementById('zunk-a11y-root'); if (!root) return 0; ${js} })()`);

try {
  const page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 800 });
  page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') console.log(`[console.${m.type()}] ${m.text()}`); });
  page.on('pageerror', (e) => { failures.push(`pageerror: ${e.message || e}`); console.log(`[pageerror] ${e.stack || e}`); });
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  await page.waitForFunction(() => !!document.getElementById('zunk-a11y-root'), { timeout: 30000 }).catch(() => failures.push('no #zunk-a11y-root: the DOM mirror never published'));
  await sleep(waitMs);

  if (scenario === 'dump') {
    dump(await tree(page));
  } else if (scenario === 'todo') {
    console.log('todo: initial tree');
    let t = await tree(page);
    check(find(t, 'textbox', 'New item'), 'textbox "New item"');
    check(find(t, 'button', 'Add'), 'button "Add"');
    check(find(t, 'button', 'Clear done'), 'button "Clear done"');
    check(find(t, 'status'), 'a status (live) region for the count');
    check(find(t, 'StaticText', '0 items'), 'count text "0 items"');

    console.log('todo: focus + typing through the DOM textbox');
    await mirror(page, "root.querySelector('input').focus(); return 1;");
    t = await until(page, (n) => find(n, 'textbox', 'New item')?.focused, 'Teak focus mirrored to the textbox');
    check(find(t, 'textbox', 'New item')?.focused, 'textbox focused (DOM focus -> Teak focus -> DOM)');
    await page.keyboard.type('buy milk', { delay: 30 });
    t = await until(page, (n) => find(n, 'textbox', 'New item')?.value === 'buy milk', 'typed text reaches the model and comes back as the textbox value');
    check(find(t, 'textbox', 'New item')?.value === 'buy milk', 'textbox value "buy milk"');
    await page.keyboard.press('Enter');
    t = await until(page, (n) => find(n, 'checkbox', 'buy milk'), 'item added');
    if (!find(t, 'checkbox', 'buy milk')) dump(t);
    check(find(t, 'checkbox', 'buy milk'), 'checkbox "buy milk" appeared');
    check(find(t, 'button', 'Remove buy milk'), 'button "Remove buy milk" (accessible name differs from the visible "x")');
    check(find(t, 'StaticText', '1 items'), 'count text "1 items"');
    check(find(t, 'list', 'Todo items') || find(t, 'generic', 'Todo items') || find(t, 'list'), 'the items scroll is a list');

    console.log('todo: activate a checkbox through the DOM');
    await mirror(page, "root.querySelector('[role=checkbox]').click(); return 1;");
    t = await until(page, (n) => find(n, 'checkbox', 'buy milk')?.checked === true, 'checkbox toggled by a DOM click');
    check(find(t, 'checkbox', 'buy milk')?.checked === true, 'checkbox is now checked (DOM click -> activate -> Msg)');

    console.log('todo: set the textbox value like assistive technology (no key events)');
    await sleep(300);
    await mirror(page, "const i = root.querySelector('input'); i.focus(); i.value = 'walk dog'; i.dispatchEvent(new Event('input', { bubbles: true })); return 1;");
    t = await until(page, (n) => find(n, 'textbox', 'New item')?.value === 'walk dog', 'set_value reaches the model');
    check(find(t, 'textbox', 'New item')?.value === 'walk dog', 'textbox value "walk dog" via set_value');

    console.log('todo: Clear done through the DOM');
    await mirror(page, "[...root.querySelectorAll('button')].find(b => b.textContent === 'Clear done').click(); return 1;");
    t = await until(page, (n) => find(n, 'StaticText', '0 items'), 'completed item cleared');
    check(find(t, 'StaticText', '0 items') && !find(t, 'checkbox', 'buy milk'), 'completed item removed, count "0 items"');
  } else if (scenario === 'notes') {
    console.log('notes: initial tree');
    let t = await tree(page);
    const areas = t.filter((n) => n.role === 'textbox');
    check(areas.length >= 2, 'two textboxes (notes editor, chat input)');
    // A <textarea> reports its text as the accessible name (and the zunk IME bridge adds an empty hidden one).
    const textOf = (n) => n.value || n.name || '';
    const notes = areas.find((n) => n.multiline && /wrap/.test(textOf(n)));
    check(notes, 'notes textbox (multiline) exposes its text');
    check(find(t, 'button', 'Send  (Enter)') || t.some((n) => n.role === 'button' && /Send/.test(n.name || '')), 'button "Send"');

    console.log('notes: type into the chat box through the DOM and send');
    await mirror(page, "const a = [...root.querySelectorAll('textarea,input')]; a[a.length - 1].focus(); return 1;");
    await sleep(500);
    await page.keyboard.type('hello from the DOM', { delay: 25 });
    t = await until(page, (n) => n.some((x) => x.role === 'textbox' && (x.value || x.name) === 'hello from the DOM'), 'chat text mirrored');
    check(t.some((n) => n.role === 'textbox' && (n.value || n.name) === 'hello from the DOM'), 'chat textbox value after typing');
    // Send through the AT path: activate the mirrored button (Enter in a mirrored <textarea> is a native newline).
    await mirror(page, "[...root.querySelectorAll('button')].find(b => /Send/.test(b.textContent)).click(); return 1;");
    t = await until(page, (n) => n.some((x) => x.role === 'StaticText' && /hello from the DOM/.test(x.name || '')), 'message sent');
    check(t.some((n) => n.role === 'StaticText' && /hello from the DOM/.test(n.name || '')), 'sent message appears in the chat log');
  } else {
    console.error(`unknown scenario: ${scenario}`);
    process.exit(2);
  }
} finally {
  await browser.close();
  server.close();
}
if (failures.length) { console.error('A11YPROBE FAIL:\n  ' + failures.join('\n  ')); process.exit(1); }
console.log('A11YPROBE OK');
