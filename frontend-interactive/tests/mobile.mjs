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
const page = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
const errors = [], checks = [];
page.on('pageerror', e => errors.push('[main] ' + e.message));
page.on('console', m => { if (m.type() === 'error') errors.push('[console] ' + m.text()); });

const url = process.env.TEST_URL || pathToFileURL(path.join(root, 'dist/index.html')).href;
const check = async (name, run) => { await run(); checks.push({ name, passed: true }); console.log('PASS ' + name); };
const pause = (ms = 320) => page.waitForTimeout(ms);
const goto = async (role, screen) => {
  const target = `#/${role}/${screen}`;
  await page.goto(url + target);
  await page.waitForSelector('h1');
  // 同文档 hash 导航下，等侧栏活动项指向目标页，确保 Vue 已完成本轮渲染
  await page.waitForFunction(h => {
    const a = document.querySelector('.main-nav a.active');
    return !!a && a.getAttribute('href') === h;
  }, target, { timeout: 8000 });
  await pause();
};

const DOCTOR = ['queue', 'emr'];
const ADMIN = ['dashboard', 'departments', 'doctors', 'schedules', 'users', 'ai', 'kb'];
const CONTAINERS = ['.page-heading', '.section-heading', '.card', '.summary-strip>div', '.metric-card', '.visit-item',
  '.emr-label', '.emr-toolbar', '.emr-savebar', '.switch-row', '.alert-banner', '.segmented', '.status-row',
  '.soft-panel', '.table-footer', '.chart-caption', '.editor-panel', '.note-list', '.kb-result'];

const AUDIT = (containers) => {
  const issues = [];
  const vw = window.innerWidth;
  const inScroller = el => {
    let p = el.parentElement;
    while (p && p !== document.body) {
      const ox = getComputedStyle(p).overflowX;
      if (ox === 'auto' || ox === 'scroll') return true;
      p = p.parentElement;
    }
    return false;
  };
  const visible = el => { const s = getComputedStyle(el); return s.display !== 'none' && s.visibility !== 'hidden'; };
  for (const sel of containers) {
    document.querySelectorAll(sel).forEach(el => {
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0 || !visible(el)) return;
      const label = sel + ' · ' + (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 24);
      if (el.scrollWidth > el.clientWidth + 1 && !inScroller(el)) {
        issues.push(`内容被裁剪 ${label}（scrollW ${el.scrollWidth} > clientW ${el.clientWidth}）`);
      }
      if (!inScroller(el) && (r.right > vw + 1 || r.left < -1)) {
        issues.push(`超出视口 ${label}（left ${Math.round(r.left)}, right ${Math.round(r.right)}, vw ${vw}）`);
      }
    });
  }
  return { issues, overflow: document.documentElement.scrollWidth - vw };
};

const TAP = () => {
  const bad = [];
  document.querySelectorAll('button,a,input,select,textarea,[role=switch]').forEach(el => {
    if (el.classList.contains('skip-link')) return;
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return;
    const s = getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden') return;
    const isCheck = el.matches('input[type=checkbox],input[type=radio]');
    const minH = isCheck ? 24 : 44, minW = isCheck ? 44 : 0;
    if (r.height < minH - 0.5 || r.width < minW - 0.5) {
      bad.push(`${el.tagName.toLowerCase()}.${String(el.className).split(' ')[0] || '-'} "${(el.textContent || el.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim().slice(0, 14)}" ${Math.round(r.width)}×${Math.round(r.height)}`);
    }
  });
  return bad;
};

await page.goto(url);
await page.waitForSelector('h1');

// ---------- 1. 逐页逐尺寸：不溢出、不裁剪、不遮挡 ----------
const SIZES = [
  { name: '320 小屏', w: 320, h: 568 },
  { name: '360 安卓常见', w: 360, h: 800 },
  { name: '390 iPhone', w: 390, h: 844 },
  { name: '414 大屏手机', w: 414, h: 896 },
];
for (const s of SIZES) {
  await page.setViewportSize({ width: s.w, height: s.h });
  await check(`医生端 2 页 @ ${s.name}：无横向溢出、无裁剪遮挡`, async () => {
    for (const screen of DOCTOR) {
      await goto('doctor', screen);
      const r = await page.evaluate(AUDIT, CONTAINERS);
      if (r.overflow > 1) throw new Error(`doctor/${screen} 页面横向溢出 ${r.overflow}px`);
      if (r.issues.length) throw new Error(`doctor/${screen}：\n  ` + r.issues.join('\n  '));
    }
  });
  await check(`管理端 7 页 @ ${s.name}：无横向溢出、无裁剪遮挡`, async () => {
    for (const screen of ADMIN) {
      await goto('admin', screen);
      const r = await page.evaluate(AUDIT, CONTAINERS);
      if (r.overflow > 1) throw new Error(`admin/${screen} 页面横向溢出 ${r.overflow}px`);
      if (r.issues.length) throw new Error(`admin/${screen}：\n  ` + r.issues.join('\n  '));
    }
  });
}

// ---------- 2. 触控目标 ----------
for (const s of [{ name: '360', w: 360, h: 800 }, { name: '390', w: 390, h: 844 }]) {
  await page.setViewportSize({ width: s.w, height: s.h });
  await check(`医生端 + 管理端全部页面 @ ${s.name}：触控目标 ≥44px`, async () => {
    const bad = [];
    for (const screen of DOCTOR) { await goto('doctor', screen); bad.push(...(await page.evaluate(TAP)).map(x => `doctor/${screen} ${x}`)); }
    for (const screen of ADMIN) { await goto('admin', screen); bad.push(...(await page.evaluate(TAP)).map(x => `admin/${screen} ${x}`)); }
    if (bad.length) throw new Error('触控目标过小：\n  ' + bad.slice(0, 12).join('\n  ') + (bad.length > 12 ? `\n  …共 ${bad.length} 处` : ''));
  });
}

// ---------- 3. 横屏 ----------
for (const s of [{ name: '横屏 740×360', w: 740, h: 360 }, { name: '横屏 844×390', w: 844, h: 390 }]) {
  await page.setViewportSize({ width: s.w, height: s.h });
  await check(`${s.name}：医生端与管理端不被竖向挤扁、不溢出`, async () => {
    for (const [role, list] of [['doctor', DOCTOR], ['admin', ADMIN]]) {
      for (const screen of list) {
        await goto(role, screen);
        const r = await page.evaluate(AUDIT, CONTAINERS);
        if (r.overflow > 1) throw new Error(`${role}/${screen} 横向溢出 ${r.overflow}px`);
        if (r.issues.length) throw new Error(`${role}/${screen}：\n  ` + r.issues.join('\n  '));
        const hero = await page.locator('.hero-art').count();
        if (hero && await page.locator('.hero-art').isVisible()) throw new Error(`${role}/${screen} 横屏仍显示装饰插画`);
      }
    }
  });
}

// ---------- 4. 移动端导航 ----------
await page.setViewportSize({ width: 390, height: 844 });
const navState = () => page.evaluate(() => {
  const navs = [...document.querySelectorAll('.mobile-bottom')];
  return {
    hash: location.hash, h1: document.querySelector('h1')?.textContent.trim(),
    navCount: navs.length,
    navs: navs.map(n => [...n.children].map(c => c.innerText.trim())),
    sideNav: [...document.querySelectorAll('.sidebar .main-nav a')].map(a => a.getAttribute('href')),
    html: navs.map(n => n.outerHTML.replace(/<svg[\s\S]*?<\/svg>/g, '<svg/>').slice(0, 420)),
  };
});

await check('医生端底部导航：接诊队列 / 电子病历（仅两页，无需「更多」）', async () => {
  await goto('doctor', 'queue');
  const nav = page.locator('.mobile-bottom');
  if (!await nav.isVisible()) throw new Error('医生端缺少底部导航 ' + JSON.stringify(await navState()));
  const labels = await nav.locator('a,button').allInnerTexts();
  const want = ['接诊队列', '电子病历'];
  if (JSON.stringify(labels.map(t => t.trim())) !== JSON.stringify(want)) throw new Error('导航项 ' + JSON.stringify(labels) + ' ' + JSON.stringify(await navState()));
});
await check('管理端底部导航：看板 / 科室 / 排班 / 账号 / 更多', async () => {
  await goto('admin', 'dashboard');
  const labels = await page.locator('.mobile-bottom a,.mobile-bottom button').allInnerTexts();
  const want = ['看板', '科室', '排班', '账号', '更多'];
  if (JSON.stringify(labels.map(t => t.trim())) !== JSON.stringify(want)) throw new Error('导航项 ' + JSON.stringify(labels));
});
await check('底部导航可切换页面，「更多」打开抽屉并可进入未列出的页面', async () => {
  await goto('admin', 'dashboard');
  await page.locator('.mobile-bottom').getByRole('link', { name: '排班' }).click();
  await page.getByRole('heading', { name: '排班号源', exact: true }).waitFor();
  await page.locator('.mobile-bottom').getByRole('button', { name: '打开更多页面' }).click();
  await pause();
  if (!await page.locator('.sidebar.open').isVisible()) throw new Error('「更多」未打开抽屉');
  await page.locator('.sidebar').getByRole('link', { name: '医学知识库' }).click();
  await page.getByRole('heading', { name: '医学知识库', exact: true }).waitFor();
  await page.waitForFunction(() => document.querySelector('.sidebar').getBoundingClientRect().right <= 0);
});
await check('患者端底部导航未被破坏', async () => {
  await goto('patient', 'triage');
  const labels = await page.locator('.mobile-bottom a,.mobile-bottom button').allInnerTexts();
  const want = ['分诊', '预问诊', '挂号', '我的预约', '我的', '更多'];
  if (JSON.stringify(labels.map(t => t.trim())) !== JSON.stringify(want)) throw new Error('导航项 ' + JSON.stringify(labels));
});

// ---------- 5. 移动端交互流程完整性 ----------
await check('医生端闭环（390px）：接诊 → 必填拦截 → 锁定 → 完成就诊', async () => {
  await goto('doctor', 'queue');
  await page.getByRole('button', { name: '开始接诊', exact: true }).first().click();
  await page.getByRole('heading', { name: '七段式电子病历' }).waitFor();
  await page.getByRole('button', { name: '提交锁定', exact: true }).click();
  await page.getByText('提交锁定前必须填写诊断和处理意见。', { exact: true }).first().waitFor();
  await page.locator('.emr-fields textarea').nth(5).fill('演示诊断');
  await page.locator('.emr-fields textarea').nth(6).fill('演示处理意见');
  await page.getByRole('button', { name: '保存草稿', exact: true }).click();
  await page.getByRole('button', { name: '提交锁定', exact: true }).click();
  await pause(600);
  const confirm = page.getByRole('button', { name: '确认', exact: true });
  if (!await confirm.count()) {
    const dbg = await page.evaluate(() => ({
      hash: location.hash,
      modal: !!document.querySelector('.modal-backdrop'),
      err: document.querySelector('.alert-banner.danger')?.textContent.trim(),
      savebar: document.querySelector('.emr-savebar')?.textContent.replace(/\s+/g, ' ').trim(),
      locked: !!document.querySelector('.emr-fields textarea[readonly]'),
      diag: document.querySelector('.emr-fields textarea:nth-of-type(6)')?.value,
    }));
    throw new Error('确认按钮未出现：' + JSON.stringify(dbg) + ' | 浏览器错误：' + JSON.stringify(errors.slice(0, 2)));
  }
  await confirm.click();
  if (!await page.getByRole('button', { name: '保存草稿', exact: true }).isDisabled()) throw new Error('锁定后仍可编辑');
  await page.getByRole('button', { name: '返回接诊队列' }).click();
  await page.getByRole('button', { name: '完成就诊', exact: true }).click();
  await page.getByRole('button', { name: '确认', exact: true }).click();
  await page.getByText('演示就诊已完成', { exact: true }).waitFor();
});

await check('管理端闭环（390px）：新增科室 → 表格操作 → 被引用删除拦截', async () => {
  await goto('admin', 'departments');
  await page.getByRole('button', { name: '新增科室', exact: true }).click();
  await page.getByLabel('科室名称').fill('测试科室');
  await page.getByLabel('唯一编码').fill('TEST');
  await page.getByLabel('就诊位置').fill('门诊楼 5F');
  await page.getByRole('button', { name: '保存科室', exact: true }).click();
  await page.getByText('测试科室', { exact: true }).waitFor();
  await page.locator('tbody tr').first().getByRole('button', { name: '删除', exact: true }).click();
  await page.getByRole('button', { name: '确认', exact: true }).click();
  await page.getByText('BASE_IN_USE：该科室被引用，请改为停用', { exact: true }).waitFor();
});

await check('管理端表格（561px 平板宽度）：保持表格形态，超宽时可横向滚动且首列吸附', async () => {
  await page.setViewportSize({ width: 561, height: 900 });
  for (const s of ['departments', 'doctors', 'schedules', 'users', 'kb']) {
    await goto('admin', s);
    if (!await page.locator('.table-card thead').first().isVisible()) throw new Error(`admin/${s} 表头不可见，未保持表格形态`);
    const sc = page.locator('.table-scroll').first();
    const over = await sc.evaluate(el => el.scrollWidth - el.clientWidth);
    if (over > 1) {
      const box = await sc.boundingBox();
      await sc.evaluate(el => { el.scrollLeft = el.scrollWidth; });
      await pause(150);
      const firstLeft = await page.locator('tbody tr').first().locator('td').first().evaluate(el => Math.round(el.getBoundingClientRect().left));
      if (Math.abs(firstLeft - box.x) > 2) throw new Error(`admin/${s} 首列未吸附，left=${firstLeft}`);
    }
  }
});

await check('管理端表格（390px 手机）：转为卡片，五张表全部列可见且无需横向滑动', async () => {
  await page.setViewportSize({ width: 390, height: 844 });
  await goto('admin', 'departments');
  const labels = await page.locator('tbody tr').first().locator('td').evaluateAll(tds => tds.map(td => td.dataset.label));
  if (labels.join(',') !== '科室名称,编码,就诊位置,状态,操作') throw new Error('单元格标签 ' + labels.join(','));
  const before = await page.locator('tbody tr').first().locator('td').first().evaluate(el => getComputedStyle(el, '::before').content);
  if (!before.includes('科室名称')) throw new Error('未渲染行内标签：' + before);
  for (const n of ['编辑', '停用', '删除']) {
    if (!await page.locator('tbody tr').first().getByRole('button', { name: n, exact: true }).isVisible()) throw new Error(n + ' 按钮不可见');
  }
  for (const s of ['departments', 'doctors', 'schedules', 'users', 'kb']) {
    await goto('admin', s);
    const over = await page.locator('.table-scroll').first().evaluate(el => el.scrollWidth - el.clientWidth);
    if (over > 1) throw new Error(`admin/${s} 表格仍横向溢出 ${over}px`);
  }
});

await check('管理端表单（360px）：排班新增成功、账号口令强度校验反馈完整', async () => {
  await page.setViewportSize({ width: 360, height: 800 });
  await goto('admin', 'schedules');
  await page.getByRole('button', { name: '新增排班', exact: true }).click();
  await page.getByLabel('总号数', { exact: true }).fill('3');
  await page.getByRole('button', { name: '保存排班', exact: true }).click();
  if (await page.locator('tbody tr').count() !== 7) throw new Error('新增排班未进入列表');
  await goto('admin', 'users');
  await page.getByRole('button', { name: '新增账号', exact: true }).click();
  await page.getByLabel('登录名', { exact: true }).fill('demo.test');
  await page.getByLabel('显示名称', { exact: true }).fill('测试账号');
  await page.getByLabel(/初始演示口令/).fill('weak');
  await page.getByRole('button', { name: '保存账号', exact: true }).click();
  await page.getByText('演示口令需至少 8 位，包含大小写字母、数字与符号。', { exact: true }).waitFor();
});

await check('管理端 AI 配置（360px）：三标签可切换且校验生效', async () => {
  await goto('admin', 'ai');
  await page.getByRole('button', { name: 'Prompt 模板', exact: true }).click();
  await page.getByLabel('模板正文').waitFor();
  await page.getByLabel('模板正文').fill('不含占位符');
  await page.getByRole('button', { name: '保存模板', exact: true }).click();
  await page.getByText('演示模板必须包含 {complaint} 和 {options} 占位符', { exact: true }).waitFor();
  await page.getByRole('button', { name: '工具开关', exact: true }).click();
  await page.getByRole('button', { name: '模型配置', exact: true }).click();
  await page.getByLabel('密钥引用（ai.key_ref）').fill('bare-secret');
  await page.getByRole('button', { name: '保存演示配置', exact: true }).click();
  await page.getByText('ai.key_ref 仅接受 env: / file: 引用，禁止裸密钥。', { exact: true }).waitFor();
});

// ---------- 6. 截图 ----------
const shot = async (role, screen, w, h, file) => {
  await page.setViewportSize({ width: w, height: h });
  await page.goto('about:blank');
  await page.goto(url + `#/${role}/${screen}`);
  await page.waitForSelector('h1');
  await pause(450);
  await page.screenshot({ path: path.join(outputDir, file) });
};
await shot('doctor', 'queue', 390, 844, 'mobile-doctor-queue.png');
await shot('doctor', 'emr', 390, 844, 'mobile-doctor-emr.png');
await shot('admin', 'dashboard', 390, 844, 'mobile-admin-dashboard.png');
await shot('admin', 'departments', 390, 844, 'mobile-admin-table.png');
await shot('admin', 'ai', 320, 568, 'mobile-320-admin-ai.png');
await shot('doctor', 'queue', 844, 390, 'mobile-landscape-doctor.png');
await shot('admin', 'departments', 740, 360, 'mobile-landscape-admin-table.png');

if (errors.length) throw new Error('浏览器错误：\n' + errors.join('\n'));

fs.writeFileSync(path.join(outputDir, 'mobile-test-results.json'),
  JSON.stringify({ passed: checks.length, errors, checks }, null, 2));
console.log(`${checks.length} checks passed; console errors: ${errors.length}`);
await browser.close();
