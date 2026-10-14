/*
  /admin/ 管理台的前端冒烟（2026-10-14）
  ============================================================================
  为什么需要它：管理台是**纯静态零构建**的（没有 npm、没有打包器、没有单测框架），
  所以"JS 语法对不对"只能用 `node --check` 守，而**"页面跑起来对不对"**
  （脚本是否加载、路由是否渲染、每个页面调的接口是否真的存在）此前完全没人守。

  这个脚本用 Edge 的 **DevTools 协议**（CDP）在真实浏览器里做三件事：
    ① 登录（调真实 /api/v1/auth/login，令牌写进 localStorage）；
    ② 逐个走一遍侧栏的每个页面（改 `location.hash`，等一拍让它取数）；
    ③ 收集三类证据：控制台报错 / 未捕获异常 / **HTTP ≥400 的响应**，
       并给每个页面截一张图。

  为什么用 CDP 而不是 `--dump-dom`：`--dump-dom` 只能看到"首屏那一份 HTML"，
  看不到接口调用、看不到控制台异常；而管理台的绝大多数问题恰好出在
  "某个页面调了一个不存在的接口"或"某个渲染函数抛异常"上。

  用法（需要：服务端在跑 + 本机装了 Edge）：
    node server/tests/admin-web-smoke.mjs `
      --base http://127.0.0.1:8091 --admin <登录名> --pw <口令> --out <截图目录>
  退出码：有控制台报错 / 未捕获异常 / 4xx-5xx 响应 ⇒ 1（可直接进 CI 门禁）。
*/

import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

/* ---------------- 参数 ---------------- */
const argv = process.argv.slice(2);
function arg(name, def) {
  const i = argv.indexOf('--' + name);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : def;
}
const BASE = arg('base', 'http://127.0.0.1:8091');
const ADMIN = arg('admin', 'admin');
const PW = arg('pw', '');
const OUT = arg('out', join(tmpdir(), 'admin-web-smoke'));
const EDGE = arg('edge', 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe');
const PORT = Number(arg('port', '9333'));
const PAGE_WAIT_MS = Number(arg('wait', '900'));

/* 页面清单：与服务端 `js/pages.js` 里 page({id:…}) 的 id 一一对应。
   刻意写死而不是"从 pages.js 里 grep 出来"—— 那样写的话，
   "某个页面整段被误删"就会让这个清单跟着变短，测试反而永远绿。 */
const PAGES = [
  'dashboard', 'users', 'departments', 'doctors', 'schedules',
  'ai-models', 'ai-settings', 'ai-prompts', 'ai-tools', 'kb', 'notices',
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ---------------- 启动 Edge（带调试端口） ---------------- */
const profile = join(tmpdir(), 'admin-web-smoke-profile');
rmSync(profile, { recursive: true, force: true });
const edge = spawn(EDGE, [
  '--headless=new', '--disable-gpu', '--no-first-run', '--no-sandbox',
  '--window-size=1440,1000',
  `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${profile}`,
  'about:blank',
], { stdio: 'ignore' });

let wsUrl = null;
for (let i = 0; i < 60 && !wsUrl; i++) {
  await sleep(250);
  try {
    const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
    const page = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
    if (page) wsUrl = page.webSocketDebuggerUrl;
  } catch { /* 端口还没起来 */ }
}
if (!wsUrl) {
  edge.kill();
  console.error('❌ 连不上 Edge 的调试端口 —— Edge 路径用 --edge 指定，或端口换一个（--port）');
  process.exit(2);
}

/* ---------------- CDP 客户端（Node 22+ 自带 WebSocket） ---------------- */
const ws = new WebSocket(wsUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });

let nextId = 1;
const pending = new Map();
const consoleErrors = [];
const exceptions = [];
const badResponses = [];

ws.onmessage = (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    return;
  }
  if (msg.method === 'Runtime.consoleAPICalled' && ['error', 'warning'].includes(msg.params.type)) {
    consoleErrors.push({
      level: msg.params.type,
      text: (msg.params.args || []).map((a) => a.value ?? a.description ?? a.type).join(' '),
    });
  }
  if (msg.method === 'Runtime.exceptionThrown') {
    const d = msg.params.exceptionDetails || {};
    exceptions.push(d.exception?.description || d.text || 'unknown exception');
  }
  if (msg.method === 'Log.entryAdded' && msg.params.entry.level === 'error') {
    consoleErrors.push({ level: 'log', text: msg.params.entry.text });
  }
  if (msg.method === 'Network.responseReceived') {
    const r = msg.params.response;
    /* `/favicon.ico` 是**浏览器自己**猜的地址（页面没声明图标时才会有），
       不是页面调的接口 —— 它 404 说明"没配图标"，不说明"页面坏了"，
       所以不计入门禁；图标本身由 index.html 的 <link rel="icon"> 守住。 */
    if (r.status >= 400 && !/\/favicon\.ico$/.test(r.url)) {
      badResponses.push({ status: r.status, url: r.url });
    }
  }
};

function send(method, params = {}) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
  });
}
async function evaluate(expression) {
  const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || 'evaluate failed');
  return r.result?.value;
}

await send('Runtime.enable');
await send('Log.enable');
await send('Page.enable');
await send('Network.enable');

/* ---------------- ① 打开管理台并登录 ---------------- */
await send('Page.navigate', { url: `${BASE}/admin/` });
await sleep(1200);

const loginOk = await evaluate(`(async () => {
  const r = await fetch('/api/v1/auth/login', {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ login_name: ${JSON.stringify(ADMIN)}, password: ${JSON.stringify(PW)} }),
  });
  const j = await r.json();
  if (!j.ok) return { ok: false, error: j.error };
  localStorage.setItem('hospital_admin_token', j.data.token);
  localStorage.setItem('hospital_admin_who', JSON.stringify({
    user_id: j.data.user_id, role: j.data.role, ref_id: j.data.ref_id,
    display_name: j.data.display_name, expires_at: j.data.expires_at,
  }));
  return { ok: true, role: j.data.role };
})()`);
if (!loginOk?.ok) {
  edge.kill();
  console.error('❌ 管理台登录失败：' + JSON.stringify(loginOk));
  process.exit(2);
}

/* 刷新一次，让 app.js 以"已登录"的状态启动（走真实的 boot 路径） */
await send('Page.navigate', { url: `${BASE}/admin/` });
await sleep(1200);
const booted = await evaluate(`({
  loginHidden: document.getElementById('login-view').classList.contains('hidden'),
  navItems: document.querySelectorAll('.nav-item').length,
  who: (document.getElementById('whoami') || {}).textContent || '',
  footNote: (document.getElementById('nav-foot-note') || {}).textContent || '',
})`);
/* 页脚是"服务端事实"（版本/数据后端/服务端认定的今天）—— 它显示成
   "（服务端信息读取失败）"时页面**不会**报控制台错误，只会静默少一段信息，
   所以必须单独断言，否则这类回归只能在截图里用眼睛发现。 */
const footOk = !/读取失败/.test(booted.footNote);

/* ---------------- ② 逐页走查 + 截图 ---------------- */
mkdirSync(OUT, { recursive: true });
const report = [];
for (const id of PAGES) {
  const before = badResponses.length;
  await evaluate(`location.hash = '#/${id}'`);
  await sleep(PAGE_WAIT_MS);
  const info = await evaluate(`(() => {
    const c = document.getElementById('content');
    return {
      activeNav: (document.querySelector('.nav-item.active') || {}).textContent || '',
      chars: c ? c.innerText.trim().length : -1,
      head: c ? c.innerText.trim().slice(0, 120).replace(/\\s+/g, ' ') : '',
      hasErrorBox: !!document.querySelector('.toast-err, .error, [data-error]'),
    };
  })()`);
  const shot = await send('Page.captureScreenshot', { format: 'png' });
  writeFileSync(join(OUT, `${id}.png`), Buffer.from(shot.data, 'base64'));
  report.push({ id, ...info, newBadResponses: badResponses.slice(before) });
}

ws.close();
edge.kill();

/* ---------------- ③ 结论 ---------------- */
const failed = consoleErrors.length + exceptions.length + badResponses.length + (footOk ? 0 : 1);
const result = {
  ok: failed === 0,
  base: BASE,
  login: { role: loginOk.role },
  booted,
  footNoteOk: footOk,
  pages: report,
  consoleErrors,
  exceptions,
  badResponses,
  screenshots: OUT,
};
console.log(JSON.stringify(result, null, 2));
process.exit(failed === 0 ? 0 : 1);
