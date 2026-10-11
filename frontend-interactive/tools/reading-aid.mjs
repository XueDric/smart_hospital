/**
 * 阅读辅助内容标注工具
 *
 * @reading-aid:skip-file —— 本文件是扫描器自身，源码里含有标记的正则字面量，必须跳过，否则自指
 *
 *   node tools/reading-aid.mjs check                校验标注配对与取值（失败返回非零退出码）
 *   node tools/reading-aid.mjs list                 按文件列出全部标注
 *   node tools/reading-aid.mjs manifest [输出路径]   生成标注清单（默认 ../docs/阅读辅助内容清单.md）
 *   node tools/reading-aid.mjs strip <输入> <输出>   剥离块级标注，输出生产副本（仅 html/js/css/mjs）
 *
 * 规范见 docs/阅读辅助标注规范.md
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const KINDS = ['讲解', '依据', '演示', '指引'];
const EXTS = new Set(['.js', '.mjs', '.cjs', '.vue', '.css', '.html', '.htm', '.cmd']);
const SKIP_DIRS = new Set(['node_modules', 'dist', '.git', '.workbuddy-ai']);

const RE_BEGIN = /@reading-aid:begin\s+(\S+)\s*(.*)$/;
const RE_END = /@reading-aid:end\b/;
const RE_FILE = /@reading-aid:file\s+(\S+)\s*(.*)$/;
const RE_INLINE = /@reading-aid:(?!begin|end|file|skip-file)(\S+)\s*(.*)$/;
const RE_ATTR = /data-reading-aid="([^"]*)"/g;

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      walk(path.join(dir, entry.name), out);
    } else if (EXTS.has(path.extname(entry.name))) {
      out.push(path.join(dir, entry.name));
    }
  }
  return out;
}

function cleanNote(s) {
  let t = String(s || '').replace(/^[—\-–\s]+/, '');
  t = t.split('-->')[0].split('*/')[0].trim();
  return t.length > 72 ? t.slice(0, 72) + '…' : t;
}

function scan(file) {
  const rel = path.relative(root, file).replace(/\\/g, '/');
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  const blocks = [], attrs = [], problems = [], files = [], inline = [];
  const stack = [];

  if (lines.slice(0, 5).some(l => l.includes('@reading-aid:skip-file'))) {
    return { rel, file, lines: lines.length, blocks, attrs, files, inline, problems, count: 0, skipped: true };
  }

  lines.forEach((line, i) => {
    const no = i + 1;

    const fm = line.match(RE_FILE);
    if (fm) {
      if (no > 10) problems.push(`${rel}:${no} 整文件横幅必须出现在前 10 行内`);
      if (!KINDS.includes(fm[1])) problems.push(`${rel}:${no} 未知类型「${fm[1]}」`);
      files.push({ line: no, kind: fm[1], note: cleanNote(fm[2]) });
    }

    const bm = line.match(RE_BEGIN);
    if (bm) {
      if (!KINDS.includes(bm[1])) problems.push(`${rel}:${no} 未知类型「${bm[1]}」`);
      stack.push({ line: no, kind: bm[1], note: cleanNote(bm[2]) });
    } else if (RE_END.test(line)) {
      const open = stack.pop();
      if (!open) problems.push(`${rel}:${no} 出现 @reading-aid:end 但没有对应的 begin`);
      else blocks.push({ ...open, end: no });
    } else {
      const im = line.match(RE_INLINE);
      if (im) {
        if (!KINDS.includes(im[1])) problems.push(`${rel}:${no} 行内标记类型「${im[1]}」不在允许集合内`);
        inline.push({ line: no, kind: im[1], note: cleanNote(im[2]) });
      }
    }

    for (const am of line.matchAll(RE_ATTR)) {
      if (!KINDS.includes(am[1])) problems.push(`${rel}:${no} 属性取值「${am[1]}」不在允许集合内`);
      attrs.push({ line: no, kind: am[1] });
    }
  });

  stack.forEach(o => problems.push(`${rel}:${o.line} @reading-aid:begin 未闭合`));

  const count = blocks.length + attrs.length + files.length + inline.length;
  return { rel, file, lines: lines.length, blocks, attrs, files, inline, problems, count };
}

function collect() {
  const targets = [root, path.resolve(root, '..', 'docs')];
  const seen = new Set();
  const results = [];
  for (const dir of targets) {
    if (!fs.existsSync(dir)) continue;
    for (const f of walk(dir)) {
      if (seen.has(f)) continue;
      seen.add(f);
      const r = scan(f);
      if (r.count || r.problems.length) results.push(r);
    }
  }
  return results.sort((a, b) => a.rel.localeCompare(b.rel, 'zh'));
}

const KIND_ICON = { 讲解: '□', 依据: '◇', 演示: '△', 指引: '→' };

function cmdList(results) {
  let total = 0;
  for (const r of results) {
    console.log(`\n${r.rel}`);
    r.files.forEach(f => { total++; console.log(`  ${KIND_ICON[f.kind] || '·'} [整文件·${f.kind}] ${f.note}`); });
    r.blocks.forEach(b => { total++; console.log(`  ${KIND_ICON[b.kind] || '·'} [块·${b.kind}] L${b.line}-${b.end} ${b.note}`); });
    r.inline.forEach(x => { total++; console.log(`  ${KIND_ICON[x.kind] || '·'} [行内·${x.kind}] L${x.line} ${x.note}`); });
    const byKind = {};
    r.attrs.forEach(a => byKind[a.kind] = (byKind[a.kind] || 0) + 1);
    const summary = Object.entries(byKind).map(([k, n]) => `${k}×${n}`).join(' ');
    if (r.attrs.length) { total += r.attrs.length; console.log(`  ${'·'} [属性] 共 ${r.attrs.length} 处：${summary}`); }
  }
  console.log(`\n合计 ${total} 处标注，涉及 ${results.length} 个文件。`);
}

function cmdCheck(results) {
  const problems = results.flatMap(r => r.problems);
  const files = results.filter(r => r.count).length;
  const total = results.reduce((n, r) => n + r.count, 0);
  if (problems.length) {
    console.error('标注校验未通过：');
    problems.forEach(p => console.error('  ✗ ' + p));
    process.exitCode = 1;
    return;
  }
  console.log(`标注校验通过：${files} 个文件、${total} 处标注，配对完整、取值合法。`);
}

function cmdManifest(results, out) {
  const order = ['讲解', '依据', '演示', '指引'];
  const totals = Object.fromEntries(order.map(k => [k, 0]));
  const body = [];

  body.push('# 阅读辅助内容清单');
  body.push('');
  body.push('> **本文件由 `node tools/reading-aid.mjs manifest` 自动生成，请勿手工编辑。**');
  body.push('> 标注规范见 [阅读辅助标注规范.md](阅读辅助标注规范.md)。');
  body.push('>');
  body.push('> 「阅读辅助」指：只写给读者看、不承担业务功能、**删掉后业务闭环仍然成立**的文字。');
  body.push('> 这些内容不参与业务判断，**不得随生产构建部署**。');
  body.push('');

  const grand = { blocks: 0, attrs: 0, files: 0, inline: 0 };
  for (const r of results) {
    r.blocks.forEach(b => { totals[b.kind] = (totals[b.kind] || 0) + 1; grand.blocks++; });
    r.attrs.forEach(a => { totals[a.kind] = (totals[a.kind] || 0) + 1; grand.attrs++; });
    r.files.forEach(f => { totals[f.kind] = (totals[f.kind] || 0) + 1; grand.files++; });
    r.inline.forEach(x => { totals[x.kind] = (totals[x.kind] || 0) + 1; grand.inline++; });
  }
  const GRAND = grand.blocks + grand.files + grand.attrs + grand.inline;

  body.push('## 汇总');
  body.push('');
  body.push('| 类型 | 含义 | 块级 | 整文件 | 元素属性 | 行内 | 小计 |');
  body.push('| --- | --- | ---: | ---: | ---: | ---: | ---: |');
  const meaning = { 讲解: '解释实现与方案', 依据: '文档出处与契约引用', 演示: '虚构演示的免责与标注', 指引: '操作与运行说明' };
  for (const k of order) {
    const b = results.reduce((n, r) => n + r.blocks.filter(x => x.kind === k).length, 0);
    const f = results.reduce((n, r) => n + r.files.filter(x => x.kind === k).length, 0);
    const a = results.reduce((n, r) => n + r.attrs.filter(x => x.kind === k).length, 0);
    const i = results.reduce((n, r) => n + r.inline.filter(x => x.kind === k).length, 0);
    body.push(`| \`${k}\` | ${meaning[k]} | ${b} | ${f} | ${a} | ${i} | **${b + f + a + i}** |`);
  }
  body.push(`| | | | | | | **${GRAND}** |`);
  body.push('');

  body.push('## 明细');
  for (const r of results) {
    body.push('');
    body.push(`### \`${r.rel}\``);
    body.push('');
    body.push('| 位置 | 形式 | 类型 | 说明 |');
    body.push('| --- | --- | --- | --- |');
    r.files.forEach(f => body.push(`| L${f.line} | 整文件 | \`${f.kind}\` | ${f.note} |`));
    r.blocks.forEach(b => body.push(`| L${b.line}–${b.end} | 块级 | \`${b.kind}\` | ${b.note} |`));
    r.inline.forEach(x => body.push(`| L${x.line} | 行内 | \`${x.kind}\` | ${x.note} |`));
    const byKind = {};
    r.attrs.forEach(a => byKind[a.kind] = (byKind[a.kind] || 0) + 1);
    Object.entries(byKind).forEach(([k, n]) => {
      const lines = r.attrs.filter(a => a.kind === k).map(a => 'L' + a.line).join(', ');
      body.push(`| ${lines} | 元素属性 | \`${k}\` | \`data-reading-aid="${k}"\` 共 ${n} 处 |`);
    });
  }

  body.push('');
  body.push('## 不进入产物、故不标注的内容');
  body.push('');
  body.push('| 类别 | 位置 | 原因 |');
  body.push('| --- | --- | --- |');
  body.push('| 开发工具脚本 | `frontend-interactive/tools/*.mjs`、`tests/*.mjs`、`start-preview.cmd` | 只在开发机执行，不打包进 `dist/` |');
  body.push('| 工程说明文档 | `docs/*.md`、`README.md` | 不进入构建产物 |');
  body.push('| 源码注释 | 各处 `//` 与 `/* */` | 编译与打包时移除，不产生运行时效果 |');
  body.push('| 构建锚点 | `canvas.html` 的 `@app-url` 标记 | 构建期占位符，属工具约定 |');
  body.push('');

  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, body.join('\n'), 'utf8');
  console.log('清单已生成 →', path.relative(process.cwd(), out), `（${GRAND} 处标注）`);
}

function cmdStrip(input, output) {
  const ext = path.extname(input);
  if (ext === '.vue') throw new Error('不处理 .vue：删除模板节点会改变渲染结构，请按规范 §4 人工剥离');
  if (!EXTS.has(ext)) throw new Error('不支持的文件类型：' + ext);

  const lines = fs.readFileSync(input, 'utf8').split(/\r?\n/);
  const out = [];
  let skipping = false, removed = 0, attrRemoved = 0;

  for (const line of lines) {
    if (!skipping && RE_BEGIN.test(line)) { skipping = true; removed++; continue; }
    if (skipping) { if (RE_END.test(line)) skipping = false; continue; }
    if (RE_END.test(line)) continue;
    const cleaned = line.replace(RE_ATTR, () => { attrRemoved++; return ''; });
    out.push(cleaned);
  }
  if (skipping) throw new Error('存在未闭合的 @reading-aid:begin，已中止');

  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, out.join('\n'), 'utf8');
  console.log(`剥离完成 → ${path.relative(process.cwd(), output)}（移除 ${removed} 个块、${attrRemoved} 个属性）`);
  console.log('提示：剥离后请重新运行 npm test 与 npm run test:canvas 确认功能未受影响。');
}

const [cmd, a1, a2] = process.argv.slice(2);
const results = collect();
switch (cmd) {
  case 'check': cmdCheck(results); break;
  case 'list': cmdList(results); break;
  case 'manifest': cmdManifest(results, a1 ? path.resolve(a1) : path.resolve(root, '..', 'docs', '阅读辅助内容清单.md')); break;
  case 'strip':
    if (!a1 || !a2) { console.error('用法：reading-aid.mjs strip <输入文件> <输出文件>'); process.exitCode = 1; }
    else cmdStrip(path.resolve(a1), path.resolve(a2));
    break;
  default:
    console.log('用法：reading-aid.mjs <check|list|manifest|strip> [参数…]');
    process.exitCode = cmd ? 1 : 0;
}
