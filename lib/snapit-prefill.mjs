#!/usr/bin/env node
// SnapIt - DeepSeek route prefill bridge
// Opens a DEDICATED Edge window at the target URL (DSH Web UI) and places the
// given prompt text into the page composer WITHOUT submitting. No dependencies:
// requires Node >= 22 (global fetch + WebSocket) and Microsoft Edge.
//
// usage:
//   node snapit-prefill.mjs --text-file <file> --url <url> --edge <edge.exe>
//                          [--base-port 9333] [--timeout-ms 45000]
// exit codes: 0 ok, 1 prereq/config, 2 composer not found, 3 timeout/browser

import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer } from 'node:net';

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const textFile = arg('--text-file', '');
const url = arg('--url', 'http://127.0.0.1:18080');
const edge = arg('--edge', '');
const basePort = parseInt(arg('--base-port', '9333'), 10);
const timeoutMs = parseInt(arg('--timeout-ms', '45000'), 10);

const fail = (code, msg) => { console.error('PREFILL_FAIL ' + msg); process.exit(code); };

if (!textFile || !edge) fail(1, 'missing --text-file/--edge');
let text;
try { text = readFileSync(textFile, 'utf8'); } catch (e) { fail(1, 'cannot read text file: ' + e.message); }
if (!text.trim()) fail(1, 'empty prompt text');

async function portFree(port) {
  return new Promise((resolve) => {
    const srv = createServer();
    srv.unref();
    srv.on('error', () => resolve(false));
    srv.listen(port, '127.0.0.1', () => { srv.close(() => resolve(true)); });
  });
}

async function pickPort() {
  for (let p = basePort; p < basePort + 40; p++) {
    if (await portFree(p)) return p;
  }
  return basePort;
}

async function waitJson(port, ms) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    try {
      const r = await fetch('http://127.0.0.1:' + port + '/json/version');
      if (r.ok) return await r.json();
    } catch (e) { /* not ready yet */ }
    await new Promise((res) => setTimeout(res, 250));
  }
  return null;
}

let wsId = 0;
const pending = new Map();
function connect(wsUrl) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    ws.onopen = () => resolve(ws);
    ws.onerror = () => reject(new Error('websocket error'));
    ws.onmessage = (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg.id && pending.has(msg.id)) {
        const pr = pending.get(msg.id);
        pending.delete(msg.id);
        if (msg.error) pr.reject(new Error(JSON.stringify(msg.error)));
        else pr.resolve(msg.result);
      }
    };
  });
}

function send(ws, method, params) {
  if (!params) params = {};
  return new Promise((resolve, reject) => {
    const id = ++wsId;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
  });
}

// JS snippet that finds the most likely composer control on the page
const FINDER = [
  '(function(){',
  '  var q = document.querySelectorAll("textarea, [contenteditable=\\"true\\"], input[type=text], input:not([type])");',
  '  var best = null; var scoreOf = -1;',
  '  for (var i = 0; i < q.length; i++) {',
  '    var el = q[i]; var r = el.getBoundingClientRect();',
  '    if (r.width < 60 || r.height < 12 || r.top < 0) continue;',
  '    var st = window.getComputedStyle(el);',
  '    if (st.display === "none" || st.visibility === "hidden") continue;',
  '    var cy = r.top + r.height / 2; var cx = r.left + r.width / 2;',
  '    var score = cy * 10 + Math.abs(cx - window.innerWidth / 2) * 0.05;',
  '    if (score > scoreOf) { scoreOf = score; best = { el: el, tag: el.tagName, editable: el.isContentEditable, top: Math.round(r.top), bottom: Math.round(r.bottom) }; }',
  '  }',
  '  if (!best) return { ok: false };',
  '  return { ok: true, tag: best.tag, editable: best.editable, top: best.top, bottom: best.bottom };',
  '})()',
].join('\n');

function buildSetter(text) {
  const parts = [
    '(function(){',
    '  var q = document.querySelectorAll("textarea, [contenteditable=\\"true\\"], input[type=text], input:not([type])");',
    '  var best = null; var scoreOf = -1;',
    '  for (var i = 0; i < q.length; i++) {',
    '    var el = q[i]; var r = el.getBoundingClientRect();',
    '    if (r.width < 60 || r.height < 12 || r.top < 0) continue;',
    '    var st = window.getComputedStyle(el);',
    '    if (st.display === "none" || st.visibility === "hidden") continue;',
    '    var cy = r.top + r.height / 2;',
    '    if (cy > scoreOf) { scoreOf = cy; best = el; }',
    '  }',
    '  if (!best) return { ok: false };',
    '  var text = ' + JSON.stringify(text) + ';',
    '  best.focus();',
    '  best.scrollIntoView({ block: "center", behavior: "instant" });',
    '  try {',
    '    if (best.isContentEditable) {',
    '      best.focus();',
    '      document.execCommand("selectAll", false, null);',
    '      document.execCommand("insertText", false, text);',
    '      best.dispatchEvent(new Event("input", { bubbles: true }));',
    '      return { ok: true, mode: "contenteditable", len: best.innerText.length };',
    '    }',
    '    var proto = best.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;',
    '    var set = Object.getOwnPropertyDescriptor(proto, "value").set;',
    '    set.call(best, text);',
    '    best.dispatchEvent(new Event("input", { bubbles: true }));',
    '    best.dispatchEvent(new Event("change", { bubbles: true }));',
    '    if (best.setSelectionRange) best.setSelectionRange(text.length, text.length);',
    '    return { ok: true, mode: best.tagName, len: best.value.length };',
    '  } catch (e) {',
    '    return { ok: false, error: String(e) };',
    '  }',
    '})()',
  ];
  return parts.join('\n');
}

async function main() {
  const debugPort = await pickPort();
  const userData = mkdtempSync(join(tmpdir(), 'snapit-edge-'));
  const edgeArgs = [
    '--user-data-dir=' + userData,
    '--remote-debugging-port=' + debugPort,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-session-crashed-bubble',
    '--disable-features=msEdgeSidebarV2',
    '--window-size=1500,950',
    'about:blank',
  ];
  const child = spawn(edge, edgeArgs, { stdio: 'ignore' });

  const ver = await waitJson(debugPort, 20000);
  if (!ver) { try { child.kill(); } catch {} fail(3, 'Edge did not expose the debug port in time'); }

  // open the target page as a new tab target
  let target = null;
  try {
    const r = await fetch('http://127.0.0.1:' + debugPort + '/json/new?' + encodeURIComponent(url), { method: 'PUT' });
    if (r.ok) target = await r.json();
  } catch {}
  if (!target || !target.webSocketDebuggerUrl) {
    try {
      const r = await fetch('http://127.0.0.1:' + debugPort + '/json/new', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: url }),
      });
      if (r.ok) target = await r.json();
    } catch {}
  }
  if (!target || !target.webSocketDebuggerUrl) {
    const list = await (await fetch('http://127.0.0.1:' + debugPort + '/json/list')).json();
    const page = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
    if (!page) { try { child.kill(); } catch {} fail(3, 'no page target available'); }
    target = page;
  }

  const ws = await connect(target.webSocketDebuggerUrl);
  await send(ws, 'Page.enable');
  await send(ws, 'Runtime.enable');

  const evaluate = async (expression) => {
    const res = await send(ws, 'Runtime.evaluate', { expression: expression, returnByValue: true, awaitPromise: true });
    if (res.exceptionDetails) throw new Error('evaluate exception: ' + JSON.stringify(res.exceptionDetails).slice(0, 300));
    return res.result && res.result.value;
  };

  try { await send(ws, 'Page.navigate', { url: url }); } catch {}

  // wait for the SPA composer to become findable
  let found = null;
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    try {
      await evaluate('document.readyState');
      const f = await evaluate(FINDER);
      if (f && f.ok) { found = f; break; }
    } catch {}
    await new Promise((res) => setTimeout(res, 700));
  }
  if (!found) { ws.close(); try { child.kill(); } catch {} fail(2, 'composer element not found on ' + url); }

  const result = await evaluate(buildSetter(text));
  ws.close();
  if (result && result.ok) {
    console.log('PREFILL_OK mode=' + result.mode + ' len=' + result.len + ' port=' + debugPort + ' url=' + url);
    console.log('Window left open. Prompt placed in the composer. Nothing was submitted.');
    process.exit(0);
  }
  fail(2, 'could not place text in composer: ' + JSON.stringify(result).slice(0, 300));
}

main().catch((e) => fail(3, String((e && e.message) ? e.message : e)));
