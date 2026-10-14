/*
  /admin/ 管理台的前端冒烟（2026-10-14）
  ============================================================================
  为什么需要它：管理台是**纯静态零构建**的（没有 npm、没有打包器、没有单测框架），
  所以"JS 语法对不对"只能用 `node --check` 守，而**"页面跑起来对不对"**
  （脚本是否加载、路由是否渲染、每个页面调的接口是否真的存在）此前完全没人守。

  这个脚本用 Edge 的 **DevTools 协议**（CDP）在真实浏览器里做四件事：
    ① 登录（调真实 /api/v1/auth/login，令牌写进 localStorage）；
    ② 逐个走一遍侧栏的每个页面（改 `location.hash`，等**网络空闲**而不是死等一拍）；
    ③ 收集三类证据：控制台报错 / 未捕获异常 / **HTTP ≥400 的响应**，并逐页截图；
    ④ **写路径覆盖**（2026-10-14 评审 C4 / A1 漏过去的直接原因）：
       模态框能否打开、必填校验是否拦住、以及"公告下架→重新发布""知识库 PATCH"
       这些**真实写操作**——只读冒烟永远发现不了 A1 那类"按钮 100% 失败"的缺陷。

  判定口径（全部计入退出码，不只是打印）：
    - 控制台 error/warning、未捕获异常、非 favicon 的 ≥400 响应；
    - boot 形态：登录遮罩必须收起、侧栏项数不得少于页面清单、whoami 非空、
      页脚不得显示"（服务端信息读取失败）"；
    - 逐页：正文长度 ≥ --min-chars、不得出现错误框、侧栏必须有高亮项；
    - 写路径与模态框断言（见 ④）。
  已知会失败的调用（故意打 400/401 的校验探针）用 `expectFailure()` 包起来，
  不污染 badResponses —— 否则"断言必填校验"本身会把门禁弄红。

  用法（需要：服务端在跑 + 本机装了 Edge）：
    node server/tests/admin-web-smoke.mjs `
      --base http://127.0.0.1:15001 --admin admin --pw <口令> --out <截图目录>
  可选：--port <调试端口>（默认随机，避免并行打架）
        --edge <msedge.exe 路径>（默认在常见安装位置里探测）
        --wait <ms>（每页额外静置，默认 300） --net-idle <ms>（网络空闲判定，默认 600）
        --min-chars <n>（每页正文最小字符数，默认 40）
  退出码：任一断言失败 ⇒ 1；连不上浏览器/登录失败 ⇒ 2（可直接进 CI 门禁）。
*/

import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

/* ---------------- 参数 ---------------- */
const argv = process.argv.slice(2);
function arg(name, def) {
  const i = argv.indexOf('--' + name);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : def;
}
/* Edge 路径不再写死一处：CI/换机时 `--edge` 与 `EDGE_PATH` 都能覆盖，
   默认按常见安装位置逐个探测（以前写死 x86 那一份，装在 Program Files 就整脚本不可用）。 */
function findEdge() {
  const cands = [
    process.env.EDGE_PATH,
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    process.env.LOCALAPPDATA ? join(process.env.LOCALAPPDATA, 'Microsoft', 'Edge', 'Application', 'msedge.exe') : null,
  ].filter(Boolean);
  return cands.find((p) => existsSync(p)) || cands[0];
}

const BASE = arg('base', 'http://127.0.0.1:8091');
const ADMIN = arg('admin', 'admin');
const PW = arg('pw', '');
const OUT = arg('out', join(tmpdir(), 'admin-web-smoke'));
const EDGE = arg('edge', findEdge());
/* 调试端口默认随机（9200-9899）：写死 9333 时两个冒烟并行就互相踢端口，
   后来者只会看到"连不上调试端口"，看起来像浏览器坏了。 */
const PORT = Number(arg('port', String(9200 + Math.floor(Math.random() * 700))));
const PAGE_WAIT_MS = Number(arg('wait', '300'));
const NET_IDLE_MS = Number(arg('net-idle', '600'));
const MIN_CHARS = Number(arg('min-chars', '40'));

/* 页面清单：与服务端 `js/pages.js` 里 page({id:…}) 的 id 一一对应。
   刻意写死而不是"从 pages.js 里 grep 出来"—— 那样写的话，
   "某个页面整段被误删"就会让这个清单跟着变短，测试反而永远绿。 */
const PAGES = [
  'dashboard', 'users', 'departments', 'doctors', 'schedules',
  'ai-models', 'ai-settings', 'ai-prompts', 'ai-tools', 'kb', 'notices',
];

/* 页面正文里必须出现的字面量。
   ★ 为什么要有这一层：这些页面里最容易被悄悄弄丢的不是"渲染失败"，而是
     **把服务端的事实说清楚的那句话** —— 列表的条数行（total）、下拉被 200 上限
     截断时的提示、以及"本页 N 条"（不是总数）的措辞。它们掉了页面照样能渲染、
     正文照样够长，只有人来点才会发现，所以钉在冒烟里。
   ⚠ 只钉"必须存在"，不钉具体数字：数字随夹具变化。 */
const REQUIRED_TEXT = {
  departments: ['共 ', '个科室'],
  doctors: ['共 ', '位医生'],
  /* 排班页由 GET /api/v1/schedules 供数，它的 count 是**本页条数** —— 文案必须是"本页" */
  schedules: ['本页 ', '条'],
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ---------------- 启动 Edge（带调试端口） ---------------- */
if (!existsSync(EDGE)) {
  console.error(`❌ 找不到 Edge：${EDGE} —— 用 --edge <msedge.exe> 或环境变量 EDGE_PATH 指定`);
  process.exit(2);
}
const profile = join(tmpdir(), 'admin-web-smoke-profile-' + PORT);
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
  console.error(`❌ 连不上 Edge 的调试端口 ${PORT} —— Edge 路径用 --edge 指定，或端口换一个（--port）`);
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
/* 网络活动时间戳：页面跳转后等它静下来，而不是死等固定毫秒（慢机随机失败的老毛病）。 */
let lastNetActivity = Date.now();
/* 故意构造的失败调用（校验探针、登出后的 401）期间关掉 ≥400 与控制台采集：
   这些 4xx 是**期望中的**，让它们进 badResponses 等于自己把门禁弄红。 */
let expectedFailureUntil = 0;
const suppressEvidence = () => Date.now() < expectedFailureUntil;

ws.onmessage = (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    return;
  }
  if (typeof msg.method === 'string' && msg.method.startsWith('Network.')) lastNetActivity = Date.now();
  if (msg.method === 'Runtime.consoleAPICalled' && ['error', 'warning'].includes(msg.params.type)) {
    if (!suppressEvidence()) consoleErrors.push({
      level: msg.params.type,
      text: (msg.params.args || []).map((a) => a.value ?? a.description ?? a.type).join(' '),
    });
  }
  if (msg.method === 'Runtime.exceptionThrown') {
    const d = msg.params.exceptionDetails || {};
    exceptions.push(d.exception?.description || d.text || 'unknown exception');
  }
  if (msg.method === 'Log.entryAdded' && msg.params.entry.level === 'error') {
    if (!suppressEvidence()) consoleErrors.push({ level: 'log', text: msg.params.entry.text });
  }
  if (msg.method === 'Network.responseReceived') {
    const r = msg.params.response;
    /* `/favicon.ico` 是**浏览器自己**猜的地址（页面没声明图标时才会有），
       不是页面调的接口 —— 它 404 说明"没配图标"，不说明"页面坏了"，
       所以不计入门禁；图标本身由 index.html 的 <link rel="icon"> 守住。 */
    if (!suppressEvidence() && r.status >= 400 && !/\/favicon\.ico$/.test(r.url)) {
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
async function waitForNetworkIdle(timeoutMs = 20000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    await sleep(100);
    if (Date.now() - lastNetActivity >= NET_IDLE_MS) return true;
  }
  return false;
}
/* 断言必填校验/401 这类"必须失败"的调用时用它包一层，
   免得 CDP 把故意打出来的 4xx 记进 badResponses 把门禁弄红。
   收尾多等 900ms：CDP 事件是异步送来的，请求返回后再放行才不会漏网。 */
async function expectFailure(fn) {
  expectedFailureUntil = Number.POSITIVE_INFINITY;
  try { return await fn(); } finally {
    expectedFailureUntil = Date.now() + 900;
    await sleep(950);
  }
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
  return { ok: true, role: j.data.role, token: j.data.token };
})()`);
if (!loginOk?.ok) {
  edge.kill();
  console.error('❌ 管理台登录失败：' + JSON.stringify(loginOk));
  process.exit(2);
}
const TOKEN = loginOk.token;

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
   所以必须单独断言，否则这类回归只能在截图里用眼睛发现。
   同一范式（"静默少一段信息"也要判 FAIL）在 2026-10-14 评审 C1 里推广到
   侧栏页数 / 登录遮罩 / 每页错误框 / 每页正文长度。 */
const footOk = !/读取失败/.test(booted.footNote);
const bootFailures = [];
if (!booted.loginHidden) bootFailures.push('登录遮罩没有收起（没进入已登录形态）');
if (booted.navItems < PAGES.length) bootFailures.push(`侧栏项数 ${booted.navItems} < 页面清单 ${PAGES.length}（整页被删/漏挂）`);
if (!String(booted.who).trim()) bootFailures.push('whoami 为空（没有登录身份展示）');
if (!footOk) bootFailures.push('页脚显示「服务端信息读取失败」');

/* ---------------- ② 逐页走查 + 截图 ---------------- */
mkdirSync(OUT, { recursive: true });
const report = [];
for (const id of PAGES) {
  const before = badResponses.length;
  lastNetActivity = Date.now();
  await evaluate(`location.hash = '#/${id}'`);
  const t0 = Date.now();
  /* 等"有内容"再等"网络静下来"，最后留一小段静置给重绘 —— 顺序反了会在
     接口还没回来时就截图，把慢机上的正常页面判成白屏。 */
  for (let i = 0; i < 100; i++) {
    const n = await evaluate(`(() => { const c = document.getElementById('content'); return c ? c.innerText.trim().length : 0; })()`);
    if (n > 0) break;
    await sleep(100);
  }
  await waitForNetworkIdle();
  await sleep(PAGE_WAIT_MS);
  const info = await evaluate(`(() => {
    const c = document.getElementById('content');
    return {
      activeNav: (document.querySelector('.nav-item.active') || {}).textContent || '',
      chars: c ? c.innerText.trim().length : -1,
      text: c ? c.innerText : '',
      head: c ? c.innerText.trim().slice(0, 120).replace(/\\s+/g, ' ') : '',
      hasErrorBox: !!document.querySelector('.toast-err, .error, [data-error]'),
    };
  })()`);
  const shot = await send('Page.captureScreenshot', { format: 'png' });
  writeFileSync(join(OUT, `${id}.png`), Buffer.from(shot.data, 'base64'));
  report.push({ id, ...info, renderMs: Date.now() - t0, newBadResponses: badResponses.slice(before) });
}
const pageFailures = [];
for (const r of report) {
  if (r.hasErrorBox) pageFailures.push(`${r.id}: 页面渲染出错误框`);
  if (r.chars < MIN_CHARS) pageFailures.push(`${r.id}: 正文过短（${r.chars} < ${MIN_CHARS}）`);
  if (!String(r.activeNav).trim()) pageFailures.push(`${r.id}: 侧栏没有高亮项（路由没生效）`);
  for (const needle of (REQUIRED_TEXT[r.id] || [])) {
    if (!String(r.text || '').includes(needle)) {
      pageFailures.push(`${r.id}: 正文缺少「${needle}」（条数行/截断提示被删或改错）`);
    }
  }
}

/* ---------------- ③ 模态框 + 必填校验（UI 写路径） ---------------- */
/* 这一步**故意**提交空表单去撞必填校验（服务端会回 400），所以整段包在
   expectFailure 里：面板/控制台都不会被这条"预期内的 400"污染。 */
const modal = await expectFailure(async () => {
  await evaluate(`location.hash = '#/notices'`);
  await sleep(400);
  await waitForNetworkIdle();
  return await evaluate(`(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const buttons = [...document.querySelectorAll('#content button, #content a.btn')];
  const create = buttons.find((b) => /新增|新建|添加/.test(b.textContent || ''));
  if (!create) return { opened: false, why: '页面上找不到「新增/新建」按钮' };
  create.click();
  await sleep(300);
  const mask = document.querySelector('.modal-mask');
  const title = (document.querySelector('.modal-title') || {}).textContent || '';
  if (!mask) return { opened: false, why: '点了新增但没有出现 .modal-mask' };
  const submit = [...document.querySelectorAll('.modal-foot button')].find((b) => /保存|提交|确定|新增/.test(b.textContent || ''))
              || document.querySelector('.modal-foot .btn-primary');
  if (!submit) return { opened: true, title, submitted: false, why: '弹窗里找不到提交按钮' };
  submit.click();
  await sleep(400);
  const errBox = document.querySelector('.modal-error');
  const validationShown = !!errBox && !errBox.classList.contains('hidden');
  const cancel = [...document.querySelectorAll('.modal-foot button')].find((b) => /取消|关闭/.test(b.textContent || ''));
  if (cancel) { cancel.click(); await sleep(300); }
  return {
    opened: true, title, submitted: true, validationShown,
    closedAfterCancel: !document.querySelector('.modal-mask'),
    errorText: errBox ? (errBox.textContent || '').slice(0, 120) : '',
  };
})()`);
});
const modalFailures = [];
if (!modal?.opened) modalFailures.push('模态框打不开：' + (modal?.why || '未知'));
else {
  if (!modal.submitted) modalFailures.push('模态框里没有提交按钮：' + (modal.why || ''));
  else if (!modal.validationShown) modalFailures.push(`必填校验没拦住空表单（.modal-error 未显示；${modal.errorText || '无错误文本'}）`);
  if (!modal.closedAfterCancel) modalFailures.push('点「取消」后模态框没关闭');
}

/* ---------------- ④ 写路径覆盖（只读冒烟发现不了 A1 那类缺陷） ---------------- */
const writeChecks = [];
function check(name, ok, detail) { writeChecks.push({ name, ok: !!ok, detail: String(detail ?? '') }); }
async function api(method, path, body) {
  const r = await fetch(`${BASE}${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${TOKEN}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let j = null;
  try { j = await r.json(); } catch { /* 非 JSON 响应 */ }
  return { status: r.status, json: j };
}

/* 公告：新建 → **下架（只发改动字段）** → 重新发布 → 删除。
   A1 的现场就是"下架按钮 100% 失败"：老实现把没传的字段当空串覆盖，
   于是 PUT {enabled:false} 会把标题/正文清空（或直接 400）。 */
const n1 = await api('POST', '/api/v1/admin/notices', { title: 'SMOKE-公告', body: '冒烟正文', enabled: true });
const nid = n1.json?.data?.id;
check('公告 新建', n1.status === 201 && !!nid, `${n1.status} ${JSON.stringify(n1.json?.error || '')}`);
const n2 = await api('PUT', `/api/v1/admin/notices/${nid}`, { enabled: false });
const nn2 = n2.json?.data?.notice || n2.json?.data?.data || n2.json?.data;
check('公告 下架（PATCH 语义：未传字段必须保留）', n2.status === 200 && nn2?.title === 'SMOKE-公告' && nn2?.body === '冒烟正文' && nn2?.enabled === false, `${n2.status} ${JSON.stringify(nn2)}`);
const n3 = await api('PUT', `/api/v1/admin/notices/${nid}`, { enabled: true });
const nn3 = n3.json?.data?.notice || n3.json?.data?.data || n3.json?.data;
check('公告 重新发布（只发 enabled）', n3.status === 200 && nn3?.title === 'SMOKE-公告' && nn3?.enabled === true, `${n3.status} ${JSON.stringify(nn3)}`);
const n4 = await expectFailure(() => api('POST', '/api/v1/admin/notices', { body: '没有标题' }));
check('公告 必填校验（缺 title 应 400 VALIDATION_FAILED）', n4.status === 400 && n4.json?.error?.code === 'VALIDATION_FAILED', `${n4.status} ${n4.json?.error?.code}`);
check('公告 删除（清理）', (await api('DELETE', `/api/v1/admin/notices/${nid}`)).status === 200, 'DELETE');

/* 知识库：新建 → 只改启用态（标题/正文/块数都不许变）→ 只改标题（不许重切块）
   → 空正文（必须 400，而不是"静默清空"）→ 换正文（重切块）→ 删除。 */
const k1 = await api('POST', '/api/v1/admin/kb/docs', { title: 'SMOKE-知识库', category: '冒烟', body: '第一段。第二段。' });
const kid = k1.json?.data?.id;
check('知识库 新建（立即切块）', k1.status === 201 && !!kid && k1.json?.data?.chunk_count >= 1, `${k1.status} ${JSON.stringify(k1.json?.data || k1.json?.error)}`);
const k2 = await api('PUT', `/api/v1/admin/kb/docs/${kid}`, { enabled: false });
const kg2 = (await api('GET', `/api/v1/admin/kb/docs/${kid}`)).json?.data;
check('知识库 只改 enabled：标题/正文/块数不变', k2.status === 200 && kg2?.title === 'SMOKE-知识库' && kg2?.body === '第一段。第二段。' && kg2?.enabled === false, JSON.stringify(kg2));
const k3 = await api('PUT', `/api/v1/admin/kb/docs/${kid}`, { title: 'SMOKE-知识库2' });
const kg3 = (await api('GET', `/api/v1/admin/kb/docs/${kid}`)).json?.data;
check('知识库 只改标题：正文不变、不重切块', k3.status === 200 && kg3?.title === 'SMOKE-知识库2' && kg3?.body === '第一段。第二段。' && kg3?.chunk_count === kg2?.chunk_count, JSON.stringify(kg3));
const k4 = await expectFailure(() => api('PUT', `/api/v1/admin/kb/docs/${kid}`, { body: '' }));
check('知识库 空正文必须 400（不能静默清空）', k4.status === 400, `${k4.status} ${k4.json?.error?.code}`);
const k5 = await api('PUT', `/api/v1/admin/kb/docs/${kid}`, { body: '全新正文，只剩一段。' });
const kg5 = (await api('GET', `/api/v1/admin/kb/docs/${kid}`)).json?.data;
check('知识库 换正文：正文替换、标题保留、块数重算', k5.status === 200 && kg5?.body === '全新正文，只剩一段。' && kg5?.title === 'SMOKE-知识库2', JSON.stringify(kg5));
check('知识库 删除（清理）', (await api('DELETE', `/api/v1/admin/kb/docs/${kid}`)).status === 200, 'DELETE');

/* 鉴权与 404 形状：都要在真实 HTTP 上过一遍。 */
const noauth = await expectFailure(async () => { const r = await fetch(`${BASE}/api/v1/admin/ai/models`); return { status: r.status }; });
check('未带令牌访问管理接口必须 401', noauth.status === 401, `${noauth.status}`);
const nf = await expectFailure(async () => {
  const r = await fetch(`${BASE}/api/v1/admin/definitely-not-here`, { headers: { authorization: `Bearer ${TOKEN}` } });
  return { status: r.status, json: await r.json().catch(() => null) };
});
check('未注册路径必须 404 + ROUTE_NOT_FOUND 信封', nf.status === 404 && nf.json?.error?.code === 'ROUTE_NOT_FOUND', `${nf.status} ${nf.json?.error?.code}`);
const delSet = await expectFailure(() => api('DELETE', '/api/v1/admin/ai/settings/model_kind'));
check('DELETE ai/settings/:key 必须被收窄拒绝（B1）', delSet.status === 400 && delSet.json?.error?.code === 'VALIDATION_FAILED', `${delSet.status} ${delSet.json?.error?.code}`);
const badId = await expectFailure(() => api('PUT', '/api/v1/admin/ai/models/999999', { enabled: false }));
check('PUT 不存在的模型必须 404（B3：不再静默 200）', badId.status === 404, `${badId.status} ${badId.json?.error?.code}`);

/* 登出：清掉令牌后刷新一次，必须回到登录形态（401 → 登录遮罩）。
   清掉令牌后页面若还去拉管理接口，401 是**期望中的**，同样包进 expectFailure。 */
const afterLogout = await expectFailure(async () => {
  const logout = await evaluate(`(async () => {
    localStorage.removeItem('hospital_admin_token');
    localStorage.removeItem('hospital_admin_who');
    location.reload();
    return true;
  })()`);
  if (!logout) return { loginHidden: null, hash: null, why: '登出脚本没执行' };
  await sleep(1500);
  return await evaluate(`({
    loginHidden: document.getElementById('login-view').classList.contains('hidden'),
    hash: location.hash,
  })`);
});
const logoutFailures = [];
if (afterLogout?.loginHidden === null) logoutFailures.push(afterLogout.why || '登出步骤失败');
else if (afterLogout?.loginHidden) logoutFailures.push('清掉令牌后刷新，登录遮罩竟然还是收起的（401 没有回到登录页）');

ws.close();
edge.kill();

/* ---------------- ⑤ 结论 ---------------- */
const writeFailures = writeChecks.filter((c) => !c.ok).map((c) => `${c.name} —— ${c.detail}`);
const failed = consoleErrors.length + exceptions.length + badResponses.length
  + bootFailures.length + pageFailures.length + modalFailures.length
  + writeFailures.length + logoutFailures.length;
const result = {
  ok: failed === 0,
  base: BASE,
  login: { role: loginOk.role },
  booted,
  footNoteOk: footOk,
  bootFailures,
  pages: report,
  pageFailures,
  modal,
  modalFailures,
  writeChecks,
  writeFailures,
  logout: afterLogout,
  logoutFailures,
  consoleErrors,
  exceptions,
  badResponses,
  screenshots: OUT,
};
console.log(JSON.stringify(result, null, 2));
process.exit(failed === 0 ? 0 : 1);
