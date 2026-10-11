import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import fs from 'node:fs';
import os from 'node:os';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outputDir = path.resolve(root, '../outputs');
fs.mkdirSync(outputDir, { recursive: true });

const local = createRequire(path.join(root, 'package.json'));
let pkg;
try { pkg = local.resolve('playwright'); }
catch { pkg = createRequire(path.join(process.env.USERPROFILE || os.homedir(), '.workbuddy-ai/binaries/node/workspace/package.json')).resolve('playwright'); }
const pw = await import(pathToFileURL(pkg));
const { chromium } = pw.default || pw;

const defaultChrome = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const browser = await chromium.launch({
  ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH }
    : fs.existsSync(defaultChrome) ? { executablePath: defaultChrome } : {}),
  headless: true
});
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 1 });

const errors = [], checks = [];
page.on('pageerror', e => errors.push('[main] ' + e.message));
page.on('console', m => { if (m.type() === 'error') errors.push('[console] ' + m.text()); });

const url = process.env.CANVAS_URL || pathToFileURL(path.join(root, 'canvas.html')).href;
const check = async (name, run) => { await run(); checks.push({ name, passed: true }); console.log('PASS ' + name); };
const pause = (ms = 400) => page.waitForTimeout(ms);
const zoom = () => page.locator('#zoomLabel').innerText();

await page.goto(url);
await page.waitForSelector('.frame');

await check('画布骨架：18 个帧 + 18 个图层项 + 4 个分组', async () => {
  const f = await page.locator('.frame').count();
  const l = await page.locator('.layer-item').count();
  const g = await page.locator('.layer-group').count();
  if (f !== 18) throw new Error('帧数量 ' + f);
  if (l !== 18) throw new Error('图层项 ' + l);
  if (g !== 4) throw new Error('分组 ' + g);
  const st = await page.locator('#stFrames').innerText();
  if (st !== '18') throw new Error('状态栏帧数 ' + st);
});

await check('默认视图聚焦患者端且状态栏缩放合理', async () => {
  const z = await zoom();
  if (!/^\d+%$/.test(z)) throw new Error('缩放标签异常 ' + z);
  const k = parseInt(z, 10);
  if (k < 20 || k > 100) throw new Error('默认缩放越界 ' + z);
});

await check('懒加载：可见帧挂载 iframe 并渲染出页面标题', async () => {
  await page.waitForFunction(() => document.querySelectorAll('.frame-body iframe').length >= 3, null, { timeout: 15000 });
  const triage = page.frames().find(f => f.url().includes('#/patient/triage'));
  if (!triage) throw new Error('未找到分诊帧');
  await triage.waitForSelector('h1', { timeout: 15000 });
  const h1 = (await triage.$eval('h1', el => el.textContent)).trim();
  if (h1 !== '智能分诊') throw new Error('iframe 标题 ' + h1);
  const n = await page.locator('#stLoaded').innerText();
  if (parseInt(n, 10) < 3) throw new Error('已加载计数 ' + n);
});

await check('点击图层选中并刷新属性面板', async () => {
  await page.locator('.layer-item[data-id="patient/booking"]').click();
  await page.waitForFunction(() => document.querySelector('#props h2')?.textContent === '预约挂号');
  const route = await page.locator('#props code').first().innerText();
  if (route !== '#/patient/booking') throw new Error('路由显示 ' + route);
  const sel = await page.locator('.frame.selected').getAttribute('data-id');
  if (sel !== 'patient/booking') throw new Error('选中帧 ' + sel);
  const crumb = await page.locator('#crumbName').innerText();
  if (!crumb.includes('预约挂号')) throw new Error('面包屑 ' + crumb);
});

await check('点击帧标题选中并聚焦该帧', async () => {
  await page.locator('.frame[data-id="doctor/queue"] .frame-label').click();
  await pause(500);
  const sel = await page.locator('.frame.selected').getAttribute('data-id');
  if (sel !== 'doctor/queue') throw new Error('选中帧 ' + sel);
  const h2 = await page.locator('#props h2').innerText();
  if (h2 !== '接诊队列') throw new Error('属性标题 ' + h2);
});

await check('缩放按钮与快捷键生效', async () => {
  const before = parseInt(await zoom(), 10);
  await page.locator('#btnZoomIn').click();
  const after = parseInt(await zoom(), 10);
  if (!(after > before)) throw new Error(`放大无效 ${before} → ${after}`);
  await page.keyboard.press('-');
  await pause(200);
  const back = parseInt(await zoom(), 10);
  if (!(back < after)) throw new Error('快捷键缩小无效');
  await page.locator('#btnHundred').click();
  await pause(200);
  const h = parseInt(await zoom(), 10);
  if (h !== 100) throw new Error('100% 按钮 ' + h);
});

await check('适应画布与聚焦分组', async () => {
  await page.locator('#btnFit').click();
  await pause(400);
  const all = parseInt(await zoom(), 10);
  if (all >= 100) throw new Error('适应画布未缩小 ' + all);
  await page.locator('#btnFitSection').click();
  await pause(400);
  const sec = parseInt(await zoom(), 10);
  if (sec < all) throw new Error(`聚焦分组未放大 ${all} → ${sec}`);
  await page.keyboard.press('0');
  await pause(300);
  const viaKey = parseInt(await zoom(), 10);
  if (Math.abs(viaKey - all) > 1) throw new Error('快捷键 0 与适应画布不一致');
});

await check('空白拖拽平移画布', async () => {
  const before = await page.evaluate(() => document.getElementById('world').style.transform);
  const box = await page.locator('#viewport').boundingBox();
  await page.mouse.move(box.x + box.width - 40, box.y + 60);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width - 220, box.y + 180, { steps: 8 });
  await page.mouse.up();
  await pause(200);
  const after = await page.evaluate(() => document.getElementById('world').style.transform);
  if (before === after) throw new Error('平移未改变视图');
});

await check('显示开关：网格 / 连线 / 锁定交互', async () => {
  await page.locator('#btnGrid').click();
  if (await page.evaluate(() => document.getElementById('grid').style.display) !== 'none') throw new Error('网格未关闭');
  await page.locator('#btnGrid').click();

  await page.locator('#btnLinks').click();
  if (!await page.locator('#links').evaluate(el => el.classList.contains('hide'))) throw new Error('连线未隐藏');
  await page.locator('#btnLinks').click();
  const paths = await page.locator('#links path[marker-end]').count();
  if (paths !== 11) throw new Error('流程连线数量 ' + paths);

  await page.locator('#btnLock').click();
  if (await page.locator('.frame.lock').count() !== 18) throw new Error('锁定未应用到全部帧');
  await page.locator('#btnLock').click();
});

await check('小地图渲染并可点击跳转', async () => {
  const rects = await page.locator('#minimapSvg rect').count();
  if (rects < 20) throw new Error('小地图元素过少 ' + rects);
  const before = await page.evaluate(() => document.getElementById('world').style.transform);
  await page.locator('#minimap').click({ position: { x: 40, y: 30 } });
  await pause(300);
  const after = await page.evaluate(() => document.getElementById('world').style.transform);
  if (before === after) throw new Error('小地图点击未跳转');
});

await check('画布内帧可真实交互（非静态截图）', async () => {
  await page.locator('.layer-item[data-id="patient/triage"]').click();
  await page.locator('#pFocus').click();
  await pause(700);
  const f = page.frames().find(x => x.url().includes('#/patient/triage'));
  if (!f) throw new Error('未找到画布内的分诊帧');
  await f.getByRole('button', { name: '咳嗽、发热' }).click();
  await f.getByRole('button', { name: '开始智能分诊' }).click();
  await f.getByRole('button', { name: '去挂号' }).first().waitFor({ timeout: 10000 });
});

await check('演示模式：打开、翻页、加载真实页面、Esc 退出', async () => {
  await page.locator('.layer-item[data-id="patient/triage"]').click();
  await page.locator('#btnPresent').click();
  await page.waitForSelector('.present.open');
  const name = await page.locator('#presentName').innerText();
  if (name !== '智能分诊') throw new Error('演示标题 ' + name);
  const pf = page.frames().find(f => f.url().includes('#/patient/triage') && f !== page.mainFrame());
  const all = page.frames().filter(f => f.url().includes('#/patient/triage'));
  await all[all.length - 1].waitForSelector('h1', { timeout: 15000 });
  const h1 = (await all[all.length - 1].$eval('h1', el => el.textContent)).trim();
  if (h1 !== '智能分诊') throw new Error('演示 iframe 标题 ' + h1);
  const phone = await page.locator('.present-phone').count();
  if (phone !== 1) throw new Error('移动端未套手机壳');
  await page.locator('#presentNext').click();
  await pause(400);
  const next = await page.locator('#presentName').innerText();
  if (next === name) throw new Error('下一页未切换');
  await page.keyboard.press('Escape');
  await pause(300);
  if (await page.locator('.present.open').count()) throw new Error('Esc 未退出演示');
});

await check('演示模式：桌面端帧不带手机壳', async () => {
  await page.locator('.layer-item[data-id="admin/dashboard"]').click();
  await page.locator('#btnPresent').click();
  await page.waitForSelector('.present.open');
  await pause(400);
  if (await page.locator('.present-phone').count()) throw new Error('桌面帧误套手机壳');
  await page.keyboard.press('Escape');
  await pause(200);
});

await page.locator('.layer-item[data-id="patient/triage"]').click();
await page.locator('#btnFitSection').click();
await pause(900);
await page.screenshot({ path: path.join(outputDir, 'canvas-preview.png') });

await page.locator('#btnHundred').click();
await pause(900);
await page.screenshot({ path: path.join(outputDir, 'canvas-zoom100.png') });

await page.locator('.layer-item[data-id="patient/triage"]').click();
await page.locator('#btnPresent').click();
await pause(900);
await page.screenshot({ path: path.join(outputDir, 'canvas-present.png') });
await page.keyboard.press('Escape');

if (errors.length) throw new Error('浏览器错误：\n' + errors.join('\n'));

fs.writeFileSync(path.join(outputDir, 'canvas-test-results.json'),
  JSON.stringify({ passed: checks.length, errors, checks }, null, 2));
console.log(`${checks.length} checks passed; console errors: ${errors.length}`);
await browser.close();
